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
VIEWER_URL="git@github.com:plow-pbc/seed-life-dashboard-viewer.git"

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

# 5. Upstash KV integration. Idempotent: if it's already added, this is
#    a no-op. We don't parse the integration list — we just attempt the
#    add and accept "already exists" as success. The integration's
#    first-run consent is browser-based when newly added; that surfaces
#    naturally to the operator and is normal SEED behavior.
vercel integration add upstash-kv || true

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
  echo "Type or paste the value, then press Enter:" >&2
  read -r DASHBOARD_TOKEN </dev/tty
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

# 9. Land the state file atomically at mode 600.
mkdir -p "$APP_SUPPORT"
TMP_STATE=$(mktemp -t relay-state)
jq -n --arg url "$DEPLOY_URL" --arg tok "$DASHBOARD_TOKEN" \
  '{endpoint_url: $url, dashboard_token: $tok}' > "$TMP_STATE"
chmod 600 "$TMP_STATE"
mv "$TMP_STATE" "$STATE_FILE"

echo "" >&2
echo "Relay deployed:" >&2
echo "  endpoint_url: $DEPLOY_URL" >&2
echo "  state file:   $STATE_FILE (mode 600)" >&2
