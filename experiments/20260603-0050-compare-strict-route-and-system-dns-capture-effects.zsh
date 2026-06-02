#!/bin/zsh
set -u

# Experiment: compare strict_route and system DNS /32 capture effects under an
# isolated GitHub-only sing-box config.
#
# Intent:
# - Verify whether strict_route=true is the cause of "network is unreachable".
# - Verify whether excluding direct DNS (223.5.5.5/32) is enough to recover
#   non-target DNS when system DNS (192.168.31.1/32) is captured.
# - Compare the same strict_route variants after removing system DNS capture.
#
# Safety:
# - Starts from /tmp/funnel-github-with-system-dns.json, whose only target
#   domain is github.com.
# - Must not include chatgpt.com/openai.com/oaistatic/oaiusercontent.
# - Stops Funnel before and after every case, with a 10-second auto-stop guard.
#
# Output:
# - Probe log: /tmp/funnel-strict-route-experiment.log
# - Isolated sing-box log: /tmp/funnel-strict-route-singbox.log
# - Derived configs:
#   - /tmp/funnel-github-strict-true-exclude-direct.json
#   - /tmp/funnel-github-strict-false-exclude-direct.json
#   - /tmp/funnel-github-no-system-dns-strict-true.json
#   - /tmp/funnel-github-no-system-dns-strict-false.json
#
# Experiment record:
# - Cases:
#   - strict_true:
#     route_address = ["198.18.0.0/15", "192.168.31.1/32"],
#     route_exclude_address = ["223.5.5.5/32"], strict_route = true.
#   - strict_false:
#     same route_address and route_exclude_address, strict_route = false.
#   - no_system_dns_strict_true:
#     route_address = ["198.18.0.0/15"],
#     route_exclude_address = ["223.5.5.5/32"], strict_route = true.
#   - no_system_dns_strict_false:
#     same no-system-DNS route_address, strict_route = false.
# - Key result when system DNS /32 was captured:
#   - GitHub DNS returned FakeIP 198.18.0.3.
#   - dig @192.168.31.1 www.baidu.com A timed out.
#   - dig @223.5.5.5 www.baidu.com A timed out.
#   - nc 1.1.1.1:443 failed with Network is unreachable.
#   - strict_route=false did not materially change this behavior.
# - Key result when system DNS /32 was not captured:
#   - GitHub DNS returned a real GitHub IP, not FakeIP.
#   - system DNS and direct DNS both resolved www.baidu.com normally.
#   - nc 1.1.1.1:443 timed out rather than reporting Network is unreachable.
# - Conclusions:
#   - strict_route=true was not the root cause of this failure.
#   - Excluding 223.5.5.5/32 was not a complete fix.
#   - 192.168.31.1/32 is both the FakeIP DNS entry point and the switch that
#     drags whole-machine DNS into the TUN path.
#   - The next fix direction should be a narrower DNS capture path, not more
#     tuning around strict_route or direct DNS exclude alone.

SOCK=/var/run/funnel.sock
BASE=/tmp/funnel-github-with-system-dns.json
CFG_TRUE=/tmp/funnel-github-strict-true-exclude-direct.json
CFG_FALSE=/tmp/funnel-github-strict-false-exclude-direct.json
CFG_NO_SYSTEM_TRUE=/tmp/funnel-github-no-system-dns-strict-true.json
CFG_NO_SYSTEM_FALSE=/tmp/funnel-github-no-system-dns-strict-false.json
LOG=/tmp/funnel-strict-route-experiment.log
SINGLOG=/tmp/funnel-strict-route-singbox.log

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
  jq '.inbounds[0].route_exclude_address=["223.5.5.5/32"] | .inbounds[0].strict_route=true | .log.level="info"' "$BASE" > "$CFG_TRUE"
  jq '.inbounds[0].route_exclude_address=["223.5.5.5/32"] | .inbounds[0].strict_route=false | .log.level="info"' "$BASE" > "$CFG_FALSE"
  jq '.inbounds[0].route_address=["198.18.0.0/15"] | .inbounds[0].route_exclude_address=["223.5.5.5/32"] | .inbounds[0].strict_route=true | .log.level="info"' "$BASE" > "$CFG_NO_SYSTEM_TRUE"
  jq '.inbounds[0].route_address=["198.18.0.0/15"] | .inbounds[0].route_exclude_address=["223.5.5.5/32"] | .inbounds[0].strict_route=false | .log.level="info"' "$BASE" > "$CFG_NO_SYSTEM_FALSE"
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
  jq '.inbounds[0].strict_route,.inbounds[0].route_address,.inbounds[0].route_exclude_address,.dns.rules' "$config" | sed "s/^/CONFIG_$name /" | tee -a "$LOG"

  log "START $name $(ts)"
  printf '{"action":"start","binary_path":"/Users/hanger/.funnel/sing-box","config_path":"%s","log_path":"%s"}\n' "$config" "$SINGLOG" | nc -U "$SOCK" | tee -a "$LOG" || true

  sleep 1
  log "PROBE_BEGIN $name $(ts)"

  log "ROUTE_SYSTEM_DNS $name"
  route -n get 192.168.31.1 2>&1 | sed "s/^/ROUTE_SYSTEM_DNS_$name /" | tee -a "$LOG" || true

  log "ROUTE_DIRECT_DNS $name"
  route -n get 223.5.5.5 2>&1 | sed "s/^/ROUTE_DIRECT_DNS_$name /" | tee -a "$LOG" || true

  log "ROUTE_CLOUDFLARE $name"
  route -n get 1.1.1.1 2>&1 | sed "s/^/ROUTE_CLOUDFLARE_$name /" | tee -a "$LOG" || true

  log "NETSTAT_SELECTED $name"
  netstat -rn -f inet | grep -E '198\.18|172\.19|utun|192\.168\.31\.1|223\.5\.5\.5|1\.1\.1\.1' | sed "s/^/NETSTAT_$name /" | tee -a "$LOG" || true

  log "DIG_DEFAULT_GITHUB $name"
  dig +time=3 +tries=1 +short github.com A 2>&1 | sed "s/^/DIG_DEFAULT_GITHUB_$name /" | tee -a "$LOG" || true

  log "DIG_AT_SYSTEM_DNS_BAIDU $name"
  dig +time=3 +tries=1 +short @192.168.31.1 www.baidu.com A 2>&1 | sed "s/^/DIG_AT_SYSTEM_DNS_BAIDU_$name /" | tee -a "$LOG" || true

  log "DIG_AT_DIRECT_DNS_BAIDU $name"
  dig +time=3 +tries=1 +short @223.5.5.5 www.baidu.com A 2>&1 | sed "s/^/DIG_AT_DIRECT_DNS_BAIDU_$name /" | tee -a "$LOG" || true

  log "NC_CLOUDFLARE_443 $name"
  nc -vz -G 2 1.1.1.1 443 2>&1 | sed "s/^/NC_CLOUDFLARE_443_$name /" | tee -a "$LOG" || true

  log "PROBE_DONE $name $(ts)"
  helper '{"action":"stop"}' || true
  wait "$timer_pid"
  log "CASE_DONE $name $(ts)"
}

log "SCRIPT_BEGIN $(ts)"
make_configs
probe_case "strict_true" "$CFG_TRUE"
probe_case "strict_false" "$CFG_FALSE"
probe_case "no_system_dns_strict_true" "$CFG_NO_SYSTEM_TRUE"
probe_case "no_system_dns_strict_false" "$CFG_NO_SYSTEM_FALSE"
log "STATUS_AFTER $(ts)"
helper '{"action":"status"}' || true
log "SINGLOG_PATH $SINGLOG"
log "SCRIPT_DONE $(ts)"
