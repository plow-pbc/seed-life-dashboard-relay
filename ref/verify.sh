#!/usr/bin/env bash
# Deterministic implementation of SEED.md ## Verify.

set -euo pipefail

STATE="$HOME/Library/Application Support/seed-life-dashboard-relay/state.json"

# v1: state file present, mode 600, well-formed.
[ -f "$STATE" ] || { echo "FAIL ^v-state: $STATE missing" >&2; exit 1; }
[ "$(stat -f '%Lp' "$STATE")" = "600" ] \
  || { echo "FAIL ^v-state: $STATE not mode 600" >&2; exit 1; }
URL=$(jq -re .endpoint_url "$STATE") \
  || { echo "FAIL ^v-state: .endpoint_url missing/empty" >&2; exit 1; }
TOK=$(jq -re .dashboard_token "$STATE") \
  || { echo "FAIL ^v-state: .dashboard_token missing/empty" >&2; exit 1; }
case "$URL" in
  https://*) ;;
  *) echo "FAIL ^v-state: endpoint_url is not HTTPS" >&2; exit 1 ;;
esac
echo "OK   ^v-state"

# v2: endpoint reachable with bearer.
HTTP=$(curl -fsS -H "Authorization: Bearer $TOK" \
            -o /dev/null -w '%{http_code}' \
            "$URL/api/message")
[ "$HTTP" = "200" ] || { echo "FAIL ^v-reachable: $URL/api/message → $HTTP" >&2; exit 1; }
echo "OK   ^v-reachable"

# v3: auth enforced (no header → 401).
HTTP_NOAUTH=$(curl -s -o /dev/null -w '%{http_code}' "$URL/api/message")
[ "$HTTP_NOAUTH" = "401" ] || {
  echo "FAIL ^v-auth: expected 401 without bearer, got $HTTP_NOAUTH" >&2
  exit 1
}
echo "OK   ^v-auth"

echo "tree conforms"
