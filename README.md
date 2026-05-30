# Funnel

macOS 菜单栏工具，通过 TUN + DNS hijack + FakeIP + 路由规则，**让指定域名和目标 App 稳定走本地上游代理**，其余流量默认直连。

## 原理

```
系统 DNS 查询 → Funnel TUN → sing-box hijack-dns
  ├── target_domains 的 A → 返回 FakeIP（198.18.0.0/15）
  ├── target_domains 的 AAAA → 返回空成功响应
  └── 其他域名 → direct DNS

App 连接 FakeIP → Funnel TUN → sing-box 找回原始域名
  ├── domain_suffix 匹配（openai.com/chatgpt.com/...）→ 上游代理
  ├── process_name 匹配（Codex/Antigravity/...）→ 上游代理
  └── 其余流量 → 直连
```

与全局 TUN 代理的区别：`route.final = "direct"`，只有匹配的进程或域名走代理。

详细背景、DNS/FakeIP 设计和排查方法见 [docs/network-design.md](docs/network-design.md)。

## 典型用途

- **Codex App 登录**：Codex 的 OAuth token exchange 不走系统代理，需要 TUN 强制代理
- **Antigravity IDE**：IDE 相关进程走代理
- **任何需要翻墙的 GUI App**：配置进程名即可

## 安装

```bash
# 编译
make build

# 安装到 /Applications
make install
```

首次启动会弹出系统授权框安装 helper（仅一次）。

## 配置

配置文件：`~/.funnel/config.json`

首次启动自动生成默认配置。

### 上游代理模式（推荐）

指向本地已有的代理（V2RayX、Clash 等）：

```json
{
  "upstream": {
    "type": "socks5",
    "host": "127.0.0.1",
    "port": 13658
  },
  "target_processes": [
    "Codex",
    "Codex Helper",
    "Codex Helper (Renderer)",
    "Codex Helper (GPU)",
    "Codex Helper (Plugin)",
    "Antigravity",
    "Antigravity Helper",
    "Antigravity Helper (Renderer)"
  ],
  "target_domains": [
    "openai.com",
    "auth.openai.com",
    "api.openai.com",
    "chatgpt.com",
    "oaistatic.com",
    "oaiusercontent.com"
  ],
  "direct_dns": "223.5.5.5",
  "fake_ip_range": "198.18.0.0/15",
  "log_level": "info"
}
```

### 直连节点模式

不依赖本地代理，直接配置节点：

```json
{
  "nodes": [
    {
      "name": "我的节点",
      "type": "vmess",
      "server": "example.com",
      "port": 443,
      "uuid": "xxx-xxx-xxx"
    }
  ],
  "selected_node": 0,
  "target_processes": ["Codex", "Codex Helper", "Codex Helper (Renderer)"],
  "target_domains": ["openai.com"]
}
```

### 配置项

| 字段 | 说明 |
|---|---|
| `upstream.type` | 上游代理类型：`socks5` 或 `http` |
| `upstream.host` | 上游代理地址（通常 `127.0.0.1`） |
| `upstream.port` | 上游代理端口 |
| `target_processes` | 要代理的进程名列表 |
| `target_domains` | 要代理的域名后缀列表；A 查询返回 FakeIP，AAAA 查询返回空成功响应 |
| `direct_dns` | 非目标域名的直连 DNS；不要设成会被 TUN 捕获的系统 DNS |
| `fake_ip_range` | 目标域名 A 查询返回的 FakeIP 段 |
| `route_addresses` | 额外强制进入 TUN 的地址段；通常不需要配置 |
| `nodes` | 直连节点列表（upstream 优先） |
| `log_level` | sing-box 日志级别：trace/debug/info/warn/error |

### 路由优先级

1. DNS 请求 → hijack 到 sing-box DNS
2. `target_domains` 匹配 → 走代理（不管哪个进程）
3. `target_processes` 匹配 → 走代理
4. 私有 IP → 直连
5. 其余 → 直连

注意：`target_domains` 是稳定主路径。macOS 上 DNS 查询常由系统 resolver 代发，因此“按进程捕获任意未知域名 DNS”不能只靠当前 split TUN 方案严格保证；详见设计文档。

## 如何找到 App 的进程名

```bash
# 方法 1：Activity Monitor 里看
# 方法 2：命令行
ps aux | grep -i "codex" | grep -v grep
```

常见 App 进程名：

| App | 进程名 |
|---|---|
| Codex | `Codex`, `Codex Helper`, `Codex Helper (Renderer)`, `Codex Helper (GPU)`, `Codex Helper (Plugin)` |
| Antigravity | `Antigravity`, `Antigravity Helper`, ... |
| Claude | `Claude`, `Claude Helper`, `Claude Helper (Renderer)` |
| Cursor | `Cursor`, `Cursor Helper`, `Cursor Helper (Renderer)` |

## 日志

- 应用日志：`~/.funnel/funnel.log`
- sing-box 日志：`~/.funnel/singbox.log`
- Helper 日志：`/var/log/funnel-helper.log`

## 快速排查

核心判断标准见 [docs/network-design.md](docs/network-design.md#agent-排查手册)。目标域名的健康链路应该长这样：

```text
dns: exchanged A chatgpt.com. ... A 198.18.x.x
inbound/tun[tun-in]: inbound connection to 198.18.x.x:443
outbound/socks[proxy]: outbound connection to chatgpt.com:443
```

如果只看到 Codex 连接 `127.0.0.1:13658`，先区分它是环境变量代理还是系统 PAC：

```bash
ps eww -p <codex-pid> -o command= | rg 'ALL_PROXY|HTTPS_PROXY|HTTP_PROXY|NO_PROXY'
scutil --proxy
```

没有 proxy env 但仍连接 `127.0.0.1:13658`，通常是 Chromium/Electron 读到了系统 PAC，不代表 Funnel 的 FakeIP 链路坏了。

## 依赖

- sing-box 1.11.x（首次启动自动下载）
- macOS Security.framework（helper 安装授权）
