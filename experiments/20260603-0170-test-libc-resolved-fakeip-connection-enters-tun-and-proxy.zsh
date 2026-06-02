#!/bin/zsh
set -u

# Experiment: verify libc-resolved FakeIP connection enters TUN and proxy.
#
# Intent:
# - Do not open Funnel.app.
# - Use updated helper socket with isolated config.
# - Let macOS/libc resolve target domains through /etc/resolver to FakeIP.
# - Open a real TLS connection to github.com:443 from Python.
# - Verify sing-box logs show inbound to FakeIP and outbound/proxy to the
#   original domain.
#
# Safety:
# - Default mode starts from /tmp/funnel-github-with-system-dns.json, whose only
#   target domain is github.com.
# - Set FUNNEL_EXPERIMENT_INCLUDE_OPENAI=1 only when intentionally testing the
#   real OpenAI/ChatGPT target domains under the current network state.
# - Stops helper-managed sing-box at the end.
#
# Output:
# - Probe log: /tmp/funnel-libc-fakeip-connection-e2e-experiment.log
# - Isolated sing-box log: /tmp/funnel-libc-fakeip-connection-e2e-singbox.log
# - Derived config: /tmp/funnel-github-libc-fakeip-connection-e2e.json
#
# Experiment record:
# - Ran at 2026-06-03 01:20 +0800.
# - Observed phenomenon:
#   - /etc/resolver/github.com existed and pointed to 127.0.0.1 port 53535.
#   - dscacheutil -q host -a name github.com returned FakeIP 198.18.0.3.
#   - Python socket.getaddrinfo("github.com", 443, AF_INET, SOCK_STREAM)
#     returned 198.18.0.3.
#   - Python TLS connection to github.com:443 succeeded with TLSv1.3 and a
#     github.com certificate.
#   - plain dig www.baidu.com A resolved normally.
#   - sing-box log evidence:
#     - dns: exchanged A github.com -> 198.18.0.3.
#     - inbound/tun[tun-in]: inbound connection to 198.18.0.3:443.
#     - outbound/socks[proxy]: outbound connection to github.com:443.
# - Conclusion:
#   - The resolver-file + local DNS inbound + FakeIP + TUN route chain works
#     end to end for a libc-resolved client.
#   - The fix avoids capturing the system DNS/default gateway and still routes
#     target-domain connections through the proxy.
#   - Non-target DNS remained healthy in this run.
# - Scenario 1 run at 2026-06-03 01:23 +0800: "先打开内网软件".
#   - This reused the same script and did not open Funnel.app.
#   - dscacheutil github.com returned 198.18.0.3.
#   - Python socket.getaddrinfo returned 198.18.0.3.
#   - Python TLS connection to github.com:443 succeeded with TLSv1.3 and a
#     github.com certificate.
#   - plain dig www.baidu.com A resolved normally.
#   - sing-box log evidence:
#     - dns: exchanged A github.com -> 198.18.0.3.
#     - inbound/tun[tun-in]: inbound connection to 198.18.0.3:443.
#     - outbound/socks[proxy]: outbound connection to github.com:443.
#   - Scenario 1 conclusion:
#     - With the intranet software already open, the resolver-file + local DNS
#       inbound + FakeIP + TUN route chain still works end to end.
#     - This validates scenario 1 only. Scenario 2 (打开自动入网) and scenario 3
#       (打开 VPN) still need separate runs under those network states.
# - Scenario 2 run at 2026-06-03 01:24 +0800:
#   "先打开内网软件（打开自动入网）".
#   - This reused the same script and did not open Funnel.app.
#   - dscacheutil github.com returned 198.18.0.3.
#   - Python socket.getaddrinfo returned 198.18.0.3.
#   - Python TLS connection to github.com:443 succeeded with TLSv1.3 and a
#     github.com certificate.
#   - plain dig www.baidu.com A resolved normally, but returned 180.101.51.73
#     and 180.101.49.44 instead of the scenario 1 223.109.* addresses, showing
#     the network/DNS state changed under automatic intranet access.
#   - sing-box log evidence:
#     - dns: exchanged A github.com -> 198.18.0.3.
#     - inbound/tun[tun-in]: inbound connection to 198.18.0.3:443.
#     - outbound/socks[proxy]: outbound connection to github.com:443.
#   - Scenario 2 conclusion:
#     - With automatic intranet access enabled, the resolver-file + local DNS
#       inbound + FakeIP + TUN route chain still works end to end.
#     - Non-target DNS remained healthy in this run.
#     - This validates scenario 2. Scenario 3 (打开 VPN) still needs a separate
#       run under that network state.
# - Scenario 3 run at 2026-06-03 01:25 +0800:
#   "先打开内网软件（打开 VPN）".
#   - This reused the same script and did not open Funnel.app.
#   - dscacheutil github.com returned 198.18.0.3.
#   - Python socket.getaddrinfo returned 198.18.0.3.
#   - Python TLS connection to github.com:443 succeeded with TLSv1.3 and a
#     github.com certificate.
#   - plain dig www.baidu.com A resolved normally, returning 153.3.238.127 and
#     153.3.238.28. This differs from both scenario 1 and scenario 2, confirming
#     the VPN state changed the non-target DNS environment.
#   - sing-box log evidence:
#     - dns: exchanged A github.com -> 198.18.0.3.
#     - inbound/tun[tun-in]: inbound connection to 198.18.0.3:443.
#     - outbound/socks[proxy]: outbound connection to github.com:443.
#   - Scenario 3 conclusion:
#     - With VPN enabled, the resolver-file + local DNS inbound + FakeIP + TUN
#       route chain still works end to end.
#     - Non-target DNS remained healthy in this run.
#     - This validates all three requested network-state scenarios.
# - VPN domain sweep at 2026-06-03 01:30 +0800 with
#   FUNNEL_EXPERIMENT_INCLUDE_OPENAI=1:
#   - This run intentionally included chatgpt.com/openai.com/api.openai.com/
#     auth.openai.com/oaistatic.com/oaiusercontent.com/google.com/
#     www.google.com/github.com in the isolated target domain set.
#   - All probed target domains had /etc/resolver files pointing to
#     127.0.0.1:53535.
#   - macOS/libc resolver results:
#     - chatgpt.com -> 198.18.0.3
#     - openai.com -> 198.18.0.4
#     - api.openai.com -> 198.18.0.5
#     - auth.openai.com -> 198.18.0.6
#     - oaistatic.com -> 198.18.0.7
#     - oaiusercontent.com -> 198.18.0.8
#     - google.com -> 198.18.0.9
#     - www.google.com -> 198.18.0.10
#     - github.com -> 198.18.0.11
#   - Python TLS connection to chatgpt.com:443 succeeded with TLSv1.3 and a
#     chatgpt.com certificate.
#   - sing-box log evidence:
#     - dns exchanged A records for all listed domains to their FakeIP values.
#     - inbound/tun[tun-in]: inbound connection to 198.18.0.3:443.
#     - outbound/socks[proxy]: outbound connection to chatgpt.com:443.
#   - Non-target www.baidu.com resolved normally to 180.101.49.44 and
#     180.101.51.73.
#   - VPN domain sweep conclusion:
#     - With Funnel running, these target domains do get FakeIP through the
#       macOS/libc resolver path.
#     - The observed chatgpt.com TLS request did enter Funnel's TUN and exited
#       via the socks proxy.
#     - The previous DNS/IP snapshot with helper stopped was only a baseline;
#       it did not test FakeIP/TUN routing.

SOCK=/var/run/funnel.sock
BASE=/tmp/funnel-github-with-system-dns.json
CONFIG=/tmp/funnel-github-libc-fakeip-connection-e2e.json
LOG=/tmp/funnel-libc-fakeip-connection-e2e-experiment.log
SINGLOG=/tmp/funnel-libc-fakeip-connection-e2e-singbox.log
TARGET_DOMAINS=(github.com)
TLS_DOMAIN=github.com

if [[ "${FUNNEL_EXPERIMENT_INCLUDE_OPENAI:-}" == "1" ]]; then
  TARGET_DOMAINS=(chatgpt.com openai.com api.openai.com auth.openai.com oaistatic.com oaiusercontent.com google.com www.google.com github.com)
  TLS_DOMAIN=chatgpt.com
fi

: > "$LOG"
: > "$SINGLOG"

ts() {
  date "+%Y-%m-%d %H:%M:%S %z"
}

log() {
  echo "$@" | tee -a "$LOG"
}

helper() {
  printf '%s\n' "$1" | nc -U "$SOCK" 2>&1 | tee -a "$LOG"
}

make_config() {
  jq '.inbounds[0].route_address=["198.18.0.0/15"] | .inbounds[0].route_exclude_address=["223.5.5.5/32"] | .inbounds[0].strict_route=false | .inbounds += [{"type":"direct","tag":"dns-in","listen":"127.0.0.1","listen_port":53535,"network":"udp","override_address":"8.8.8.8","override_port":53}] | .route.rules=([{"inbound":["dns-in"],"action":"hijack-dns"}] + .route.rules) | .log.level="info"' "$BASE" > "$CONFIG"
  if [[ "${FUNNEL_EXPERIMENT_INCLUDE_OPENAI:-}" == "1" ]]; then
    jq --argjson domains '["chatgpt.com","openai.com","api.openai.com","auth.openai.com","oaistatic.com","oaiusercontent.com","google.com","www.google.com","github.com"]' '
      .dns.rules = (.dns.rules | map(if has("domain_suffix") then .domain_suffix=$domains else . end)) |
      .route.rules = (.route.rules | map(if has("domain_suffix") then .domain_suffix=$domains else . end))
    ' "$CONFIG" > "$CONFIG.tmp" && mv "$CONFIG.tmp" "$CONFIG"
  fi
}

log "SCRIPT_BEGIN $(ts)"
make_config
helper '{"action":"stop"}' || true

(
  sleep 15
  echo "AUTO_STOP_FIRE $(ts)" >> "$LOG"
  printf '{"action":"stop"}\n' | nc -U "$SOCK" >> "$LOG" 2>&1 || true
  echo "AUTO_STOP_DONE $(ts)" >> "$LOG"
) &
timer_pid=$!
log "TIMER_PID $timer_pid $(ts)"

log "START $(ts)"
domains_json=$(printf '%s\n' "${TARGET_DOMAINS[@]}" | jq -R . | jq -s .)
printf '{"action":"start","binary_path":"/Users/hanger/.funnel/sing-box","config_path":"%s","log_path":"%s","target_domains":%s}\n' "$CONFIG" "$SINGLOG" "$domains_json" | nc -U "$SOCK" | tee -a "$LOG" || true

sleep 2
log "PROBE_BEGIN $(ts)"

for domain in "${TARGET_DOMAINS[@]}"; do
  safe_name=$(echo "$domain" | tr '.-' '__')
  log "RESOLVER_FILE $domain"
  if [[ -f "/etc/resolver/$domain" ]]; then
    sed "s/^/RESOLVER_FILE_$safe_name /" "/etc/resolver/$domain" | tee -a "$LOG"
  else
    log "RESOLVER_FILE_MISSING $domain"
  fi

  log "DSCACHEUTIL $domain"
  dscacheutil -q host -a name "$domain" 2>&1 | sed "s/^/DSCACHEUTIL_$safe_name /" | tee -a "$LOG" || true

  log "PYTHON_GETADDRINFO $domain"
  python3 -c 'import socket,sys; d=sys.argv[1]; print(socket.getaddrinfo(d, 443, socket.AF_INET, socket.SOCK_STREAM))' "$domain" 2>&1 | sed "s/^/PYTHON_GETADDRINFO_$safe_name /" | tee -a "$LOG" || true
done

log "PYTHON_TLS $TLS_DOMAIN"
python3 -c 'import socket, ssl, sys; d=sys.argv[1]; s=socket.create_connection((d,443),timeout=8); c=ssl.create_default_context().wrap_socket(s,server_hostname=d); print("TLS_DOMAIN", d); print("TLS_VERSION", c.version()); print("PEER", c.getpeercert().get("subject", [])[:1]); c.close()' "$TLS_DOMAIN" 2>&1 | sed "s/^/PYTHON_TLS /" | tee -a "$LOG" || true

log "DIG_DEFAULT_BAIDU"
dig +time=3 +tries=1 +short www.baidu.com A 2>&1 | sed 's/^/DIG_DEFAULT_BAIDU /' | tee -a "$LOG" || true

log "SINGBOX_EVIDENCE"
grep -E '198\.18\.0\.3|github\.com|outbound/socks|outbound/direct|dns: exchanged' "$SINGLOG" 2>&1 | sed 's/^/SINGBOX_EVIDENCE /' | tee -a "$LOG" || true

log "PROBE_DONE $(ts)"
helper '{"action":"stop"}' || true
wait "$timer_pid"
log "STATUS_AFTER $(ts)"
helper '{"action":"status"}' || true
log "SINGLOG_PATH $SINGLOG"
log "SCRIPT_DONE $(ts)"
