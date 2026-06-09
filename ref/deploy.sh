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

# 1. Required tools. Checked BEFORE first use of any of them (xxd/shasum
#    in the machine-ID block, openssl in the headless DASHBOARD_TOKEN
#    auto-generation path) so a missing tool fails loudly up front.
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

# 3. Get / refresh the viewer source. Honor SEED_BRANCH (default: main) so the
#    whole SEED graph can be installed from one feature branch; fall back to main
#    if the viewer remote lacks that branch.
SEED_BRANCH="${SEED_BRANCH:-main}"
mkdir -p "$(dirname "$SRC_CACHE")"
if [ -d "$SRC_CACHE/.git" ]; then
  if git -C "$SRC_CACHE" fetch --depth=1 origin "$SEED_BRANCH" 2>/dev/null; then
    git -C "$SRC_CACHE" reset --hard FETCH_HEAD
  else
    git -C "$SRC_CACHE" fetch --depth=1 origin main
    git -C "$SRC_CACHE" reset --hard FETCH_HEAD
  fi
else
  git clone --depth 1 --branch "$SEED_BRANCH" "$VIEWER_URL" "$SRC_CACHE" 2>/dev/null \
    || git clone --depth 1 "$VIEWER_URL" "$SRC_CACHE"
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
  vercel integration add upstash-kv
fi

# 6. DASHBOARD_TOKEN: collect from the operator on first install; reuse
#    on subsequent runs. The presence check uses `vercel env ls` parsed
#    via grep; absence triggers token resolution (env / auto-gen / prompt).
#    The env-supplied value was captured + CR-stripped into DASH_ENV at §1b.
#    The full value is NEVER echoed — only its last 3 chars.
DASHBOARD_TOKEN=""
if [ -n "$DASH_ENV" ]; then
  # Env-supplied token is AUTHORITATIVE. Make Vercel prod match it — overwriting
  # any existing var, including a write-only "Sensitive" one whose value
  # `vercel env pull` cannot read back. That unreadable-Sensitive case is the
  # exact failure that otherwise forces regenerating the token on every redeploy
  # (and breaks token-consistency with downstream consumers); rm-then-add is the
  # only way to change an existing var's value via the CLI.
  DASHBOARD_TOKEN="$DASH_ENV"
  echo "DASHBOARD_TOKEN supplied via environment — making it authoritative on production." >&2
  vercel env rm DASHBOARD_TOKEN production --yes >/dev/null 2>&1 || true
  printf '%s' "$DASHBOARD_TOKEN" | vercel env add DASHBOARD_TOKEN production
elif vercel env ls production 2>/dev/null | grep -qE '^\s*DASHBOARD_TOKEN\b'; then
  echo "DASHBOARD_TOKEN already set on production — reusing (value resolved from Vercel below)." >&2
else
  # No env value and not yet on Vercel:
  #   - a TTY is present → prompt the operator on /dev/tty.
  #   - no controlling terminal (headless / agent-driven) → auto-generate.
  # Probe for a controlling terminal by actually OPENING /dev/tty — a node
  # can exist with rwx bits yet fail to open with no controlling terminal
  # (the headless / agent-harness case); [ -r ]/[ -w ] do not catch that.
  if ( : <>/dev/tty ) 2>/dev/null; then
    echo "" >&2
    echo "Generate a DASHBOARD_TOKEN (the bearer the relay validates on /api/message)." >&2
    echo "Suggested: openssl rand -hex 32" >&2
    echo "Type or paste the value (input will NOT be echoed), then press Enter:" >&2
    # `-s` silent: terminal doesn't echo as the operator types/pastes.
    # `printf '\n'` after read because -s eats the operator's Enter
    # keystroke too, leaving the cursor on the same line.
    IFS= read -r -s DASHBOARD_TOKEN </dev/tty
    printf '\n' >&2
    DASHBOARD_TOKEN="${DASHBOARD_TOKEN%$'\r'}"
    [ -n "$DASHBOARD_TOKEN" ] || {
      echo "no DASHBOARD_TOKEN supplied — aborting" >&2
      exit 1
    }
  else
    DASHBOARD_TOKEN=$(openssl rand -hex 32)
    echo "No DASHBOARD_TOKEN in env and no controlling terminal — auto-generated one (…${DASHBOARD_TOKEN: -3})." >&2
  fi
  printf '%s' "$DASHBOARD_TOKEN" | vercel env add DASHBOARD_TOKEN production
fi

# 7. Deploy. `vercel deploy` may emit trailing diagnostic lines (inspect
#    hints, warnings) after the deployment URL, so `tail -1` can poison
#    DEPLOY_URL with a non-URL. Extract the LAST https://...vercel.app
#    token from the full output instead — robust to extra trailing lines.
DEPLOY_OUT=$(vercel deploy --prod --yes)
DEPLOY_URL=$(printf '%s\n' "$DEPLOY_OUT" \
             | grep -oE 'https://[A-Za-z0-9.-]+\.vercel\.app' \
             | tail -1 || true)
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
