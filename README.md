# seed-life-dashboard-relay

> **Superseded (2026-06).** The message backend now lives in
> [`seed-life-dashboard-viewer`](https://github.com/plow-pbc/seed-life-dashboard-viewer)
> and runs on the household Pi itself — the umbrella
> [`seed-life-dashboard`](https://github.com/plow-pbc/seed-life-dashboard) mints the
> token, derives the endpoint from `LD_PI_SSH_TARGET`, and no longer installs this
> SEED. No Vercel or Upstash account is needed. This repo is retained for history;
> to remove an old deploy, see the uninstall notes in `SEED.md` § Open Items.

## Purpose

A SEED that **used to** deploy the per-household Vercel message relay backing the [life-dashboard](https://github.com/plow-pbc/seed-life-dashboard-viewer) kiosk — the `/api/message` endpoint Plow-side skills POSTed cards to. The deploy contract (Vercel project + Upstash KV + the `state.json` handoff the agent/viewer SEEDs consumed) is retired and owned by git history (`git log -- SEED.md README.md`); the backend is now the viewer's own server on the Pi.

## Install

**Do not install this SEED.** It is superseded — see the banner above. An agent asked to
install it should halt and install
[`seed-life-dashboard`](https://github.com/plow-pbc/seed-life-dashboard) instead, which
provisions the Pi-hosted backend with no Vercel or Upstash account. To tear down an old
relay deploy, see `SEED.md` § Open Items (uninstall notes).

## License

MIT
