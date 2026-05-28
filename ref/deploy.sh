#!/usr/bin/env bash
#
# seed-life-dashboard-relay — deploy the Vercel message relay.
#
# Idempotent: re-running redeploys against the same Vercel project and
# rewrites the state file with the current values. A redeploy reuses
# DASHBOARD_TOKEN (does not regenerate); the operator picks the value
# once at first install.

set -euo pipefail

# 0. Paths & names.
APP_SUPPORT="$HOME/Library/Application Support/seed-life-dashboard-relay"
STATE_FILE="$APP_SUPPORT/state.json"
SRC_CACHE="$HOME/Library/Caches/seed-life-dashboard-relay/source"
VIEWER_URL="https://github.com/plow-pbc/seed-life-dashboard-viewer.git"

# Machine ID — first 8 hex chars of sha256(hostname + per-machine salt).
SALT_FILE="$HOME/.config/seed/machine-id"
mkdir -p "$(dirname "$SALT_FILE")"
if [ ! -s "$SALT_FILE" ]; then
  head -c 16 /dev/urandom | xxd -p > "$SALT_FILE"
  chmod 600 "$SALT_FILE"
fi
SHORT_ID=$(printf '%s%s' "$(hostname)" "$(cat "$SALT_FILE")" \
           | shasum -a 256 | cut -c1-8)
PROJECT_NAME="life-dashboard-$SHORT_ID"

# 1. Required tools.
for tool in vercel git jq curl shasum xxd; do
  command -v "$tool" >/dev/null \
    || { echo "missing required tool: $tool" >&2; exit 1; }
done

# 2. Vercel login surface. We can't drive the OAuth browser flow ourselves.
#    A logged-in `vercel whoami` exits 0; otherwise we surface the command
#    and abort so the operator can complete it.
if ! vercel whoami >/dev/null 2>&1; then
  echo "" >&2
  echo "Vercel login required. Run:" >&2
  echo "" >&2
  echo "    vercel login" >&2
  echo "" >&2
  echo "Then re-run this SEED." >&2
  exit 1
fi

# 3. Get / refresh the viewer source.
mkdir -p "$(dirname "$SRC_CACHE")"
if [ -d "$SRC_CACHE/.git" ]; then
  git -C "$SRC_CACHE" fetch --depth=1 origin main
  git -C "$SRC_CACHE" reset --hard origin/main
else
  git clone --depth 1 "$VIEWER_URL" "$SRC_CACHE"
fi
cd "$SRC_CACHE/ref/app"

# 4. Link / re-link the Vercel project.
if [ ! -s ".vercel/project.json" ]; then
  vercel link --yes --project "$PROJECT_NAME"
fi

# 5. Upstash KV integration. Probe for existing provisioning via the
#    FULL credential pair — a partial set (URL without TOKEN or vice
#    versa) leaves the relay deployed against an unusable KV. Require
#    both KV_REST_API_URL AND KV_REST_API_TOKEN to consider it linked;
#    if either is missing, attempt the add and fail loudly.
KV_ENV=$(vercel env ls production 2>/dev/null || true)
if echo "$KV_ENV" | grep -qE '^\s*KV_REST_API_URL\b' \
   && echo "$KV_ENV" | grep -qE '^\s*KV_REST_API_TOKEN\b'; then
  echo "Upstash KV already linked (KV_REST_API_URL + KV_REST_API_TOKEN both present on prod)." >&2
else
  vercel integration add upstash-kv
fi

# 6. DASHBOARD_TOKEN: collect from the operator on first install; reuse
#    on subsequent runs. The presence check uses `vercel env ls` parsed
#    via grep; absence triggers the tier-3 prompt.
DASHBOARD_TOKEN=""
if vercel env ls production 2>/dev/null | grep -qE '^\s*DASHBOARD_TOKEN\b'; then
  echo "DASHBOARD_TOKEN already set on production — reusing." >&2
else
  echo "" >&2
  echo "Generate a DASHBOARD_TOKEN (the bearer the relay validates on /api/message)." >&2
  echo "Suggested: openssl rand -hex 32" >&2
  echo "Type or paste the value (input will NOT be echoed), then press Enter:" >&2
  # `-s` silent: terminal doesn't echo as the operator types/pastes.
  # `printf '\n'` after read because -s eats the operator's Enter
  # keystroke too, leaving the cursor on the same line.
  IFS= read -r -s DASHBOARD_TOKEN </dev/tty
  printf '\n' >&2
  [ -n "$DASHBOARD_TOKEN" ] || {
    echo "no DASHBOARD_TOKEN supplied — aborting" >&2
    exit 1
  }
  printf '%s' "$DASHBOARD_TOKEN" | vercel env add DASHBOARD_TOKEN production
fi

# 7. Deploy.
DEPLOY_URL=$(vercel deploy --prod --yes | tail -1)
[ -n "$DEPLOY_URL" ] || { echo "vercel deploy failed to return a URL" >&2; exit 1; }

# 8. Resolve the DASHBOARD_TOKEN value for the state file. On a reused
#    token (the common idempotent re-run case) the value is on Vercel,
#    not in $DASHBOARD_TOKEN — we have to ask Vercel for it. `vercel env
#    pull` writes it (plus all other prod vars) to a local file; we
#    extract the one var and shred the file.
if [ -z "$DASHBOARD_TOKEN" ]; then
  ENV_PULL=$(mktemp -t vercel-env)
  trap 'rm -f "$ENV_PULL"' EXIT
  vercel env pull "$ENV_PULL" --environment=production --yes >/dev/null
  DASHBOARD_TOKEN=$(grep -E '^DASHBOARD_TOKEN=' "$ENV_PULL" \
                    | sed 's/^DASHBOARD_TOKEN=//; s/^"//; s/"$//')
  rm -f "$ENV_PULL"
  trap - EXIT
fi
[ -n "$DASHBOARD_TOKEN" ] || {
  echo "could not resolve DASHBOARD_TOKEN from Vercel env after deploy" >&2
  exit 1
}

# 9. Land the state file atomically at mode 600. The temp file lives
#    inside $APP_SUPPORT (not /tmp) so the final `mv` is a same-
#    filesystem atomic rename — mktemp -t targets $TMPDIR which on
#    macOS is /var/folders/..., a different volume from
#    ~/Library/Application Support, where mv falls back to copy+unlink
#    and can be observed half-written.
mkdir -p "$APP_SUPPORT"
TMP_STATE=$(mktemp "$APP_SUPPORT/.state.json.XXXXXX")
# Bearer flows through stdin → jq's raw-slurp, never as a --arg value
# (jq's argv is visible in /proc/<pid>/cmdline while the call is live).
# `-Rs` reads stdin as one raw string into `.`; we strip the trailing
# newline `printf '%s'` already omits and assemble the JSON from there.
printf '%s' "$DASHBOARD_TOKEN" \
  | jq -Rs --arg url "$DEPLOY_URL" '{endpoint_url: $url, dashboard_token: .}' \
  > "$TMP_STATE"
chmod 600 "$TMP_STATE"
mv "$TMP_STATE" "$STATE_FILE"

echo "" >&2
echo "Relay deployed:" >&2
echo "  endpoint_url: $DEPLOY_URL" >&2
echo "  state file:   $STATE_FILE (mode 600)" >&2
