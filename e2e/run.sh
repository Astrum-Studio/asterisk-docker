#!/usr/bin/env bash
# Smoke-test customer-side FreePBX (+ optional remote Connector / Market App).
# Live call scenarios are opt-in because they create real Bitrix24 activities.
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMPOSE=(docker compose --project-directory "$ROOT" -f "$ROOT/docker-compose.yml")
# Market App runs on the vendor host; Connector on the customer host.
APP_URL="${E2E_APP_URL:-https://app-11.astrum.agency}"
CONNECTOR_URL="${E2E_CONNECTOR_URL:-http://127.0.0.1:8079}"
LIVE_BITRIX="${E2E_LIVE_BITRIX:-0}"
LIVE_AMI="${E2E_LIVE_AMI:-0}"
RUN_LIVE="${E2E_RUN_LIVE:-0}"

passed=0
skipped=0
failed=0

result() {
  local state="$1" scenario="$2" detail="${3:-}"
  printf '%-5s %s %s\n' "$state" "$scenario" "$detail"
  case "$state" in
    PASS) ((passed+=1)) ;;
    SKIP) ((skipped+=1)) ;;
    FAIL) ((failed+=1)) ;;
  esac
}

http_ok() {
  curl --fail --silent --show-error --max-time 15 "$1" >/dev/null
}

require_live() {
  local scenario="$1"
  if [[ "$RUN_LIVE" != 1 ]]; then
    result SKIP "$scenario" "set E2E_RUN_LIVE=1"
    return 1
  fi
  if [[ "$LIVE_BITRIX" != 1 || "$LIVE_AMI" != 1 ]]; then
    result SKIP "$scenario" "requires E2E_LIVE_BITRIX=1 and E2E_LIVE_AMI=1"
    return 1
  fi
  return 0
}

main() {
  "${COMPOSE[@]}" config --quiet

  if "${COMPOSE[@]}" ps --status running --services 2>/dev/null | grep -qx freepbx; then
    result PASS "stack.freepbx-running"
  else
    result FAIL "stack.freepbx-running" "start with: docker compose up -d"
  fi

  if [[ -n "$CONNECTOR_URL" ]]; then
    if http_ok "${CONNECTOR_URL%/}/status"; then
      result PASS "stack.connector-status"
    else
      result FAIL "stack.connector-status" "$CONNECTOR_URL/status"
    fi
  else
    result SKIP "stack.connector-status" "set E2E_CONNECTOR_URL"
  fi

  if [[ -n "$APP_URL" ]]; then
    if http_ok "${APP_URL%/}/status"; then
      result PASS "stack.market-status"
    else
      result FAIL "stack.market-status" "$APP_URL/status"
    fi
  else
    result SKIP "stack.market-status" "set E2E_APP_URL to vendor Market App"
  fi

  for scenario in \
    inbound-known inbound-unknown inbound-missed inbound-busy inbound-unavailable \
    outbound-known outbound-unknown transfer queue call-card-deal recording-link-file \
    timeman restart-replay multi-asterisk; do
    require_live "$scenario" || continue
    result SKIP "$scenario" "manual/live fixture assertion required; see e2e/MATRIX.md"
  done

  printf '\nSummary: %d passed, %d skipped, %d failed\n' "$passed" "$skipped" "$failed"
  (( failed == 0 ))
}

main "$@"
