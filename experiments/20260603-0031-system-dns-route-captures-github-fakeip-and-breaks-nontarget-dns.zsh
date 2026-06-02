#!/bin/zsh
set -u

# Experiment: verify what happens when Funnel routes the system DNS server
# (192.168.31.1/32) into the TUN.
#
# Intent:
# - Confirm target-domain DNS can be hijacked into FakeIP.
# - Confirm non-target DNS behavior when the whole system DNS server is captured.
#
# Safety:
# - Uses /tmp/funnel-github-with-system-dns.json, whose only target domain is
#   github.com.
# - Must not include chatgpt.com/openai.com/oaistatic/oaiusercontent.
# - Auto-stops helper after 12 seconds.
#
# Output:
# - Probe log: /tmp/funnel-dns-route-experiment.log
# - sing-box log path is intentionally the app log in this older experiment;
#   later experiments write to isolated /tmp logs.
#
# Experiment record:
# - Config checked before running:
#   - /tmp/funnel-github-with-system-dns.json only targets github.com.
#   - route_address contains 198.18.0.0/15 and 192.168.31.1/32.
# - Key result after running:
#   - route -n get 192.168.31.1 selected the TUN gateway 172.19.0.1.
#   - netstat showed 192.168.31.1/32 routed through utun.
#   - dig github.com A returned FakeIP 198.18.0.3.
#   - dig @192.168.31.1 github.com A also returned FakeIP 198.18.0.3.
#   - dig @192.168.31.1 www.baidu.com A timed out.
# - Correlated sing-box evidence:
#   - inbound/tun saw packet connection to 192.168.31.1:53.
#   - DNS exchanged github.com A to 198.18.0.3.
#   - direct outbound attempted 223.5.5.5:53 for non-target DNS.
#   - www.baidu.com DNS exchange failed with deadline exceeded.
# - Conclusion at this point:
#   - Adding system DNS /32 makes target-domain FakeIP possible because system
#     DNS queries enter sing-box hijack-dns.
#   - Capturing the whole system DNS server also pulls non-target DNS into this
#     path, and non-target DNS timed out in this live run.
#   - The later 20260603-0050 experiment disproved the narrower hypothesis that
#     adding only 223.5.5.5/32 to route_exclude_address fully fixes this.

SOCK=/var/run/funnel.sock
CONFIG=/tmp/funnel-github-with-system-dns.json
LOG=/tmp/funnel-dns-route-experiment.log

: > "$LOG"

ts() {
  date "+%Y-%m-%d %H:%M:%S %z"
}

log() {
  echo "$@" | tee -a "$LOG"
}

log "SCRIPT_BEGIN $(ts)"
printf '{"action":"stop"}\n' | nc -U "$SOCK" >> "$LOG" 2>&1 || true

(
  sleep 12
  echo "AUTO_STOP_FIRE $(ts)" >> "$LOG"
  printf '{"action":"stop"}\n' | nc -U "$SOCK" >> "$LOG" 2>&1 || true
  echo "AUTO_STOP_DONE $(ts)" >> "$LOG"
) &
timer_pid=$!
log "TIMER_PID $timer_pid $(ts)"

log "START $(ts)"
printf '{"action":"start","binary_path":"/Users/hanger/.funnel/sing-box","config_path":"%s","log_path":"/Users/hanger/.funnel/singbox.log"}\n' "$CONFIG" | nc -U "$SOCK" | tee -a "$LOG" || true

sleep 1
log "PROBE_BEGIN $(ts)"

log "ROUTE_GET_SYSTEM_DNS"
route -n get 192.168.31.1 2>&1 | sed 's/^/ROUTE_SYSTEM_DNS /' | tee -a "$LOG" || true

log "ROUTE_GET_FAKEIP"
route -n get 198.18.0.3 2>&1 | sed 's/^/ROUTE_FAKEIP /' | tee -a "$LOG" || true

log "NETSTAT_SELECTED"
netstat -rn -f inet | grep -E '198\.18|172\.19|utun|192\.168\.31\.1' | sed 's/^/NETSTAT /' | tee -a "$LOG" || true

log "DIG_DEFAULT_GITHUB"
dig +time=3 +tries=1 +short github.com A 2>&1 | sed 's/^/DIG_DEFAULT_GITHUB /' | tee -a "$LOG" || true

log "DIG_AT_SYSTEM_DNS_GITHUB"
dig +time=3 +tries=1 +short @192.168.31.1 github.com A 2>&1 | sed 's/^/DIG_AT_SYSTEM_DNS_GITHUB /' | tee -a "$LOG" || true

log "DIG_AT_SYSTEM_DNS_BAIDU"
dig +time=3 +tries=1 +short @192.168.31.1 www.baidu.com A 2>&1 | sed 's/^/DIG_AT_SYSTEM_DNS_BAIDU /' | tee -a "$LOG" || true

log "PROBE_DONE $(ts)"
wait "$timer_pid"

log "STATUS_AFTER_AUTO_STOP $(ts)"
printf '{"action":"status"}\n' | nc -U "$SOCK" | tee -a "$LOG" || true
log "SCRIPT_DONE $(ts)"
