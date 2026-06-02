#!/bin/zsh
set -u

# Experiment: DNS/IP snapshot under "intranet software + VPN" network state.
#
# Intent:
# - Inspect current system DNS behavior for representative external domains.
# - Compare dig, dscacheutil, and Python libc resolver output.
# - Include ChatGPT/OpenAI domains, Google domains, and a non-target control.
# - Set FUNNEL_CHECK_COMMON_WITH_HELPER=1 to start an isolated github.com-only
#   Funnel config first, then verify common non-target domains are not forced
#   into FakeIP/TUN.
#
# Safety:
# - Does not start Funnel.
# - Does not open Funnel.app.
# - Does not modify /etc/resolver or system network settings.
# - With FUNNEL_CHECK_COMMON_WITH_HELPER=1, starts helper-managed sing-box and
#   stops it at the end.
#
# Output:
# - Probe log: /tmp/funnel-vpn-dns-ip-snapshot-chatgpt-google-openai.log
#
# Experiment record:
# - Ran at 2026-06-03 01:27 +0800 under the "intranet software + VPN" state.
# - Current helper status:
#   - helper socket returned {"ok":true,"message":"stopped"}.
#   - No Funnel-managed /etc/resolver files existed for the probed domains.
# - Resolver summary:
#   - scutil --dns resolver #1 used nameserver 30.30.30.30.
#   - Scoped resolver on en0 also used 30.30.30.30.
# - Domain observations:
#   - chatgpt.com:
#     - A: 59.82.113.122.
#     - No AAAA in dig output.
#     - dscacheutil and Python resolved to 59.82.113.122.
#   - openai.com:
#     - A: 172.64.154.211, 104.18.33.45.
#     - dscacheutil/Python resolved the same A set.
#   - api.openai.com:
#     - A: 162.159.140.245, 172.66.0.243.
#   - auth.openai.com:
#     - CNAME: auth.openai.com.cdn.cloudflare.net.
#     - A: 172.64.146.15, 104.18.41.241.
#     - AAAA: 2a06:98c1:3106::ac40:920f,
#       2606:4700:4406::6812:29f1.
#   - oaistatic.com:
#     - A: 104.18.41.158, 172.64.146.98.
#     - AAAA: 2606:4700:440c::6812:299e,
#       2a06:98c1:3104::ac40:9262.
#   - oaiusercontent.com:
#     - dig A/AAAA had no short output.
#     - Python getaddrinfo failed with socket.gaierror Errno 8.
#   - google.com:
#     - A: 142.250.197.110.
#     - AAAA: 2404:6800:4005:812::200e.
#   - www.google.com:
#     - A: 142.251.150.119 through 142.251.157.119 variants.
#     - AAAA: 2001:4860:4826:7700:: through 2001:4860:482d:7700::
#       variants.
#   - github.com:
#     - A: 20.205.243.166.
#   - www.baidu.com:
#     - dig A: CNAME www.a.shifen.com, A 153.3.238.127 and 153.3.238.28.
#     - dscacheutil/Python returned A 180.101.51.73 and 180.101.49.44,
#       showing dig and macOS/libc resolver can differ in this network state.
# - Conclusion:
#   - In the current VPN state, baseline system DNS is 30.30.30.30 and
#     chatgpt.com is resolved to 59.82.113.122 without Funnel.
#   - Google and most OpenAI domains resolve normally to public Cloudflare/
#     Google addresses, while oaiusercontent.com does not resolve in this
#     snapshot.
#   - dig and macOS/libc resolver results can diverge; for app behavior, prefer
#     dscacheutil or socket.getaddrinfo over plain dig.
# - Common-domain impact run at 2026-06-03 01:32 +0800 with
#   FUNNEL_CHECK_COMMON_WITH_HELPER=1:
#   - Started an isolated helper-managed Funnel config whose only target domain
#     was github.com.
#   - Only /etc/resolver/github.com existed. No resolver files existed for
#     chatgpt.com/openai/google/baidu or the common-domain set.
#   - github.com resolved through macOS/libc to FakeIP 198.18.0.3.
#   - Common non-target domains resolved to real IPs, not FakeIP:
#     - apple.com -> 17.253.144.10
#     - www.apple.com -> 122.228.243.* CDN IPs
#     - microsoft.com -> 150.171.110.98
#     - www.microsoft.com -> 61.147.219.124
#     - taobao.com -> 59.82.* IPs
#     - www.taobao.com -> 122.228.243.67/70
#     - alibaba.com -> 203.119.207.11
#     - dingtalk.com -> 106.11.* IPs
#     - zhihu.com -> 182.61.194.9
#     - bilibili.com -> 119.3.70.188 / 139.159.241.37 /
#       8.134.50.24 / 47.103.24.173
#     - npmjs.com -> 104.17.134.117 / 104.17.135.117
#     - pypi.org -> 151.101.* IPs
#   - Python TCP connect to port 443 succeeded for every common non-target
#     domain tested.
#   - sing-box evidence only showed:
#     - inbound/tun started.
#     - direct DNS exchange for github.com -> 198.18.0.3.
#     - No common-domain inbound/tun connection and no common-domain
#       outbound/socks connection.
# - Common-domain impact conclusion:
#   - With only github.com targeted, ordinary domains were not forced into
#     FakeIP and did not appear to enter Funnel's TUN/proxy path in this run.
#   - The new domain-scoped resolver approach affects only domains with
#     /etc/resolver entries.

LOG=/tmp/funnel-vpn-dns-ip-snapshot-chatgpt-google-openai.log
: > "$LOG"

DOMAINS=(
  chatgpt.com
  openai.com
  api.openai.com
  auth.openai.com
  oaistatic.com
  oaiusercontent.com
  google.com
  www.google.com
  github.com
  www.baidu.com
)

COMMON_DOMAINS=(
  apple.com
  www.apple.com
  microsoft.com
  www.microsoft.com
  taobao.com
  www.taobao.com
  alibaba.com
  dingtalk.com
  zhihu.com
  bilibili.com
  npmjs.com
  pypi.org
)

SOCK=/var/run/funnel.sock
BASE=/tmp/funnel-github-with-system-dns.json
CONFIG=/tmp/funnel-common-domains-nontarget-impact-check.json
SINGLOG=/tmp/funnel-common-domains-nontarget-impact-check-singbox.log

ts() {
  date "+%Y-%m-%d %H:%M:%S %z"
}

log() {
  echo "$@" | tee -a "$LOG"
}

log "SCRIPT_BEGIN $(ts)"

if [[ "${FUNNEL_CHECK_COMMON_WITH_HELPER:-}" == "1" ]]; then
  log "FUNNEL_COMMON_CHECK_START $(ts)"
  : > "$SINGLOG"
  jq '.inbounds[0].route_address=["198.18.0.0/15"] | .inbounds[0].route_exclude_address=["223.5.5.5/32"] | .inbounds[0].strict_route=false | .inbounds += [{"type":"direct","tag":"dns-in","listen":"127.0.0.1","listen_port":53535,"network":"udp","override_address":"8.8.8.8","override_port":53}] | .route.rules=([{"inbound":["dns-in"],"action":"hijack-dns"}] + .route.rules) | .log.level="info"' "$BASE" > "$CONFIG"
  printf '{"action":"stop"}\n' | nc -U "$SOCK" 2>&1 | sed 's/^/FUNNEL_STOP_BEFORE /' | tee -a "$LOG" || true
  printf '{"action":"start","binary_path":"/Users/hanger/.funnel/sing-box","config_path":"%s","log_path":"%s","target_domains":["github.com"]}\n' "$CONFIG" "$SINGLOG" | nc -U "$SOCK" 2>&1 | sed 's/^/FUNNEL_START /' | tee -a "$LOG" || true
  sleep 2
fi

log "HELPER_STATUS"
printf '{"action":"status"}\n' | nc -U /var/run/funnel.sock 2>&1 | sed 's/^/HELPER_STATUS /' | tee -a "$LOG" || true

log "RESOLVER_FILES"
for domain in "${DOMAINS[@]}"; do
  if [[ -f "/etc/resolver/$domain" ]]; then
    echo "RESOLVER_FILE_BEGIN $domain" | tee -a "$LOG"
    sed "s/^/RESOLVER_FILE_$domain /" "/etc/resolver/$domain" | tee -a "$LOG"
    echo "RESOLVER_FILE_END $domain" | tee -a "$LOG"
  else
    echo "RESOLVER_FILE_MISSING $domain" | tee -a "$LOG"
  fi
done

log "SCUTIL_DNS_HEAD"
scutil --dns 2>&1 | sed -n '1,80p' | sed 's/^/SCUTIL_DNS_HEAD /' | tee -a "$LOG" || true

for domain in "${DOMAINS[@]}"; do
  safe_name=$(echo "$domain" | tr '.-' '__')

  log "DOMAIN_BEGIN $domain"

  log "DIG_A $domain"
  dig +time=3 +tries=1 +short "$domain" A 2>&1 | sed "s/^/DIG_A_$safe_name /" | tee -a "$LOG" || true

  log "DIG_AAAA $domain"
  dig +time=3 +tries=1 +short "$domain" AAAA 2>&1 | sed "s/^/DIG_AAAA_$safe_name /" | tee -a "$LOG" || true

  log "DSCACHEUTIL $domain"
  dscacheutil -q host -a name "$domain" 2>&1 | sed "s/^/DSCACHEUTIL_$safe_name /" | tee -a "$LOG" || true

  log "PYTHON_GETADDRINFO $domain"
  python3 -c 'import socket,sys; d=sys.argv[1]; print(socket.getaddrinfo(d,443,socket.AF_UNSPEC,socket.SOCK_STREAM))' "$domain" 2>&1 | sed "s/^/PYTHON_GETADDRINFO_$safe_name /" | tee -a "$LOG" || true

  log "DOMAIN_END $domain"
done

if [[ "${FUNNEL_CHECK_COMMON_WITH_HELPER:-}" == "1" ]]; then
  for domain in "${COMMON_DOMAINS[@]}"; do
    safe_name=$(echo "$domain" | tr '.-' '__')

    log "COMMON_DOMAIN_BEGIN $domain"

    log "COMMON_DSCACHEUTIL $domain"
    dscacheutil -q host -a name "$domain" 2>&1 | sed "s/^/COMMON_DSCACHEUTIL_$safe_name /" | tee -a "$LOG" || true

    log "COMMON_PYTHON_GETADDRINFO $domain"
    python3 -c 'import socket,sys; d=sys.argv[1]; print(socket.getaddrinfo(d,443,socket.AF_INET,socket.SOCK_STREAM))' "$domain" 2>&1 | sed "s/^/COMMON_PYTHON_GETADDRINFO_$safe_name /" | tee -a "$LOG" || true

    log "COMMON_PYTHON_TCP $domain"
    python3 -c 'import socket,sys; d=sys.argv[1]; s=socket.create_connection((d,443),timeout=5); print("CONNECTED", d, s.getpeername()); s.close()' "$domain" 2>&1 | sed "s/^/COMMON_PYTHON_TCP_$safe_name /" | tee -a "$LOG" || true

    log "COMMON_DOMAIN_END $domain"
  done

  log "FUNNEL_COMMON_SINGBOX_EVIDENCE"
  grep -E '198\.18|inbound/tun|outbound/socks|outbound/direct|dns: exchanged' "$SINGLOG" 2>&1 | sed 's/^/FUNNEL_COMMON_SINGBOX_EVIDENCE /' | tee -a "$LOG" || true

  log "FUNNEL_COMMON_CHECK_STOP"
  printf '{"action":"stop"}\n' | nc -U "$SOCK" 2>&1 | sed 's/^/FUNNEL_STOP_AFTER /' | tee -a "$LOG" || true
fi

log "SCRIPT_DONE $(ts)"
log "LOG_PATH $LOG"
