#!/usr/bin/env bash
# Deterministic implementation of SEED.md ## Verify.

set -euo pipefail

STATE="$HOME/Library/Application Support/seed-life-dashboard-relay/state.json"

# v1: state file present, mode 600, well-formed.
[ -f "$STATE" ] || { echo "FAIL v-state: $STATE missing" >&2; exit 1; }
[ "$(stat -f '%Lp' "$STATE")" = "600" ] \
  || { echo "FAIL v-state: $STATE not mode 600" >&2; exit 1; }
URL=$(jq -re .endpoint_url "$STATE") \
  || { echo "FAIL v-state: .endpoint_url missing/empty" >&2; exit 1; }
TOK=$(jq -re .dashboard_token "$STATE") \
  || { echo "FAIL v-state: .dashboard_token missing/empty" >&2; exit 1; }
case "$URL" in
  https://*) ;;
  *) echo "FAIL v-state: endpoint_url is not HTTPS" >&2; exit 1 ;;
esac
echo "OK   v-state"

# Build a mode-600 curl config file carrying the Authorization header.
# `printf` is a bash builtin (no fork), so the token never appears in
# `ps` or /proc/<pid>/cmdline — unlike `-H "Authorization: ..."` which
# does land in curl's argv. Allocate the body tempfile alongside the
# curl-config so one trap covers both.
CURL_CFG=$(mktemp -t relay-verify-curl)
BODY=$(mktemp -t relay-verify-body)
chmod 600 "$CURL_CFG"
trap 'rm -f "$CURL_CFG" "$BODY"' EXIT
printf 'header = "Authorization: Bearer %s"\n' "$TOK" > "$CURL_CFG"

# v2: endpoint reachable with bearer AND body is valid JSON. The
# SEED contract is JSON (empty list `[]` is valid on a freshly-deployed
# relay); a 200 with non-JSON body would let install-time verify pass
# while every downstream consumer (`jq` over the body) fails at runtime.
HTTP=$(curl -fsS -K "$CURL_CFG" \
            -o "$BODY" -w '%{http_code}' \
            "$URL/api/message")
[ "$HTTP" = "200" ] || { echo "FAIL v-reachable: $URL/api/message → $HTTP" >&2; exit 1; }
jq -e . "$BODY" >/dev/null \
  || { echo "FAIL v-reachable: $URL/api/message returned non-JSON body" >&2; exit 1; }
echo "OK   v-reachable"

# v3: auth enforced (no header → 401).
HTTP_NOAUTH=$(curl -s -o /dev/null -w '%{http_code}' "$URL/api/message")
[ "$HTTP_NOAUTH" = "401" ] || {
  echo "FAIL v-auth: expected 401 without bearer, got $HTTP_NOAUTH" >&2
  exit 1
}
echo "OK   v-auth"

echo "tree conforms"
