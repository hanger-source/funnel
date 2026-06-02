#!/bin/zsh
set -u

# Experiment: test a local DNS inbound as a dedicated target-domain resolver.
#
# Intent:
# - Avoid routing the default gateway/system DNS (192.168.31.1/32) into TUN.
# - Add a local UDP direct inbound at 127.0.0.1:53535.
# - Route that inbound to sing-box internal DNS with hijack-dns.
# - If dig @127.0.0.1 -p 53535 github.com returns FakeIP while ordinary DNS
#   remains healthy, Funnel can use domain-scoped macOS resolver files instead
#   of gateway capture.
#
# Safety:
# - Starts from /tmp/funnel-github-with-system-dns.json, whose only target
#   domain is github.com.
# - Must not include chatgpt.com/openai.com/oaistatic/oaiusercontent.
# - Stops Funnel with a 12-second auto-stop guard.
#
# Output:
# - Probe log: /tmp/funnel-local-dns-inbound-experiment.log
# - Isolated sing-box log: /tmp/funnel-local-dns-inbound-singbox.log
# - Derived config: /tmp/funnel-github-local-dns-inbound-no-gateway-capture.json
#
# Experiment record:
# - First run at 2026-06-03 01:07 +0800:
#   - Used 127.0.0.1:5353.
#   - sing-box failed to start dns-in because UDP 127.0.0.1:5353 was already
#     in use.
# - Second run at 2026-06-03 01:08 +0800:
#   - Changed local DNS inbound to UDP 127.0.0.1:53535.
#   - sing-box started successfully.
# - Observed phenomenon:
#   - route_address only contained 198.18.0.0/15.
#   - No 192.168.31.1/32 default gateway capture was used.
#   - dig @127.0.0.1 -p 53535 github.com A returned FakeIP 198.18.0.3.
#   - dig @127.0.0.1 -p 53535 www.baidu.com A resolved normally via dns-direct.
#   - default github.com A returned real IP 20.205.243.166 because macOS had
#     not yet been configured to use the local DNS inbound for github.com.
#   - default www.baidu.com A resolved normally.
# - Conclusions:
#   - A local direct inbound plus hijack-dns can be the dedicated target-domain
#     DNS entry.
#   - The fix direction is to keep system DNS/default gateway out of TUN and
#     install macOS domain-scoped resolver files for target domains pointing to
#     127.0.0.1 port 53535.
#   - This preserves ordinary DNS while still giving target domains a FakeIP
#     path once macOS resolver routing is added.

SOCK=/var/run/funnel.sock
BASE=/tmp/funnel-github-with-system-dns.json
CONFIG=/tmp/funnel-github-local-dns-inbound-no-gateway-capture.json
LOG=/tmp/funnel-local-dns-inbound-experiment.log
SINGLOG=/tmp/funnel-local-dns-inbound-singbox.log

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
}

log "SCRIPT_BEGIN $(ts)"
make_config
log "CHECK_CONFIG"
/Users/hanger/.funnel/sing-box check -c "$CONFIG" 2>&1 | sed 's/^/CHECK /' | tee -a "$LOG" || true
helper '{"action":"stop"}' || true

(
  sleep 12
  echo "AUTO_STOP_FIRE $(ts)" >> "$LOG"
  printf '{"action":"stop"}\n' | nc -U "$SOCK" >> "$LOG" 2>&1 || true
  echo "AUTO_STOP_DONE $(ts)" >> "$LOG"
) &
timer_pid=$!
log "TIMER_PID $timer_pid $(ts)"

log "CONFIG_SUMMARY"
jq '.inbounds,.route.rules,.dns.rules,.dns.final' "$CONFIG" | sed "s/^/CONFIG /" | tee -a "$LOG"

log "START $(ts)"
printf '{"action":"start","binary_path":"/Users/hanger/.funnel/sing-box","config_path":"%s","log_path":"%s"}\n' "$CONFIG" "$SINGLOG" | nc -U "$SOCK" | tee -a "$LOG" || true

sleep 1
log "PROBE_BEGIN $(ts)"

log "DIG_LOCAL_DNS_GITHUB"
dig +time=3 +tries=1 +short @127.0.0.1 -p 53535 github.com A 2>&1 | sed 's/^/DIG_LOCAL_DNS_GITHUB /' | tee -a "$LOG" || true

log "DIG_LOCAL_DNS_BAIDU"
dig +time=3 +tries=1 +short @127.0.0.1 -p 53535 www.baidu.com A 2>&1 | sed 's/^/DIG_LOCAL_DNS_BAIDU /' | tee -a "$LOG" || true

log "DIG_DEFAULT_GITHUB"
dig +time=3 +tries=1 +short github.com A 2>&1 | sed 's/^/DIG_DEFAULT_GITHUB /' | tee -a "$LOG" || true

log "DIG_DEFAULT_BAIDU"
dig +time=3 +tries=1 +short www.baidu.com A 2>&1 | sed 's/^/DIG_DEFAULT_BAIDU /' | tee -a "$LOG" || true

log "PROBE_DONE $(ts)"
helper '{"action":"stop"}' || true
wait "$timer_pid"
log "STATUS_AFTER $(ts)"
helper '{"action":"status"}' || true
log "SINGLOG_PATH $SINGLOG"
log "SCRIPT_DONE $(ts)"
