#!/bin/zsh
set -u

# Experiment: test helper-managed macOS resolver end to end.
#
# Intent:
# - Use the helper socket protocol with target_domains populated.
# - Start sing-box with local DNS inbound and without system DNS/default gateway
#   capture.
# - Check whether the installed helper writes /etc/resolver/github.com.
# - Check whether default macOS resolution for github.com returns FakeIP.
#
# Safety:
# - Starts from /tmp/funnel-github-with-system-dns.json, whose only target
#   domain is github.com.
# - Must not include chatgpt.com/openai.com/oaistatic/oaiusercontent.
# - Stops Funnel with a 12-second auto-stop guard.
#
# Output:
# - Probe log: /tmp/funnel-helper-managed-resolver-e2e-experiment.log
# - Isolated sing-box log: /tmp/funnel-helper-managed-resolver-e2e-singbox.log
# - Derived config: /tmp/funnel-github-helper-managed-resolver-e2e.json
#
# Experiment record:
# - Ran at 2026-06-03 01:15 +0800.
# - Before running:
#   - Repository helper binary existed at ./helper/funnel-helper.
#   - Installed privileged helper existed at /usr/local/bin/funnel-helper.
#   - Their SHA256 hashes differed:
#     - installed: c342c0b3be98ad2c7f94bcfc8d8ede9fb22f244fafc63442a11bda50792c0e32
#     - repo build: 4a926048fc69d16b69eb79fbae9b635d7b490ba6673a37c69c85ee49ea0e5739
# - Observed phenomenon:
#   - helper start returned {"ok":true,"message":"started"}.
#   - /etc/resolver/github.com was missing.
#   - scutil --dns showed no github.com resolver entry.
#   - default dig github.com A returned real IP 20.205.243.166, not FakeIP.
#   - local DNS inbound still worked: dig @127.0.0.1 -p 53535 github.com A
#     returned 198.18.0.3.
#   - default dig www.baidu.com A resolved normally.
# - Conclusion:
#   - This end-to-end test did not pass.
#   - The local DNS inbound part works, but the installed privileged helper is
#     still the old binary and does not write macOS resolver files.
#   - Next experiment must first install or run the updated helper, then repeat
#     the same resolver and default-dig checks. Do not claim the fix works
#     until default macOS resolution for the target domain returns FakeIP.

SOCK=/var/run/funnel.sock
BASE=/tmp/funnel-github-with-system-dns.json
CONFIG=/tmp/funnel-github-helper-managed-resolver-e2e.json
LOG=/tmp/funnel-helper-managed-resolver-e2e-experiment.log
SINGLOG=/tmp/funnel-helper-managed-resolver-e2e-singbox.log

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
log "HELPER_FILES"
ls -l /usr/local/bin/funnel-helper ./helper/funnel-helper 2>&1 | sed 's/^/HELPER_FILE /' | tee -a "$LOG" || true
shasum -a 256 /usr/local/bin/funnel-helper ./helper/funnel-helper 2>&1 | sed 's/^/HELPER_SHA /' | tee -a "$LOG" || true

helper '{"action":"stop"}' || true

(
  sleep 12
  echo "AUTO_STOP_FIRE $(ts)" >> "$LOG"
  printf '{"action":"stop"}\n' | nc -U "$SOCK" >> "$LOG" 2>&1 || true
  echo "AUTO_STOP_DONE $(ts)" >> "$LOG"
) &
timer_pid=$!
log "TIMER_PID $timer_pid $(ts)"

log "START $(ts)"
printf '{"action":"start","binary_path":"/Users/hanger/.funnel/sing-box","config_path":"%s","log_path":"%s","target_domains":["github.com"]}\n' "$CONFIG" "$SINGLOG" | nc -U "$SOCK" | tee -a "$LOG" || true

sleep 2
log "PROBE_BEGIN $(ts)"

log "RESOLVER_FILE"
if [[ -f /etc/resolver/github.com ]]; then
  sed 's/^/RESOLVER_FILE /' /etc/resolver/github.com | tee -a "$LOG"
else
  log "RESOLVER_FILE missing /etc/resolver/github.com"
fi

log "SCUTIL_DNS_GITHUB"
scutil --dns 2>&1 | grep -A8 -E 'github\.com|127\.0\.0\.1|53535' | sed 's/^/SCUTIL_DNS_GITHUB /' | tee -a "$LOG" || true

log "DIG_DEFAULT_GITHUB"
dig +time=3 +tries=1 +short github.com A 2>&1 | sed 's/^/DIG_DEFAULT_GITHUB /' | tee -a "$LOG" || true

log "DIG_LOCAL_GITHUB"
dig +time=3 +tries=1 +short @127.0.0.1 -p 53535 github.com A 2>&1 | sed 's/^/DIG_LOCAL_GITHUB /' | tee -a "$LOG" || true

log "DIG_DEFAULT_BAIDU"
dig +time=3 +tries=1 +short www.baidu.com A 2>&1 | sed 's/^/DIG_DEFAULT_BAIDU /' | tee -a "$LOG" || true

log "PROBE_DONE $(ts)"
helper '{"action":"stop"}' || true
wait "$timer_pid"
log "STATUS_AFTER $(ts)"
helper '{"action":"status"}' || true
log "SINGLOG_PATH $SINGLOG"
log "SCRIPT_DONE $(ts)"
