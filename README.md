# seed-life-dashboard-relay

## Purpose

A SEED that deploys the per-household Vercel message relay backing the [life-dashboard](https://github.com/plow-pbc/seed-life-dashboard-viewer) kiosk. The relay is the `/api/message` endpoint that the Plow-side `ld-*` agent skills POST cards to and the Pi-side kiosk reads cards from — same source code as the viewer's Node service, deployed to Vercel for the producer↔consumer hop.

Installing this SEED:

1. Clones the viewer repo to access its dual-purpose `ref/app/` source.
2. Surfaces `vercel login` (browser OAuth) only if not already logged in.
3. Ensures Upstash KV credentials (`KV_REST_API_URL` + `KV_REST_API_TOKEN`) are on prod. Reused if already present on prod; else, if both are supplied in the environment, pushed straight to prod (skipping the integration step); otherwise provisioned with `vercel integration add upstash-kv --plan paid -e production`, which is headless once the Upstash integration is authorized on the Vercel account (only a first-ever account authorization needs a browser).
4. Resolves a `DASHBOARD_TOKEN` (the bearer the relay validates on every `/api/message` write/read): an env-supplied value is authoritative and overwrites whatever is on prod; otherwise an already-set prod token is reused (the no-env redeploy case); otherwise it's auto-generated via `openssl rand -hex 32` when there's no controlling terminal (headless install); otherwise prompted interactively on `/dev/tty`.
5. Runs `vercel env add` + `vercel deploy --prod`.
6. Writes the production-alias URL (`https://<project>.vercel.app`) + bearer to `~/Library/Application Support/seed-life-dashboard-relay/state.json` (mode 600) so the agent SEED and the viewer SEED can wire themselves up without re-prompting the operator.

A fully headless / agent-driven install needs no interactive prompt and (with Vercel already logged in) no browser OAuth — env-supplied KV credentials skip the integration step entirely, and otherwise `--plan paid` provisions Upstash headlessly once the integration is authorized on the account; `DASHBOARD_TOKEN` is env-supplied or auto-generated.

This state file is the **host-side handoff** between SEEDs. It is NOT the same as Plow's VM-side `/config/secrets/dashboard-{endpoint-url,token}` runtime files — those are materialized by [`seed-life-dashboard-agent`](https://github.com/plow-pbc/seed-life-dashboard-agent) when it reads this state file and writes single-value files into `<plow-app-support>/agent-runtime/secrets/` (which plowd bind-mounts into the VM at `/config/secrets/`). This SEED owns the host-side handoff; the agent SEED owns the VM-runtime materialization.

**`endpoint_url` contract:** the state file stores the Vercel **production-alias base URL** only (`https://<project>.vercel.app`, e.g. `https://life-dashboard-abc123.vercel.app`) — the stable, public production domain, not the SSO-gated per-deployment URL `vercel deploy` returns. Downstream materialization is responsible for appending `/api/message` where the consumer needs the POST/GET endpoint — `seed-life-dashboard-agent` writes `/config/secrets/dashboard-endpoint-url` = `${endpoint_url%/}/api/message`; the umbrella SEED writes viewer's `.env MESSAGE_API_URL` = `${endpoint_url%/}/api/message` (the **full path**, not the base — the Pi's `server.js` appends only the `?type=` query string and treats `MESSAGE_API_URL` as the complete endpoint).

Per-household: each household gets its own deployment; no shared infrastructure across households in v1.

## Install

Tell any AI agent:

> Install `https://github.com/plow-pbc/seed-life-dashboard-relay`

## License

MIT
