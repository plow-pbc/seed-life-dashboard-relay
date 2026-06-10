#!/usr/bin/env bash
#
# seed-life-dashboard-relay — deploy the Vercel message relay.
#
# Idempotent: re-running redeploys against the same Vercel project and
# rewrites the state file with the current values. A redeploy reuses
# DASHBOARD_TOKEN when Vercel can read it back; a write-only "Sensitive"
# var can't be, so the prior token is recovered from the state file —
# or rotated to a fresh one when it holds no usable token (consumers read
# the state file, so either stays consistent).

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

# 3. Get / refresh the viewer source.
# TEST PLUMBING (overnight-latest branch only) — DO NOT MERGE to main;
# see seed-life-dashboard d6ac834. main's version tracks origin/main.
mkdir -p "$(dirname "$SRC_CACHE")"
if [ -d "$SRC_CACHE/.git" ]; then
  git -C "$SRC_CACHE" fetch --depth=1 origin overnight-latest
  git -C "$SRC_CACHE" reset --hard FETCH_HEAD
else
  git clone --depth 1 --branch overnight-latest "$VIEWER_URL" "$SRC_CACHE"
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
  vercel integration add upstash-kv
fi

# 6. DASHBOARD_TOKEN: collect from the operator on first install; reuse
#    on subsequent runs. The presence check uses `vercel env ls` parsed
#    via grep; absence triggers token resolution (env / auto-gen / prompt).
#    The env-supplied value was captured + CR-stripped into DASH_ENV at §1b.
#    The full value is NEVER echoed — only its last 3 chars.

# Make $DASHBOARD_TOKEN authoritative on prod — overwriting any existing var,
# including a write-only "Sensitive" one whose value `vercel env pull` cannot
# read back. rm-then-add is the only way to change an existing var's value via
# the CLI. The value flows through stdin (printf is a builtin, no fork), never
# argv, so it stays out of `ps` / /proc/<pid>/cmdline.
push_token_to_prod() {
  vercel env rm DASHBOARD_TOKEN production --yes >/dev/null 2>&1 || true
  printf '%s' "$DASHBOARD_TOKEN" | vercel env add DASHBOARD_TOKEN production \
    || { echo "DASHBOARD_TOKEN removed but re-add FAILED — production now has NO bearer; re-run this deploy to restore it" >&2; exit 1; }
}

DASHBOARD_TOKEN=""
if [ -n "$DASH_ENV" ]; then
  # Env-supplied token is AUTHORITATIVE. The unreadable-Sensitive case is the
  # exact failure that otherwise forces regenerating the token on every redeploy
  # (and breaks token-consistency with downstream consumers).
  DASHBOARD_TOKEN="$DASH_ENV"
  echo "DASHBOARD_TOKEN supplied via environment — making it authoritative on production." >&2
  push_token_to_prod
elif vercel env ls production 2>/dev/null | grep -qE '^\s*DASHBOARD_TOKEN\b'; then
  # Already on Vercel — reuse. `vercel env pull` writes the value (plus all
  # other prod vars) to a local file; we extract the one var and shred the
  # file. Resolved HERE, before the deploy, because a rotation pushed after
  # `vercel deploy --prod` wouldn't be baked into the running deployment.
  echo "DASHBOARD_TOKEN already set on production — reusing (value resolved from Vercel)." >&2
  ENV_PULL=$(mktemp -t vercel-env.XXXXXX)
  trap 'rm -f "$ENV_PULL"' EXIT
  vercel env pull "$ENV_PULL" --environment=production --yes >/dev/null
  DASHBOARD_TOKEN=$(grep -E '^DASHBOARD_TOKEN=' "$ENV_PULL" \
                    | sed 's/^DASHBOARD_TOKEN=//; s/^"//; s/"$//' || true)
  rm -f "$ENV_PULL"
  trap - EXIT
  if [ -z "$DASHBOARD_TOKEN" ]; then
    # `env pull` returned no value — likely a write-only "Sensitive" var,
    # whose value the CLI cannot read back. Recover the token from the prior
    # run's state file when one exists (keeps the bearer stable for
    # already-materialized consumers); otherwise rotate to a fresh one.
    # Either way make it authoritative (same rm-then-add as the env-supplied
    # path) — deliberately re-added as a plain var so the next redeploy can
    # read it back. Downstream consumers all read the state file written
    # below, so the result is consistent by construction.
    DASHBOARD_TOKEN=$(jq -r '.dashboard_token // empty' "$STATE_FILE" 2>/dev/null || true)
    if [ -n "$DASHBOARD_TOKEN" ]; then
      echo "env pull returned no value for DASHBOARD_TOKEN (likely a write-only Sensitive var) — recovered the prior token from the state file (…${DASHBOARD_TOKEN: -3}); re-pushing it as a readable var." >&2
    else
      DASHBOARD_TOKEN=$(openssl rand -hex 32)
      echo "env pull returned no value for DASHBOARD_TOKEN (likely a write-only Sensitive var) and no usable prior token in the state file — rotated to a fresh token (…${DASHBOARD_TOKEN: -3})." >&2
    fi
    push_token_to_prod
  fi
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
