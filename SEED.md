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

- Node ≥ 20, `git`, `jq`, `vercel` CLI (`npm i -g vercel@latest`). System tools at `/usr/bin/*`: `curl`, `mkdir`.

Run the following block to deploy the relay. The block is idempotent: re-running redeploys against the same Vercel project and rewrites the state file with the current values.

```bash
set -euo pipefail
bash "$(dirname "${BASH_SOURCE[0]:-$0}")/ref/deploy.sh"
```

## Objects

### Vercel project ^obj-vercel-project

- The linked Vercel project (`.vercel/project.json` inside the cloned viewer's `ref/app/`). The single source of truth for "this household's relay" as far as Vercel is concerned.

### Upstash KV resource ^obj-kv

- The Upstash KV resource the relay's `/api/message` route reads from and writes to. Provisioned via Vercel's marketplace integration (`vercel integration add upstash-kv`).

### State file ^obj-state

- `~/Library/Application Support/seed-life-dashboard-relay/state.json`, mode 600, owner-only. The **host-side, SEED-to-SEED handoff** containing `{endpoint_url, dashboard_token}`. Downstream consumers (`seed-life-dashboard-agent`, `seed-life-dashboard-viewer`, `seed-life-dashboard` umbrella) read this file at install time to wire themselves up.
- **NOT the same as Plow's VM-side `/config/secrets/dashboard-endpoint-url` and `/config/secrets/dashboard-token` runtime files.** Those are materialized by [`seed-life-dashboard-agent`](https://github.com/plow-pbc/seed-life-dashboard-agent)'s `^act-land-secrets` — it reads this SEED's `^obj-state` at install time and writes the two single-value files at `<plow-app-support>/agent-runtime/secrets/` (bind-mounted into the VM at `/config/secrets/`). This SEED owns the host-side handoff; the agent SEED owns the runtime materialization.

### DASHBOARD_TOKEN ^obj-token

- The operator-generated bearer the relay validates on every `/api/message` read/write. NOT logged, NOT echoed, NOT included in commits. The SEED prompts for it once (tier-3 per [Tier](#tier)) and lands it in two places: Vercel env (production) and the state file — nowhere else.

## Actions

### Vercel project is deployed ^act-deploy

- The install action MUST `git clone --depth 1` the viewer repo to a per-household cache directory under `~/Library/Caches/seed-life-dashboard-relay/source/`. Re-runs `git -C "$dir" fetch --depth=1` + `git -C "$dir" reset --hard origin/main` rather than re-cloning to keep the link state in `.vercel/` intact.
- The install action MUST `vercel link --yes` against a project named `life-dashboard-<short-machine-id>` (or accept an existing link). The `<short-machine-id>` is the first 8 hex chars of `sha256(hostname + per-machine-salt)` — same salt the SEED convention uses for `anon_machine_id`. This keeps multiple households on the same Mac (rare but possible) from colliding on project name.
- The install action MUST add the Upstash KV integration via `vercel integration add upstash-kv` (surfaced — the integration's first-run requires browser OAuth, can't be fully auto). KV credentials are exposed as `KV_URL` + `KV_REST_API_TOKEN` env vars on the deployment.
- The install action MUST collect `DASHBOARD_TOKEN` from the operator. Tier-3 — the SEED suggests `openssl rand -hex 32` as a copy-pasteable default but does NOT generate one silently (the operator picks). Once collected, the token is added via `vercel env add DASHBOARD_TOKEN production` (value via stdin, never argv).
- The install action MUST `vercel deploy --prod` and capture the resulting URL.
- A redeploy MUST NOT regenerate `DASHBOARD_TOKEN`. The operator re-running the install sees a "token already set on Vercel — reusing" message; the value is pulled from `vercel env pull` so the state file stays in sync.

### State file is landed ^act-land-state

- The install action MUST write `~/Library/Application Support/seed-life-dashboard-relay/state.json` atomically (mktemp + rename) with mode 600. Body:

```json
{
  "endpoint_url": "https://<deployment-url>",
  "dashboard_token": "<bearer>"
}
```

- The state file's `dashboard_token` value is the same one set as the Vercel env var — single source of truth for the bearer. Consumers read it to derive their own configuration.

## Verify

1. **State file present and well-formed.** ^v-state Does `~/Library/Application Support/seed-life-dashboard-relay/state.json` exist with mode `600`, parse as JSON, and contain non-empty `endpoint_url` (HTTPS) and `dashboard_token` strings? Expected: yes.
2. **Endpoint reachable.** ^v-reachable Does `curl -fsS -H "Authorization: Bearer $(jq -r .dashboard_token state.json)" "$(jq -r .endpoint_url state.json)/api/message"` return HTTP 200 with a JSON body (empty list `[]` is valid — relay was just deployed)? Expected: yes.
3. **Auth is enforced.** ^v-auth Does the same `curl` with NO Authorization header return 401? Expected: yes. (Catches a misconfigured deploy where `DASHBOARD_TOKEN` is unset on the Vercel side.)

A deterministic bash implementation of these three prompts lives at [`ref/verify.sh`](ref/verify.sh).

## Feedback

(default)

## Open

- The Vercel-deployable source lives in `seed-life-dashboard-viewer/ref/app/`. Extraction to its own repo `life-dashboard-relay-app` becomes the right move if a third consumer materializes (hosted multi-tenant, mobile companion). For v1 the clone-the-viewer approach keeps the source single-truth. ^o-source
- v1 = one Vercel deploy per household. A future shared multi-tenant relay with per-token isolation would obsolete the per-household install. ^o-multi-tenant
- No SHA / signature pin on the cloned viewer source. The agent trusts SSH GitHub + the operator's account access. ^o-pin
- No uninstall action. To remove: `vercel projects rm life-dashboard-<id>`, `rm -rf ~/Library/Application\ Support/seed-life-dashboard-relay`, `rm -rf ~/Library/Caches/seed-life-dashboard-relay`. ^o-uninstall

## Non-Goals

- Not Linux or Windows. macOS-only by inheritance from the `~/Library/Application Support` path convention.
- Not a shared multi-tenant deploy. Per-household by design until `^o-multi-tenant` is acted on.
- Not source for the React SPA — that lives in the viewer repo's `ref/app/`. This SEED is a deploy recipe, not a code mirror.
