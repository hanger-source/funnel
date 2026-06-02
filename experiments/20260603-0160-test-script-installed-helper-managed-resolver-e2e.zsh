#!/bin/zsh
set -u

# Experiment: install the updated helper by script, then test resolver E2E.
#
# Intent:
# - Do not open Funnel.app.
# - Install ./helper/funnel-helper and helper/com.funnel.helper.plist through an
#   explicit admin shell step.
# - Start an isolated github.com-only sing-box config through the helper socket.
# - Verify /etc/resolver/github.com, scutil --dns, default dig github.com, local
#   DNS inbound, and ordinary non-target DNS.
#
# Safety:
# - Starts from /tmp/funnel-github-with-system-dns.json, whose only target
#   domain is github.com.
# - Must not include chatgpt.com/openai.com/oaistatic/oaiusercontent.
# - Does not open Funnel.app.
# - Stops helper-managed sing-box at the end.
#
# Output:
# - Probe log: /tmp/funnel-script-installed-helper-resolver-e2e-experiment.log
# - Isolated sing-box log: /tmp/funnel-script-installed-helper-resolver-e2e-singbox.log
# - Derived config: /tmp/funnel-github-script-installed-helper-resolver-e2e.json
#
# Experiment record:
# - First run at 2026-06-03 01:18 +0800:
#   - Admin install completed.
#   - Installed helper hash changed from the old binary to the repo helper hash:
#     4a926048fc69d16b69eb79fbae9b635d7b490ba6673a37c69c85ee49ea0e5739.
#   - /etc/resolver/github.com was created:
#     nameserver 127.0.0.1, port 53535, domain github.com.
#   - scutil --dns showed a github.com resolver using 127.0.0.1:53535.
#   - dig @127.0.0.1 -p 53535 github.com A returned FakeIP 198.18.0.3.
#   - plain dig github.com A still returned real IP 20.205.243.166.
#   - plain dig www.baidu.com A resolved normally.
# - First-run conclusion:
#   - Helper install and resolver-file creation worked.
#   - Local DNS inbound worked.
#   - plain dig is not enough to validate macOS /etc/resolver behavior because
#     dig may bypass the macOS Super DNS resolver and read /etc/resolv.conf.
#   - Need a second run using dscacheutil or a libc resolver client before
#     judging whether default app resolution returns FakeIP.
# - Second run at 2026-06-03 01:19 +0800:
#   - Installed helper and repo helper hashes matched before and after install.
#   - /etc/resolver/github.com existed with nameserver 127.0.0.1 and port 53535.
#   - scutil --dns showed github.com routed to 127.0.0.1:53535.
#   - plain dig github.com A still returned real IP 20.205.243.166.
#   - dscacheutil -q host -a name github.com returned FakeIP 198.18.0.3.
#   - Python socket.getaddrinfo("github.com", 443, AF_INET, SOCK_STREAM)
#     returned 198.18.0.3.
#   - dig @127.0.0.1 -p 53535 github.com A returned FakeIP 198.18.0.3.
#   - plain dig www.baidu.com A resolved normally.
# - Second-run conclusion:
#   - The script-installed updated helper successfully manages macOS
#     domain-scoped resolver files.
#   - macOS/libc resolver clients resolve target domains to FakeIP without
#     capturing the system DNS/default gateway.
#   - plain dig is not the right validator for /etc/resolver; use dscacheutil,
#     socket.getaddrinfo, or an actual app/network client.
#   - DNS-side fix is validated. The next required experiment is connection
#     layer validation: a libc-resolved connection to github.com should enter
#     the FakeIP TUN path and reach outbound/proxy with the original domain.

SOCK=/var/run/funnel.sock
BASE=/tmp/funnel-github-with-system-dns.json
CONFIG=/tmp/funnel-github-script-installed-helper-resolver-e2e.json
LOG=/tmp/funnel-script-installed-helper-resolver-e2e-experiment.log
SINGLOG=/tmp/funnel-script-installed-helper-resolver-e2e-singbox.log
HELPER_SRC=/Users/hanger/projects/funnel/helper/funnel-helper
PLIST_SRC=/Users/hanger/projects/funnel/helper/com.funnel.helper.plist
HELPER_DST=/usr/local/bin/funnel-helper
PLIST_DST=/Library/LaunchDaemons/com.funnel.helper.plist

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

log "HELPER_BEFORE"
ls -l "$HELPER_DST" "$HELPER_SRC" 2>&1 | sed 's/^/HELPER_BEFORE /' | tee -a "$LOG" || true
shasum -a 256 "$HELPER_DST" "$HELPER_SRC" 2>&1 | sed 's/^/HELPER_SHA_BEFORE /' | tee -a "$LOG" || true

log "ADMIN_INSTALL_BEGIN $(ts)"
ADMIN_SCRIPT="cp '$HELPER_SRC' '$HELPER_DST' && chmod 755 '$HELPER_DST' && chown root:wheel '$HELPER_DST' && cp '$PLIST_SRC' '$PLIST_DST' && chmod 644 '$PLIST_DST' && chown root:wheel '$PLIST_DST' && launchctl bootout system/com.funnel.helper 2>/dev/null; sleep 1; launchctl bootstrap system '$PLIST_DST' 2>/dev/null || launchctl load -w '$PLIST_DST'"
osascript -e "do shell script \"$ADMIN_SCRIPT\" with administrator privileges" 2>&1 | sed 's/^/ADMIN_INSTALL /' | tee -a "$LOG" || true
log "ADMIN_INSTALL_DONE $(ts)"

sleep 2

log "HELPER_AFTER"
ls -l "$HELPER_DST" "$HELPER_SRC" 2>&1 | sed 's/^/HELPER_AFTER /' | tee -a "$LOG" || true
shasum -a 256 "$HELPER_DST" "$HELPER_SRC" 2>&1 | sed 's/^/HELPER_SHA_AFTER /' | tee -a "$LOG" || true

log "HELPER_STOP_BEFORE_START"
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

log "DSCACHEUTIL_GITHUB"
dscacheutil -q host -a name github.com 2>&1 | sed 's/^/DSCACHEUTIL_GITHUB /' | tee -a "$LOG" || true

log "PYTHON_GETADDRINFO_GITHUB"
python3 -c 'import socket; print(socket.getaddrinfo("github.com", 443, socket.AF_INET, socket.SOCK_STREAM))' 2>&1 | sed 's/^/PYTHON_GETADDRINFO_GITHUB /' | tee -a "$LOG" || true

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
