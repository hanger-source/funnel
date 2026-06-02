#!/bin/zsh
set -u

# Experiment: test whether Funnel can use a dedicated TUN DNS entry instead of
# capturing the system DNS/default gateway address.
#
# Intent:
# - Do not route 192.168.31.1/32 into the TUN because it is also the default
#   gateway on this network.
# - Keep route_address limited to 198.18.0.0/15.
# - Probe whether direct DNS queries to the TUN address (172.19.0.1) reach
#   sing-box hijack-dns and return FakeIP for github.com.
# - If this works, the fix direction is domain-scoped macOS resolver entries
#   for target domains, pointing at the TUN DNS entry, instead of global system
#   DNS capture.
#
# Safety:
# - Starts from /tmp/funnel-github-with-system-dns.json, whose only target
#   domain is github.com.
# - Must not include chatgpt.com/openai.com/oaistatic/oaiusercontent.
# - Stops Funnel with a 12-second auto-stop guard.
#
# Output:
# - Probe log: /tmp/funnel-dedicated-tun-dns-entry-experiment.log
# - Isolated sing-box log: /tmp/funnel-dedicated-tun-dns-entry-singbox.log
# - Derived config: /tmp/funnel-github-dedicated-tun-dns-entry-no-gateway-capture.json
#
# Experiment record:
# - Ran at 2026-06-03 01:06 +0800.
# - Before running:
#   - Removed 192.168.31.1/32 from route_address.
#   - Kept only 198.18.0.0/15 in route_address.
#   - Hypothesis: maybe the TUN local address 172.19.0.1 can act as a
#     dedicated DNS entry without capturing the default gateway.
# - Observed phenomenon:
#   - route_address: ["198.18.0.0/15"].
#   - route -n get 192.168.31.1 stayed on en0 and had ROUTER flag.
#   - route -n get 172.19.0.1 selected local utun4.
#   - dig @172.19.0.1 github.com A timed out.
#   - dig @172.19.0.1 www.baidu.com A timed out.
#   - default github.com A returned real IP 20.205.243.166, not FakeIP.
#   - default www.baidu.com A resolved normally.
# - Conclusions:
#   - Removing default gateway capture restores ordinary DNS and routing.
#   - The TUN interface address is not automatically a DNS listener; packets
#     sent directly to 172.19.0.1:53 do not reach sing-box DNS.
#   - A dedicated DNS entry needs an explicit sing-box inbound, not just the
#     TUN address.

SOCK=/var/run/funnel.sock
BASE=/tmp/funnel-github-with-system-dns.json
CONFIG=/tmp/funnel-github-dedicated-tun-dns-entry-no-gateway-capture.json
LOG=/tmp/funnel-dedicated-tun-dns-entry-experiment.log
SINGLOG=/tmp/funnel-dedicated-tun-dns-entry-singbox.log

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
  jq '.inbounds[0].route_address=["198.18.0.0/15"] | .inbounds[0].route_exclude_address=["223.5.5.5/32"] | .inbounds[0].strict_route=false | .log.level="info"' "$BASE" > "$CONFIG"
}

log "SCRIPT_BEGIN $(ts)"
make_config
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
jq '.dns.servers,.dns.final,.inbounds[0].route_address,.inbounds[0].route_exclude_address' "$CONFIG" | sed "s/^/CONFIG /" | tee -a "$LOG"

log "START $(ts)"
printf '{"action":"start","binary_path":"/Users/hanger/.funnel/sing-box","config_path":"%s","log_path":"%s"}\n' "$CONFIG" "$SINGLOG" | nc -U "$SOCK" | tee -a "$LOG" || true

sleep 1
log "PROBE_BEGIN $(ts)"

log "ROUTE_DEFAULT"
route -n get default 2>&1 | sed 's/^/ROUTE_DEFAULT /' | tee -a "$LOG" || true

log "ROUTE_SYSTEM_DNS"
route -n get 192.168.31.1 2>&1 | sed 's/^/ROUTE_SYSTEM_DNS /' | tee -a "$LOG" || true

log "ROUTE_TUN_DNS"
route -n get 172.19.0.1 2>&1 | sed 's/^/ROUTE_TUN_DNS /' | tee -a "$LOG" || true

log "DIG_AT_TUN_GITHUB"
dig +time=3 +tries=1 +short @172.19.0.1 github.com A 2>&1 | sed 's/^/DIG_AT_TUN_GITHUB /' | tee -a "$LOG" || true

log "DIG_AT_TUN_BAIDU"
dig +time=3 +tries=1 +short @172.19.0.1 www.baidu.com A 2>&1 | sed 's/^/DIG_AT_TUN_BAIDU /' | tee -a "$LOG" || true

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
