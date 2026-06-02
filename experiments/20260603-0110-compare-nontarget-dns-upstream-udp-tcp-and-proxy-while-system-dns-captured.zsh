#!/bin/zsh
set -u

# Experiment: compare non-target DNS upstream choices while system DNS /32 is
# still captured for target-domain FakeIP.
#
# Intent:
# - Keep the known FakeIP entry point: route_address includes 192.168.31.1/32.
# - Test whether non-target DNS failure is specific to UDP direct DNS.
# - Compare:
#   1. udp_direct_2235: current default dns-direct address 223.5.5.5.
#   2. tcp_direct_2235: direct DNS changed to tcp://223.5.5.5.
#   3. remote_final_proxy: dns.final changed to dns-remote, so non-target DNS
#      also resolves through tcp://1.1.1.1 via the proxy outbound.
#
# Safety:
# - Starts from /tmp/funnel-github-with-system-dns.json, whose only target
#   domain is github.com.
# - Must not include chatgpt.com/openai.com/oaistatic/oaiusercontent.
# - Stops Funnel before and after every case, with a 10-second auto-stop guard.
#
# Output:
# - Probe log: /tmp/funnel-dns-upstream-choice-experiment.log
# - Isolated sing-box log: /tmp/funnel-dns-upstream-choice-singbox.log
# - Derived configs:
#   - /tmp/funnel-github-dns-upstream-udp-direct-2235.json
#   - /tmp/funnel-github-dns-upstream-tcp-direct-2235.json
#   - /tmp/funnel-github-dns-upstream-remote-final-proxy.json
#
# Experiment record:
# - Ran at 2026-06-03 01:04 +0800.
# - Before running:
#   - Base config only targeted github.com.
#   - route_address still contained 198.18.0.0/15 and 192.168.31.1/32.
#   - 192.168.31.1 was later confirmed to be both system DNS and default
#     gateway on this network.
# - Observed phenomenon:
#   - udp_direct_2235:
#     - route -n get 192.168.31.1 selected utun4.
#     - route -n get 223.5.5.5 selected en0, but the gateway was still
#       192.168.31.1.
#     - github.com returned FakeIP 198.18.0.3.
#     - @192.168.31.1, @223.5.5.5, and default DNS queries for baidu all
#       timed out.
#   - tcp_direct_2235:
#     - 223.5.5.5 again selected en0 through gateway 192.168.31.1.
#     - github.com returned FakeIP 198.18.0.3.
#     - direct TCP DNS to 223.5.5.5 still timed out.
#   - remote_final_proxy:
#     - github.com returned FakeIP 198.18.0.3.
#     - non-target DNS still timed out even when dns.final was dns-remote.
#     - sing-box logs showed outbound/socks[proxy] connections to 1.1.1.1:53,
#       but no successful non-target exchange before stop.
# - Conclusions:
#   - The failure is not specific to UDP direct DNS.
#   - Changing non-target DNS to TCP direct or proxy remote does not by itself
#     restore DNS while 192.168.31.1/32 is captured.
#   - The stronger lead is that capturing 192.168.31.1 captures the machine's
#     default gateway, so even traffic whose destination route says en0 can
#     break because its next hop is the captured gateway.

SOCK=/var/run/funnel.sock
BASE=/tmp/funnel-github-with-system-dns.json
CFG_UDP=/tmp/funnel-github-dns-upstream-udp-direct-2235.json
CFG_TCP=/tmp/funnel-github-dns-upstream-tcp-direct-2235.json
CFG_REMOTE=/tmp/funnel-github-dns-upstream-remote-final-proxy.json
LOG=/tmp/funnel-dns-upstream-choice-experiment.log
SINGLOG=/tmp/funnel-dns-upstream-choice-singbox.log

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

make_configs() {
  jq '.inbounds[0].route_exclude_address=["223.5.5.5/32"] | .inbounds[0].strict_route=false | .log.level="info"' "$BASE" > "$CFG_UDP"
  jq '.dns.servers=(.dns.servers | map(if .tag=="dns-direct" then .address="tcp://223.5.5.5" else . end)) | .inbounds[0].route_exclude_address=["223.5.5.5/32"] | .inbounds[0].strict_route=false | .log.level="info"' "$BASE" > "$CFG_TCP"
  jq '.dns.final="dns-remote" | .inbounds[0].route_exclude_address=["223.5.5.5/32"] | .inbounds[0].strict_route=false | .log.level="info"' "$BASE" > "$CFG_REMOTE"
}

probe_case() {
  local name="$1"
  local config="$2"

  log "CASE_BEGIN $name $(ts)"
  helper '{"action":"stop"}' || true

  (
    sleep 10
    echo "AUTO_STOP_FIRE $name $(ts)" >> "$LOG"
    printf '{"action":"stop"}\n' | nc -U "$SOCK" >> "$LOG" 2>&1 || true
    echo "AUTO_STOP_DONE $name $(ts)" >> "$LOG"
  ) &
  local timer_pid=$!
  log "TIMER_PID $name $timer_pid $(ts)"

  log "CONFIG_SUMMARY $name"
  jq '.dns.servers,.dns.final,.inbounds[0].strict_route,.inbounds[0].route_address,.inbounds[0].route_exclude_address' "$config" | sed "s/^/CONFIG_$name /" | tee -a "$LOG"

  log "START $name $(ts)"
  printf '{"action":"start","binary_path":"/Users/hanger/.funnel/sing-box","config_path":"%s","log_path":"%s"}\n' "$config" "$SINGLOG" | nc -U "$SOCK" | tee -a "$LOG" || true

  sleep 1
  log "PROBE_BEGIN $name $(ts)"

  log "ROUTE_SYSTEM_DNS $name"
  route -n get 192.168.31.1 2>&1 | sed "s/^/ROUTE_SYSTEM_DNS_$name /" | tee -a "$LOG" || true

  log "ROUTE_DIRECT_DNS $name"
  route -n get 223.5.5.5 2>&1 | sed "s/^/ROUTE_DIRECT_DNS_$name /" | tee -a "$LOG" || true

  log "DIG_DEFAULT_GITHUB $name"
  dig +time=3 +tries=1 +short github.com A 2>&1 | sed "s/^/DIG_DEFAULT_GITHUB_$name /" | tee -a "$LOG" || true

  log "DIG_AT_SYSTEM_DNS_BAIDU $name"
  dig +time=3 +tries=1 +short @192.168.31.1 www.baidu.com A 2>&1 | sed "s/^/DIG_AT_SYSTEM_DNS_BAIDU_$name /" | tee -a "$LOG" || true

  log "DIG_AT_DIRECT_DNS_BAIDU $name"
  dig +time=3 +tries=1 +short @223.5.5.5 www.baidu.com A 2>&1 | sed "s/^/DIG_AT_DIRECT_DNS_BAIDU_$name /" | tee -a "$LOG" || true

  log "DIG_DEFAULT_BAIDU $name"
  dig +time=3 +tries=1 +short www.baidu.com A 2>&1 | sed "s/^/DIG_DEFAULT_BAIDU_$name /" | tee -a "$LOG" || true

  log "PROBE_DONE $name $(ts)"
  helper '{"action":"stop"}' || true
  wait "$timer_pid"
  log "CASE_DONE $name $(ts)"
}

log "SCRIPT_BEGIN $(ts)"
make_configs
probe_case "udp_direct_2235" "$CFG_UDP"
probe_case "tcp_direct_2235" "$CFG_TCP"
probe_case "remote_final_proxy" "$CFG_REMOTE"
log "STATUS_AFTER $(ts)"
helper '{"action":"status"}' || true
log "SINGLOG_PATH $SINGLOG"
log "SCRIPT_DONE $(ts)"
