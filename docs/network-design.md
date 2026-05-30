# Funnel 网络设计说明

这份文档解释 Funnel 为什么要用 `DNS hijack + FakeIP + TUN`，以及这些配置之间的关系。后续维护者先读这份文档，再改 `singbox.go`，会少走很多弯路。

Funnel 的目标不是“开一个全局代理”。它要在 macOS 上做到：

- 指定域名稳定走本地上游代理。
- 指定进程尽量走本地上游代理。
- 非目标流量默认直连。
- 避免目标域名被系统 DNS 或更具体的系统路由带到受控地址。
- 避免把大段办公或局域网流量卷进 TUN 后造成超时、日志暴涨、系统变慢。

## 背景

最初的直觉是：

```text
App -> TUN -> sing-box 根据 process_name/domain_suffix 决定 proxy 或 direct
```

这在普通网络里通常可行。但在受控网络环境里，实际链路更复杂：

```text
App
  -> macOS resolver / mDNSResponder
  -> 系统 DNS
  -> macOS 路由表
  -> 某个系统 utun / 默认网关
  -> 远端服务或受控页面
```

问题出在两个地方：

1. DNS 可能先被系统 resolver 解析成受控地址。
2. macOS 路由表里可能存在比 Funnel TUN 更具体的系统路由。

也就是说，在 Funnel 看到连接之前，系统已经把“域名”变成了“某个 IP”，并且可能已经决定这个 IP 走另一条 utun。

## 关键现象

实验里观察到过这样的情况：

```text
target.example.com -> controlled-ip
route controlled-prefix -> system-utun
```

如果 Funnel 没有更具体的路由，连接会这样走：

```text
App
  -> 连接 controlled-ip:443
  -> macOS 命中 controlled-prefix 路由
  -> system-utun
  -> 受控页面或连接失败
```

这时请求没有进入 Funnel 的 TUN。sing-box 里就算配置了：

```json
{ "domain_suffix": ["target.example.com"], "outbound": "proxy" }
```

也不会生效，因为 sing-box 根本没有收到这条连接。

## 失败方案一：只调路由规则顺序

早期修过 route/dns rules 的顺序，把目标域名和目标进程规则放在 `ip_is_private -> direct` 前面：

```text
target_domains -> proxy
target_processes -> proxy
private IP -> direct
final -> direct
```

这个修复是必要的，但不充分。原因是：规则顺序只影响已经进入 sing-box 的流量。如果 macOS 在进入 Funnel 之前就把连接交给更具体的系统路由，sing-box 规则没有机会判断。

## 失败方案二：追受控 IP

另一个实验是把受控地址所在的大网段写进 `route_address`：

```json
{
  "route_address": [
    "controlled-prefix/16"
  ]
}
```

这能把目标域名当前解析出来的受控 IP 抢进 Funnel。进入 Funnel 后，sing-box 可以通过 TLS SNI sniff 看到真实域名，再走 proxy：

```text
inbound/tun -> controlled-ip:443
sniff TLS SNI -> target.example.com
outbound/socks -> target.example.com:443
```

但这个方案不稳定，也不专业：

- 它依赖“当前解析出来的受控 IP 恰好在 route_address 里”。
- 如果受控 DNS 换了另一个 IP，要重新追。
- 如果写大网段，会把很多非目标流量也抓进 Funnel。
- 非目标流量进 Funnel 后通常按规则走 `direct`，但这些地址可能原本只能通过系统 utun 访问，于是会超时。
- 日志会出现大量非目标进程的 `outbound/direct` 超时，拖慢启动、停止和网络体验。

实验里能看到大量非目标域名或非目标进程被大网段 route 抓进来，随后 direct 超时。这就是后来移除大网段兜底的原因。

## 稳定方案：DNS hijack + FakeIP

最终方案不再追受控 IP，而是让目标域名在 DNS 阶段就不落到受控地址。

主链路：

```text
1. 系统 DNS 查询进入 Funnel TUN
2. sing-box 对 DNS packet 执行 hijack-dns
3. target_domains 的 A 查询返回 FakeIP，AAAA 查询返回空成功响应
4. App 连接 FakeIP
5. FakeIP 段进入 Funnel TUN
6. sing-box 用 FakeIP 映射找回原始域名
7. route rule 命中 target domain/process
8. proxy outbound 转给本地上游代理
```

更具体地说：

```text
App asks target.example.com A
  -> packet to system-dns:53
  -> route_address 捕获 system-dns/32
  -> sing-box hijack-dns
  -> dns-fake returns 198.18.x.x

App connects 198.18.x.x:443
  -> route_address 捕获 198.18.0.0/15
  -> sing-box finds fakeip domain target.example.com
  -> outbound/socks[proxy] target.example.com:443
  -> local upstream proxy resolves/connects from proxy side
```

这样目标域名不再依赖系统 DNS 返回的真实或受控 IP。系统 DNS 只是一个被捕获的入口，最终响应由 sing-box DNS 模块决定。

## 当前配置结构

Funnel 生成 sing-box 配置的位置：

- `singbox.go`: `GenerateSingboxConfig`
- `config.go`: 默认目标域名、进程、DNS 和 FakeIP 配置

当前使用 sing-box `1.11.x`。这一版使用 legacy FakeIP：

```json
{
  "dns": {
    "servers": [
      {
        "tag": "dns-remote",
        "address": "tcp://1.1.1.1",
        "detour": "proxy"
      },
      {
        "tag": "dns-direct",
        "address": "223.5.5.5",
        "detour": "direct"
      },
      {
        "tag": "dns-fake",
        "address": "fakeip"
      },
      {
        "tag": "dns-empty",
        "address": "rcode://success"
      }
    ],
    "rules": [
      {
        "domain_suffix": ["target.example.com"],
        "query_type": ["AAAA"],
        "server": "dns-empty"
      },
      {
        "domain_suffix": ["target.example.com"],
        "query_type": ["A"],
        "server": "dns-fake"
      },
      {
        "domain_suffix": ["target.example.com"],
        "server": "dns-remote"
      }
    ],
    "final": "dns-direct",
    "reverse_mapping": true,
    "fakeip": {
      "enabled": true,
      "inet4_range": "198.18.0.0/15"
    }
  }
}
```

### DNS servers

`dns-fake` 用于目标域名的 A 查询。它返回 `198.18.0.0/15` 里的 FakeIP。

`dns-empty` 用于目标域名的 AAAA 查询。当前配置没有 IPv6 FakeIP range，也没有给 TUN 配 IPv6 FakeIP 路由，所以 AAAA 不能送到 `dns-fake`。这里返回 `rcode://success`，让客户端得到 NOERROR/NODATA，然后继续使用 A 记录的 IPv4 FakeIP 主路径。

`dns-remote` 通过 proxy 访问远端 DNS，给目标域名的非 A/AAAA 查询以及内部解析使用。

`dns-direct` 给非目标域名使用。它不能配置成会被 Funnel 捕获的系统 DNS，否则 sing-box 自己向外查询 direct DNS 时可能绕回 TUN，形成等待或回环。当前默认是：

```json
{ "tag": "dns-direct", "address": "223.5.5.5", "detour": "direct" }
```

### DNS rules

目标域名的 AAAA 查询必须先命中 `dns-empty`，避免在只有 `inet4_range` 时触发 sing-box 的 IPv6 FakeIP 错误：

```json
{
  "domain_suffix": ["target.example.com"],
  "query_type": ["AAAA"],
  "server": "dns-empty"
}
```

目标域名的 A 查询再命中 `dns-fake`：

```json
{
  "domain_suffix": ["target.example.com"],
  "query_type": ["A"],
  "server": "dns-fake"
}
```

目标域名的其他 DNS 查询再走 `dns-remote`：

```json
{
  "domain_suffix": ["target.example.com"],
  "server": "dns-remote"
}
```

`process_name` 规则也存在，但要理解它的边界：macOS 上很多 DNS 查询实际由系统 resolver 代发，进入 sing-box 时可能不再保留原始应用进程身份。因此 `target_domains` 是稳定主路径，`target_processes` 是连接路由层面的补充。

### Route rules

第一条 route rule 必须是 DNS hijack：

```json
{
  "protocol": "dns",
  "action": "hijack-dns"
}
```

后续才是域名和进程代理规则：

```text
dns packet -> hijack-dns
target_domains -> proxy
target_processes -> proxy
private IP -> direct
final -> direct
```

如果 DNS hijack 不在第一条，DNS packet 可能被其他规则提前处理，目标域名就可能继续走系统 DNS。

### TUN route_address

`route_address` 当前包含：

```json
[
  "198.18.0.0/15",
  "system-dns-1/32",
  "system-dns-2/32"
]
```

这三个东西各自负责不同阶段：

- `system-dns/32`: 把系统 DNS 查询抓进 Funnel。
- `198.18.0.0/15`: 把 FakeIP 连接抓进 Funnel。
- 额外 `route_addresses`: 留给用户手动加特殊路由，但默认不依赖它。

不要再把受控地址的大网段写进默认配置。那是实验手段，不是产品设计。

## 上游代理关系

Funnel 本身不直接提供最终出海能力。它把需要代理的连接交给本地上游代理：

```text
sing-box outbound/socks[proxy]
  -> 127.0.0.1:13658
  -> local upstream proxy
  -> remote network
```

这也是为什么日志里期望看到：

```text
outbound/socks[proxy]: outbound connection to target.example.com:443
```

而不是：

```text
outbound/direct[direct]: outbound connection to controlled-ip:443
```

`proxy` outbound 应尽量保留域名目标，让上游代理在代理侧解析和连接。FakeIP 链路会把 `198.18.x.x` 还原成原始域名，因此能做到这一点。

## 实验记录

### 实验 1：系统 DNS 返回受控地址

无 Funnel 或旧配置下，目标域名可以被系统 DNS 解析到受控地址：

```bash
dscacheutil -q host -a name target.example.com
```

结果类似：

```text
name: target.example.com
ip_address: controlled-ip
```

再看路由：

```bash
route -n get controlled-ip
```

可能看到更具体系统路由，而不是 Funnel TUN。

结论：只做 `domain_suffix -> proxy` 不够，因为连接可能没有进入 sing-box。

### 实验 2：大网段 route_address 能救目标，但副作用大

把受控大网段加入 `route_address` 后，目标连接进入 Funnel，sing-box 可通过 sniff 把它还原成域名：

```text
inbound connection to controlled-ip:443
outbound/socks[proxy]: outbound connection to target.example.com:443
```

但同时大量非目标流量也进入 Funnel：

```text
outbound/direct[direct]: outbound connection to non-target.example:443
connection: open outbound connection: i/o timeout
```

结论：这不是稳定方案。

### 实验 3：FakeIP + hijack-dns 跑通

实验配置要点：

```json
{
  "route": {
    "rules": [
      { "protocol": "dns", "action": "hijack-dns" }
    ]
  },
  "dns": {
    "fakeip": {
      "enabled": true,
      "inet4_range": "198.18.0.0/15"
    }
  },
  "inbounds": [
    {
      "type": "tun",
      "route_address": [
        "198.18.0.0/15",
        "system-dns/32"
      ]
    }
  ]
}
```

验证结果：

```bash
dig +short target.example.com A
# 198.18.x.x

dig +short www.baidu.com A
# 正常真实 IP
```

无环境变量访问目标服务：

```bash
printf 'GET https://chatgpt.com/backend-api/codex/responses\nHTTP *\n' > /tmp/funnel-chatgpt.hurl
env -u ALL_PROXY -u HTTPS_PROXY -u HTTP_PROXY hurl --connect-timeout 10 --max-time 20 --test /tmp/funnel-chatgpt.hurl
```

期望是到达真实上游服务，而不是受控页面。

关键日志：

```text
dns: exchanged A target.example.com. 600 IN A 198.18.x.x
router: found fakeip domain: target.example.com
inbound/tun[tun-in]: inbound connection to 198.18.x.x:443
outbound/socks[proxy]: outbound connection to target.example.com:443
```

结论：这是当前采用的主路径。

## 排查方法

### 1. 看系统 DNS

```bash
scutil --dns | sed -n '1,120p'
cat /etc/resolv.conf
```

macOS 提醒 `/etc/resolv.conf` 不一定是所有进程的真实 resolver 配置，但 Funnel 当前用它提取系统 DNS 地址并写入 `route_address`。如果未来要更精确，应解析 `scutil --dns` 输出。

### 2. 看路由

```bash
route -n get system-dns
route -n get 198.18.0.3
```

Funnel 运行后应看到：

```text
system-dns -> Funnel utun
198.18.0.0/15 -> Funnel utun
```

### 3. 看 DNS 结果

```bash
dig +short target.example.com A
dig +short target.example.com AAAA
dig +short www.baidu.com A
```

目标域名的 A 应该返回 FakeIP，AAAA 应该返回空成功响应。非目标域名应该返回真实 IP。

### 4. 看 sing-box 日志

```bash
tail -200 ~/.funnel/singbox.log
```

目标域名的健康链路：

```text
dns-fake
found fakeip domain
outbound/socks[proxy]
```

异常链路：

```text
target domain -> controlled-ip
outbound/direct[direct]
i/o timeout
```

### 5. 看 helper 状态

```bash
printf '{"action":"status"}\n' | nc -U /var/run/funnel.sock
```

helper 负责以 root 权限启动 sing-box。启停慢通常不是 UI 问题，而是 sing-box 子进程或路由清理卡住。

## Agent 排查手册

这一节面向后续接手的 Agent。先按现象分层，不要一上来改 route rule 或加大网段。

### 0. 先定时间窗口

用户通常会给出类似“18:31:15 左右”的时间。先用这个窗口看 `~/.funnel/singbox.log`，不要只看最新 20 行：

```bash
rg '18:31|18:32|chatgpt|openai|198\.18|outbound/socks|missing IPv6|inbound/tun|exchanged A|exchanged AAAA' ~/.funnel/singbox.log
```

同时看运行态：

```bash
ps -axo %cpu,%mem,pid,command | rg 'Funnel\.app|sing-box|funnel-helper|Codex|codex'
printf '{"action":"status"}\n' | nc -U /var/run/funnel.sock
```

### 1. 判断 Codex 到底有没有带 env proxy

不要凭启动命令判断。Electron 可能复用已有主进程，也可能读系统 PAC。

```bash
ps eww -p <codex-main-pid>,<network-service-pid> -o pid=,command= \
  | rg 'ALL_PROXY|HTTPS_PROXY|HTTP_PROXY|NO_PROXY|all_proxy|https_proxy|http_proxy|no_proxy'
lsof -nP -iTCP -sTCP:ESTABLISHED | rg 'Codex|codex|13658|198\.18'
scutil --proxy
```

判读：

- 有 `ALL_PROXY/HTTPS_PROXY/HTTP_PROXY`：这是 env proxy，不是 Funnel FakeIP 主链路。
- 无 proxy env，但 `scutil --proxy` 有 `ProxyAutoConfigURLString`：Chromium/Electron 可能通过系统 PAC 连 `127.0.0.1:13658`。
- 看到 `Codex -> 127.0.0.1:13658` 不等于 Funnel 坏；要继续看 sing-box 是否也有 FakeIP 健康链路。

### 2. 判断 DNS/FakeIP 是否健康

先看生成配置：

```bash
jq '.dns.servers, .dns.rules[0:3], .dns.fakeip, .inbounds[0].route_address, .route.rules' ~/.funnel/singbox.json
/Users/hanger/.funnel/sing-box check -c ~/.funnel/singbox.json
```

期望：

```text
dns-empty address = rcode://success
target AAAA -> dns-empty
target A -> dns-fake
fakeip.inet4_range = 198.18.0.0/15
route.rules[0] = protocol:dns + action:hijack-dns
route_address contains 198.18.0.0/15 and system DNS /32
```

再看 DNS 结果：

```bash
dig +short chatgpt.com A
dig +short chatgpt.com AAAA
```

期望 A 是 `198.18.x.x`，AAAA 没有地址。如果日志出现：

```text
missing IPv6 fakeip address range
```

说明 AAAA 又被送到了 `dns-fake`，或者有人加了会覆盖这条规则的 DNS rule。不要用 reject 处理它；当前设计是 `AAAA -> rcode://success`。

### 3. 判断 FakeIP 连接是否进入 TUN

DNS 正常后，连接还必须走进 TUN：

```bash
route -n get 198.18.0.3
netstat -rn -f inet | rg '198\.18|172\.19|30\.30|8\.8\.8\.8'
```

期望 `198.18.0.0/15` 指向 Funnel 的 `utun`。健康日志应该出现：

```text
inbound/tun[tun-in]: inbound connection to 198.18.x.x:443
outbound/socks[proxy]: outbound connection to chatgpt.com:443
```

如果 `dig` 返回 FakeIP，但没有 `inbound/tun -> 198.18`，问题在路由或当前 sing-box/TUN 运行态，不在 DNS 规则。

### 4. 判断上游代理是否健康

Funnel 只负责把目标连接交给上游 `127.0.0.1:13658`，上游本身还要单独测：

```bash
printf 'GET https://chatgpt.com/backend-api/codex/responses\nHTTP *\n' > /tmp/funnel-chatgpt.hurl
env -u ALL_PROXY -u HTTPS_PROXY -u HTTP_PROXY -u all_proxy -u https_proxy -u http_proxy \
  hurl --connect-timeout 10 --max-time 20 --test /tmp/funnel-chatgpt.hurl

env -u HTTPS_PROXY -u HTTP_PROXY -u https_proxy -u http_proxy \
  ALL_PROXY=socks5://127.0.0.1:13658 \
  go -C experiments/netprobe run . -url https://chatgpt.com/backend-api/codex/responses -timeout 20s
```

第一条测 Funnel FakeIP 主链路，第二条测直接上游代理。`GET /backend-api/codex/responses` 返回 `405 Method Not Allowed` 是好信号，表示已经到达真实 ChatGPT 服务。

### 5. 常见误判

- `dns.google:443` 或 `8.8.8.8:443` 探测不是 ChatGPT 主请求。不要在目标规则前面加 reject；reject 很容易把 Chromium/Codex 的网络栈打断。
- `Codex -> 127.0.0.1:13658` 不一定是 env proxy，系统 PAC 也会导致这个结果。
- sing-box 日志里的 `router: found process path` 可能显示系统扩展或 CloudShell，不一定是最终用户应用。FakeIP 能靠反向映射还原域名，因此健康链路的关键是 `outbound/socks[proxy] -> chatgpt.com`。
- `target_processes` 不是严格的“任意域名都代理”保证。macOS DNS 经常由系统 resolver 代发，稳定主路径还是 `target_domains`。
- 不要用受控大网段兜底。短期可能救一个域名，长期会把大量非目标流量卷进 TUN，带来 CPU、日志和超时问题。

### 6. 修复后必须回归

每次改网络配置生成后至少跑：

```bash
go test ./...
go test ./...   # helper 目录
go build ./...
make build
/Users/hanger/.funnel/sing-box check -c ~/.funnel/singbox.json
```

运行态再测：

```bash
dig +short chatgpt.com A
dig +short chatgpt.com AAAA
env -u ALL_PROXY -u HTTPS_PROXY -u HTTP_PROXY -u all_proxy -u https_proxy -u http_proxy \
  hurl --connect-timeout 10 --max-time 20 --test /tmp/funnel-chatgpt.hurl
```

最后看 CPU，确认没有把非目标大网段卷进来：

```bash
ps -axo %cpu,%mem,pid,command | rg 'Funnel\.app|sing-box|funnel-helper|Codex|codex'
```

## 代码修改注意事项

### 不要随意改掉 DNS hijack

`protocol=dns -> hijack-dns` 是主路径入口。去掉它，目标域名会重新依赖系统 DNS。

### 不要把 `dns-direct` 指向被捕获的系统 DNS

如果 `dns-direct` 指向系统 DNS，而系统 DNS 又在 `route_address` 里，sing-box 自己发起 direct DNS 查询时可能再次进入自身 TUN，造成等待或回环。

### 不要把目标 AAAA 送到 IPv4-only FakeIP

当前只配置了 `dns.fakeip.inet4_range` 和 IPv4 `route_address`。目标域名的 AAAA 必须先走 `dns-empty`，再让 A 走 `dns-fake`。如果把 A 和 AAAA 都送到 `dns-fake`，sing-box 会报 `missing IPv6 fakeip address range`，客户端可能卡到超时或出现 Broken pipe。

### 不要默认添加受控大网段

大网段会把非目标流量卷入 Funnel。默认配置只能包含 FakeIP 段和系统 DNS 地址。

### 目标域名优先于目标进程

在 macOS 上，域名是更稳定的控制面。进程规则用于连接层补充，但不要把“按进程捕获任意未知域名 DNS”当作已经严格成立的能力。

### sing-box 版本升级要小心

当前代码针对 sing-box `1.11.x`。FakeIP 在后续版本有迁移：

- 1.11 使用 legacy `dns.fakeip`。
- 1.12 引入 fakeip DNS server。
- 1.14 移除 legacy fake-ip，并新增/调整 TUN `dns_mode` 等能力。

如果升级 sing-box，需要同步改配置生成和测试，不要只改下载版本号。

## 当前限制

`target_domains` 是当前真正稳定的主路径。只要域名在列表里，A 会返回 FakeIP，AAAA 会返回空成功响应，后续连接通过 IPv4 FakeIP 进入 Funnel，并以域名形式交给上游代理。

`target_processes` 对已经进入 TUN 的连接有效。但进程的 DNS 查询在 macOS 上可能由系统组件代发，未必能可靠以原进程身份匹配 DNS rule。

如果未来必须保证“某个进程的任意域名都严格走代理”，可能需要以下方向之一：

- 全局 TUN + 全局 DNS hijack，再对非目标流量做更完整的 direct 规则。
- Network Extension / App Proxy 级别按应用代理。
- 让目标应用显式使用本地代理入口。

## 验证清单

修改网络配置后至少跑：

```bash
go test ./...
go test ./...   # helper 目录
go build ./...
make build
/Users/hanger/.funnel/sing-box check -c ~/.funnel/singbox.json
```

启动 Funnel 后验证：

```bash
dig +short target.example.com A
# 期望：198.18.0.0/15 内的 FakeIP

dig +short www.baidu.com A
# 期望：真实直连 DNS 结果，不是 FakeIP

printf 'GET https://chatgpt.com/backend-api/codex/responses\nHTTP *\n' > /tmp/funnel-chatgpt.hurl
env -u ALL_PROXY -u HTTPS_PROXY -u HTTP_PROXY hurl --connect-timeout 10 --max-time 20 --test /tmp/funnel-chatgpt.hurl
# 期望：到达真实上游服务
```

还要检查生成配置：

```bash
jq '.dns.fakeip, .route.rules[0], .inbounds[0].route_address' ~/.funnel/singbox.json
```

期望：

```text
dns.fakeip.enabled = true
route.rules[0].action = hijack-dns
route_address contains 198.18.0.0/15 and system DNS /32
```
