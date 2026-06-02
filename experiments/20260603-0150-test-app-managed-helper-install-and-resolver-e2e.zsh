#!/bin/zsh
set -u

# Experiment: test the real App-managed helper install/start path.
#
# Intent:
# - Open build/Funnel.app so the app's normal installHelperIfNeeded flow can
#   update /usr/local/bin/funnel-helper if needed.
# - Then verify the actual installed helper, resolver files, default DNS, and
#   local DNS inbound.
#
# Safety:
# - This uses the real app flow and may trigger a macOS authorization prompt.
# - The app's real config may contain OpenAI/ChatGPT target domains. This test
#   does not manually start extra isolated sing-box configs.
# - Stops Funnel helper at the end and asks the app to quit.
#
# Output:
# - Probe log: /tmp/funnel-app-managed-helper-resolver-e2e-experiment.log
#
# Experiment record:
# - Ran at 2026-06-03 01:16 +0800.
# - This experiment is invalid and must not be used as evidence because it
#   opened build/Funnel.app. The user explicitly rejected using Funnel.app as
#   the test driver.
# - Partial observed phenomenon before the run was interrupted:
#   - Installed helper and repo helper hashes still differed.
#   - /etc/resolver target files were missing.
#   - default openai.com and chatgpt.com did not return FakeIP.
#   - local DNS inbound for openai.com timed out because the app/helper path did
#     not actually start the new isolated local-DNS configuration.
# - Conclusion:
#   - Discard this experiment for root-cause validation.
#   - Future tests must use direct experiment scripts and helper socket/admin
#     install steps, not opening Funnel.app.

SOCK=/var/run/funnel.sock
LOG=/tmp/funnel-app-managed-helper-resolver-e2e-experiment.log

: > "$LOG"

ts() {
  date "+%Y-%m-%d %H:%M:%S %z"
}

log() {
  echo "$@" | tee -a "$LOG"
}

helper() {
  printf '%s\n' "$1" | nc -U "$SOCK" 2>&1 | tee -a "$LOG"
}

log "SCRIPT_BEGIN $(ts)"

log "HELPER_BEFORE"
ls -l /usr/local/bin/funnel-helper ./helper/funnel-helper 2>&1 | sed 's/^/HELPER_BEFORE /' | tee -a "$LOG" || true
shasum -a 256 /usr/local/bin/funnel-helper ./helper/funnel-helper 2>&1 | sed 's/^/HELPER_SHA_BEFORE /' | tee -a "$LOG" || true

log "OPEN_APP $(ts)"
open -n ./build/Funnel.app 2>&1 | sed 's/^/OPEN_APP /' | tee -a "$LOG" || true

log "WAIT_FOR_APP_FLOW $(ts)"
sleep 15

log "HELPER_AFTER"
ls -l /usr/local/bin/funnel-helper ./helper/funnel-helper 2>&1 | sed 's/^/HELPER_AFTER /' | tee -a "$LOG" || true
shasum -a 256 /usr/local/bin/funnel-helper ./helper/funnel-helper 2>&1 | sed 's/^/HELPER_SHA_AFTER /' | tee -a "$LOG" || true

log "HELPER_STATUS"
helper '{"action":"status"}' || true

log "RESOLVER_FILES"
for domain in github.com openai.com chatgpt.com oaistatic.com oaiusercontent.com; do
  if [[ -f "/etc/resolver/$domain" ]]; then
    echo "RESOLVER_FILE_BEGIN $domain" | tee -a "$LOG"
    sed "s/^/RESOLVER_FILE_$domain /" "/etc/resolver/$domain" | tee -a "$LOG"
    echo "RESOLVER_FILE_END $domain" | tee -a "$LOG"
  else
    echo "RESOLVER_FILE_MISSING $domain" | tee -a "$LOG"
  fi
done

log "SCUTIL_DNS_TARGETS"
scutil --dns 2>&1 | grep -A8 -E 'github\.com|openai\.com|chatgpt\.com|oaistatic\.com|oaiusercontent\.com|127\.0\.0\.1|53535' | sed 's/^/SCUTIL_DNS_TARGETS /' | tee -a "$LOG" || true

log "DIG_DEFAULT_OPENAI"
dig +time=3 +tries=1 +short openai.com A 2>&1 | sed 's/^/DIG_DEFAULT_OPENAI /' | tee -a "$LOG" || true

log "DIG_DEFAULT_CHATGPT"
dig +time=3 +tries=1 +short chatgpt.com A 2>&1 | sed 's/^/DIG_DEFAULT_CHATGPT /' | tee -a "$LOG" || true

log "DIG_LOCAL_OPENAI"
dig +time=3 +tries=1 +short @127.0.0.1 -p 53535 openai.com A 2>&1 | sed 's/^/DIG_LOCAL_OPENAI /' | tee -a "$LOG" || true

log "DIG_DEFAULT_BAIDU"
dig +time=3 +tries=1 +short www.baidu.com A 2>&1 | sed 's/^/DIG_DEFAULT_BAIDU /' | tee -a "$LOG" || true

log "STOP_HELPER"
helper '{"action":"stop"}' || true

log "QUIT_APP"
osascript -e 'tell application "Funnel" to quit' 2>&1 | sed 's/^/QUIT_APP /' | tee -a "$LOG" || true

log "SCRIPT_DONE $(ts)"
