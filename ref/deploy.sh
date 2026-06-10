#!/usr/bin/env bash
#
# seed-life-dashboard-relay — deploy the Vercel message relay.
#
# Idempotent: re-running redeploys against the same Vercel project and
# rewrites the state file with the current values. Each deploy mints a
# fresh DASHBOARD_TOKEN unless one is env-supplied (the operator-pinned
# case); consumers read the state file, so rotation is invisible to them.

set -euo pipefail

# 0. Paths & names.
APP_SUPPORT="$HOME/Library/Application Support/seed-life-dashboard-relay"
STATE_FILE="$APP_SUPPORT/state.json"
SRC_CACHE="$HOME/Library/Caches/seed-life-dashboard-relay/source"
VIEWER_URL="https://github.com/plow-pbc/seed-life-dashboard-viewer.git"

# 1. Required tools. Checked BEFORE first use of any of them (xxd/shasum
#    in the machine-ID block, openssl in the DASHBOARD_TOKEN minting
#    step) so a missing tool fails loudly up front.
for tool in vercel git jq curl shasum xxd openssl; do
  command -v "$tool" >/dev/null \
    || { echo "missing required tool: $tool" >&2; exit 1; }
done

# 1b. Capture any env-supplied secrets into UNEXPORTED locals, strip a
#     trailing CR (CRLF env file / pasted line), then `unset` the exported
#     originals BEFORE any external command (the machine-ID
#     `mkdir`/`xxd`/`shasum` block and `vercel whoami`, all below).
#     The script passes every secret to `vercel env add` via stdin, never
#     argv, so the `vercel`/`git` subprocesses don't need them in the env —
#     unsetting keeps them out of inherited child environments entirely
#     (defense-in-depth). The full values are NEVER echoed (last 3 chars only).
KV_URL_ENV="${KV_REST_API_URL:-}";   KV_URL_ENV="${KV_URL_ENV%$'\r'}"
KV_TOKEN_ENV="${KV_REST_API_TOKEN:-}"; KV_TOKEN_ENV="${KV_TOKEN_ENV%$'\r'}"
DASH_ENV="${DASHBOARD_TOKEN:-}";     DASH_ENV="${DASH_ENV%$'\r'}"
unset KV_REST_API_URL KV_REST_API_TOKEN DASHBOARD_TOKEN

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

# 4. Link the Vercel project. Unconditional (not guarded on an existing
#    .vercel/project.json): a stale cached link to a DIFFERENT project would
#    otherwise let `vercel deploy --prod` update one project while ENDPOINT_URL
#    (derived from $PROJECT_NAME below) points consumers at another. Relinking to
#    $PROJECT_NAME every run keeps the deployed project and the endpoint single-truth.
vercel link --yes --project "$PROJECT_NAME"

# 5. Upstash KV integration. Probe for existing provisioning via the
#    FULL credential pair — a partial set (URL without TOKEN or vice
#    versa) leaves the relay deployed against an unusable KV. Require
#    both KV_REST_API_URL AND KV_REST_API_TOKEN to consider it linked;
#    if either is missing, attempt the add and fail loudly.
KV_ENV=$(vercel env ls production 2>/dev/null || true)
if echo "$KV_ENV" | grep -qE '^\s*KV_REST_API_URL\b' \
   && echo "$KV_ENV" | grep -qE '^\s*KV_REST_API_TOKEN\b'; then
  echo "Upstash KV already linked (KV_REST_API_URL + KV_REST_API_TOKEN both present on prod)." >&2
elif [ -n "$KV_URL_ENV" ] && [ -n "$KV_TOKEN_ENV" ]; then
  # Headless / OAuth-free path: both credentials supplied in the
  # environment (captured + CR-stripped into locals at §1b). Push them
  # straight to prod and SKIP `vercel integration add upstash-kv` — the
  # only step that requires the browser OAuth flow. Values flow through
  # stdin (printf is a builtin, no fork), never as argv, so they stay out
  # of `ps` / /proc/<pid>/cmdline.
  echo "Upstash KV credentials supplied via environment — pushing to prod (skipping integration add)." >&2
  printf '%s' "$KV_URL_ENV"   | vercel env add KV_REST_API_URL production
  printf '%s' "$KV_TOKEN_ENV" | vercel env add KV_REST_API_TOKEN production
else
  # `--plan paid` (Upstash's free-tier Pay-As-You-Go) provisions the resource
  # non-interactively: the bare command defers PLAN SELECTION to a browser, and
  # that prompt is the only thing that made this step need a human. `-e production`
  # connects the new resource's KV_REST_API_* to prod, and `</dev/null` keeps it
  # fail-fast rather than hanging if input is ever needed. A first-EVER connection
  # of the Upstash integration to a brand-new Vercel account may still need a
  # one-time browser consent; every run after that (and any account already using
  # Upstash) is fully headless.
  vercel integration add upstash-kv --plan paid -e production </dev/null
fi

# 6. DASHBOARD_TOKEN: an env-supplied value is AUTHORITATIVE (the operator-
#    pinned case, captured + CR-stripped into DASH_ENV at §1b); otherwise
#    every deploy mints a fresh token. No reuse, no pull-back: consumers
#    read the state file written later this run, so rotation is invisible
#    to them. The full value is NEVER echoed — only its last 3 chars.
if [ -n "$DASH_ENV" ]; then
  DASHBOARD_TOKEN="$DASH_ENV"
  echo "DASHBOARD_TOKEN supplied via environment — making it authoritative on production." >&2
else
  DASHBOARD_TOKEN=$(openssl rand -hex 32)
  echo "Minted a fresh DASHBOARD_TOKEN (…${DASHBOARD_TOKEN: -3})." >&2
fi
# rm-then-add — the only way to overwrite an existing prod var via the CLI
# (a prior deploy's var would make a plain `env add` fail). Value flows via
# stdin (printf is a builtin, no fork), never argv.
vercel env rm DASHBOARD_TOKEN production --yes >/dev/null 2>&1 || true
printf '%s' "$DASHBOARD_TOKEN" | vercel env add DASHBOARD_TOKEN production \
  || { echo "DASHBOARD_TOKEN env add FAILED — the prod env var may be missing or stale; re-run this deploy" >&2; exit 1; }

# 7. Deploy. `vercel deploy` may emit trailing diagnostic lines (inspect
#    hints, warnings) after the deployment URL, so `tail -1` can poison
#    DEPLOY_URL with a non-URL. Extract the LAST https://...vercel.app
#    token from the full output instead — robust to extra trailing lines.
DEPLOY_OUT=$(vercel deploy --prod --yes)
DEPLOY_URL=$(printf '%s\n' "$DEPLOY_OUT" \
             | grep -oE 'https://[A-Za-z0-9.-]+\.vercel\.app' \
             | tail -1 || true)
[ -n "$DEPLOY_URL" ] || { echo "vercel deploy failed to return a URL" >&2; exit 1; }

# Use the stable PRODUCTION ALIAS for the state-file endpoint, not the
# per-deployment URL vercel just returned: the per-deployment URL is gated by
# Vercel Deployment Protection (SSO 401) for the kiosk + agent that read/write
# /api/message, while `https://<project>.vercel.app` is the public production
# domain. DEPLOY_URL above stays purely as the deploy-succeeded check.
ENDPOINT_URL="https://$PROJECT_NAME.vercel.app"

# 8. Land the state file atomically at mode 600. The temp file lives
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
  | jq -Rs --arg url "$ENDPOINT_URL" '{endpoint_url: $url, dashboard_token: .}' \
  > "$TMP_STATE"
chmod 600 "$TMP_STATE"
mv "$TMP_STATE" "$STATE_FILE"

echo "" >&2
echo "Relay deployed:" >&2
echo "  endpoint_url: $ENDPOINT_URL" >&2
echo "  state file:   $STATE_FILE (mode 600)" >&2
