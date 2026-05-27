# seed-life-dashboard-relay

## Purpose

A SEED that deploys the per-household Vercel message relay backing the [life-dashboard](https://github.com/plow-pbc/seed-life-dashboard-viewer) kiosk. The relay is the `/api/message` endpoint that the Plow-side `ld-*` agent skills POST cards to and the Pi-side kiosk reads cards from — same source code as the viewer's Node service, deployed to Vercel for the producer↔consumer hop.

Installing this SEED:

1. Clones the viewer repo to access its dual-purpose `ref/app/` source.
2. Surfaces `vercel login` (browser OAuth).
3. Provisions an Upstash KV integration (Vercel marketplace).
4. Asks the operator to generate a `DASHBOARD_TOKEN` (the bearer the relay validates on every `/api/message` write/read).
5. Runs `vercel env add` + `vercel deploy --prod`.
6. Writes the deployment URL + bearer to `~/Library/Application Support/seed-life-dashboard-relay/state.json` (mode 600) so the agent SEED and the viewer SEED can wire themselves up without re-prompting the operator.

Per-household: each household gets its own deployment; no shared infrastructure across households in v1.

## Install

Tell any AI agent:

> Install `https://github.com/plow-pbc/seed-life-dashboard-relay`

## License

MIT
