# Purpose

> See [README#Purpose](README.md#purpose).

## Normative Language

The key words MUST, MUST NOT, REQUIRED, SHALL, SHALL NOT, SHOULD, SHOULD NOT, RECOMMENDED, MAY, and OPTIONAL in this document are to be interpreted as described in RFC 2119.

## Dependencies

API / per-machine state:

- A Mac running macOS. Authored on macOS 26.4.1 / arm64.
- A Vercel account. The SEED surfaces `vercel login` but does not provision the account itself.
- Read access to `https://github.com/plow-pbc/seed-life-dashboard-viewer` (the source the deployment is built from).

Software:

- Node ≥ 20.6, `git`, `jq`, `vercel` CLI (`npm i -g vercel@latest`). System tools at `/usr/bin/*`: `curl`, `shasum` (machine-ID hash), `xxd` (salt generation), `openssl` (`DASHBOARD_TOKEN` minting) — `ref/deploy.sh` hard-requires these up front and aborts loudly if any is missing. `mkdir` is used too but assumed present as a coreutil, not gated by the check.

### Requirements

| kind | label | phase | satisfy | bypass |
|---|---|---|---|---|
| account | Vercel account | preflight | `vercel login` (browser OAuth) | `VERCEL_TOKEN` |
| tool | `vercel` CLI, Node ≥ 20.6, `git`, `jq`, `curl`, `shasum`, `xxd`, `openssl` | preflight | `npm i -g vercel@latest`; install Node / git / jq; `curl` / `shasum` / `xxd` / `openssl` ship at `/usr/bin/*` on macOS | |
| auth | Upstash KV provisioning (first run needs browser OAuth) | in-flow | `vercel integration add upstash-kv` (browser OAuth) | `KV_REST_API_URL`+`KV_REST_API_TOKEN` |
| input | `DASHBOARD_TOKEN` (relay bearer) | preflight | `DASHBOARD_TOKEN` env, else auto-generated `openssl rand -hex 32` | |

Run the following block to deploy the relay. The block is idempotent: re-running redeploys against the same Vercel project and rewrites the state file with the current values.

```bash
set -euo pipefail
bash "$(dirname "${BASH_SOURCE[0]:-$0}")/ref/deploy.sh"
```

## Objects

### Vercel project

- The linked Vercel project (`.vercel/project.json` inside the cloned viewer's `ref/app/`). The single source of truth for "this household's relay" as far as Vercel is concerned.

### Upstash KV resource

- The Upstash KV resource the relay's `/api/message` route reads from and writes to. Resolved in order (see the [KV resolution action](#vercel-project-is-deployed)): reused if already present on prod, else pushed straight to prod when `KV_REST_API_URL` + `KV_REST_API_TOKEN` are env-supplied (headless / OAuth-free), else provisioned via Vercel's marketplace integration (`vercel integration add upstash-kv`) as the browser-OAuth fallback.

### State file

- `~/Library/Application Support/seed-life-dashboard-relay/state.json`, mode 600, owner-only. The **host-side, SEED-to-SEED handoff** containing `{endpoint_url, dashboard_token}`. Downstream consumers (`seed-life-dashboard-agent`, `seed-life-dashboard-viewer`, `seed-life-dashboard` umbrella) read this file at install time to wire themselves up.
- **`endpoint_url` is the Vercel production-alias BASE URL** (`https://<project>.vercel.app`, e.g. `https://life-dashboard-abc123.vercel.app`) — the stable, public production domain. It is NOT the per-deployment URL `vercel deploy --prod` returns (that URL is SSO-gated by Vercel Deployment Protection → 401 for the kiosk/agent, so it's captured only as the deploy-succeeded check), and NOT the full `/api/message` path. Downstream materialization is responsible for appending `/api/message` where the consumer needs a POST/GET endpoint. Specifically:
  - `seed-life-dashboard-agent`'s [dashboard-secrets landing action](https://github.com/plow-pbc/seed-life-dashboard-agent/blob/main/SEED.md#dashboard-secrets-are-landed) writes `/config/secrets/dashboard-endpoint-url` = `${endpoint_url%/}/api/message` so `ld-shared/scripts/post_to_kiosk.py` (which `urlopen`s the file's content directly) hits the message-relay route.
  - `seed-life-dashboard-viewer`'s `.env MESSAGE_API_URL` is the **full `/api/message` path** (`${endpoint_url%/}/api/message`) — the Pi's `server.js` treats `MESSAGE_API_URL` as the complete endpoint and only appends the `?type=` query string (`fetch(${MESSAGE_API_URL}${qs})`), it does NOT append `/api/message`. The append happens upstream: the umbrella SEED [`seed-life-dashboard`](https://github.com/plow-pbc/seed-life-dashboard) reads this state file's base `endpoint_url` and writes `${endpoint_url%/}/api/message` into the viewer's `.env MESSAGE_API_URL`.
- **NOT the same as Plow's VM-side `/config/secrets/dashboard-endpoint-url` and `/config/secrets/dashboard-token` runtime files.** Those are materialized by [`seed-life-dashboard-agent`](https://github.com/plow-pbc/seed-life-dashboard-agent)'s [dashboard-secrets landing action](https://github.com/plow-pbc/seed-life-dashboard-agent/blob/main/SEED.md#dashboard-secrets-are-landed) — it reads this SEED's [state file](#state-file) at install time and writes the two single-value files at `<plow-app-support>/agent-runtime/secrets/` (bind-mounted into the VM at `/config/secrets/`). This SEED owns the host-side handoff; the agent SEED owns the runtime materialization (and the `/api/message` append).

### DASHBOARD_TOKEN

- The bearer the relay validates on every `/api/message` read/write. NOT logged, NOT echoed, NOT included in commits. Resolved in order: an **env-supplied `DASHBOARD_TOKEN` is authoritative** (the operator-pinned case); otherwise **every deploy mints a fresh token** via `openssl rand -hex 32` — no reuse, no pull-back. Rotation is invisible to consumers: they read the state file, which is rewritten with the same value each run. It lands in two places: Vercel env (production) and the state file — nowhere else.

## Actions

### Vercel project is deployed

- The install action MUST `git clone --depth 1` the viewer repo to a per-household cache directory under `~/Library/Caches/seed-life-dashboard-relay/source/`. Re-runs `git -C "$dir" fetch --depth=1` + `git -C "$dir" reset --hard origin/main` rather than re-cloning to keep the link state in `.vercel/` intact.
- The install action MUST `vercel link --yes --project life-dashboard-<short-machine-id>` **unconditionally** (every run, not only when `.vercel/project.json` is missing) so a stale cached link can't diverge the deployed project from the one `endpoint_url` (`https://<project>.vercel.app`) names. The `<short-machine-id>` is the first 8 hex chars of `sha256(hostname + per-machine-salt)` — same salt the SEED convention uses for `anon_machine_id` — keeping multiple households on the same Mac from colliding on project name.
- The install action MUST ensure `KV_REST_API_URL` + `KV_REST_API_TOKEN` are set on the production deployment. Resolution order:
  1. **Already linked** — if both vars are already present on prod (idempotent re-run), the action reuses them and does nothing.
  2. **Env-supplied (headless / OAuth-free)** — if both `KV_REST_API_URL` and `KV_REST_API_TOKEN` are present in the environment, the action pushes them straight to prod via `vercel env add` (values via stdin, never argv; a trailing CR is stripped) and **SKIPS** `vercel integration add upstash-kv`. This is the path that avoids the browser OAuth flow entirely.
  3. **Fallback (browser OAuth)** — otherwise the action runs `vercel integration add upstash-kv`, whose first run requires browser OAuth and can't be fully automated. This provisions the Upstash KV resource and exposes the credentials as `KV_REST_API_URL` + `KV_REST_API_TOKEN`.
- Both var names match what `ref/deploy.sh`'s idempotent-skip probe and the env-supplied path look for.
- The install action MUST land a `DASHBOARD_TOKEN` on prod, BEFORE `vercel deploy --prod` (env vars are snapshotted into the deployment at build time). Resolution order:
  1. **Env-supplied (authoritative)** — if `DASHBOARD_TOKEN` is present in the environment, it WINS (a trailing CR is stripped; only the last 3 chars are ever echoed).
  2. **Fresh-minted** — otherwise the action generates one via `openssl rand -hex 32`. Every no-env deploy rotates; consumers are unaffected (they read the state file written the same run).
- Either way the token is landed via `vercel env rm DASHBOARD_TOKEN production --yes` then `vercel env add` (value via stdin, never argv) — rm-then-add is the only way to overwrite a var a prior deploy left on prod.
- The install action MUST `vercel deploy --prod`; the returned per-deployment URL is captured only as the deploy-succeeded check — NOT as the state-file endpoint (see [State file](#state-file)).

### State file is landed

- The install action MUST write `~/Library/Application Support/seed-life-dashboard-relay/state.json` atomically (mktemp + rename) with mode 600. Body:

```json
{
  "endpoint_url": "https://<project>.vercel.app",
  "dashboard_token": "<bearer>"
}
```

- The state file's `dashboard_token` value is the same one set as the Vercel env var — single source of truth for the bearer. Consumers read it to derive their own configuration.

## Verification

1. **State file present and well-formed.** Does `~/Library/Application Support/seed-life-dashboard-relay/state.json` exist with mode `600`, parse as JSON, and contain non-empty `endpoint_url` (HTTPS) and `dashboard_token` strings? Expected: yes.
2. **Endpoint reachable.** Run `bash ref/verify.sh` (or the equivalent — see [`ref/verify.sh`](ref/verify.sh) for the exact mode-600 `curl -K`-config pattern that keeps `dashboard_token` out of process argv). The verifier asserts `GET <endpoint_url>/api/message` with bearer returns HTTP 200 with a JSON body (empty list `[]` is valid — relay was just deployed). Do NOT inline `curl -H "Authorization: Bearer $(jq -r .dashboard_token ...)"` literally: that puts the household token in process argv (visible via `ps` / `/proc/<pid>/cmdline`). Expected: yes.
3. **Auth is enforced.** Does the same `curl` with NO Authorization header return 401? Expected: yes. (Catches a misconfigured deploy where `DASHBOARD_TOKEN` is unset on the Vercel side.)

A deterministic bash implementation of these three prompts lives at [`ref/verify.sh`](ref/verify.sh).

## Feedback

(default)

## Open Items

- The Vercel-deployable source lives in `seed-life-dashboard-viewer/ref/app/`. Extraction to its own repo `life-dashboard-relay-app` becomes the right move if a third consumer materializes (hosted multi-tenant, mobile companion). For v1 the clone-the-viewer approach keeps the source single-truth.

#### Multi-tenant relay

v1 = one Vercel deploy per household. A future shared multi-tenant relay with per-token isolation would obsolete the per-household install.

- No SHA / signature pin on the cloned viewer source. The agent trusts SSH GitHub + the operator's account access.
- No uninstall action. To remove: `vercel projects rm life-dashboard-<id>`, `rm -rf ~/Library/Application\ Support/seed-life-dashboard-relay`, `rm -rf ~/Library/Caches/seed-life-dashboard-relay`.

## Non-Goals

- Not Linux or Windows. macOS-only by inheritance from the `~/Library/Application Support` path convention.
- Not a shared multi-tenant deploy. Per-household by design until the [multi-tenant relay](#multi-tenant-relay) is acted on.
- Not source for the React SPA — that lives in the viewer repo's `ref/app/`. This SEED is a deploy recipe, not a code mirror.
