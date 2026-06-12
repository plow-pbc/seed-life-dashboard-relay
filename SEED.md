# Purpose

> See [README#Purpose](README.md#purpose).

## Normative Language

The key words MUST, MUST NOT, REQUIRED, SHALL, SHALL NOT, SHOULD, SHOULD NOT, RECOMMENDED, MAY, and OPTIONAL in this document are to be interpreted as described in RFC 2119.

## Dependencies

**SUPERSEDED (2026-06) — this SEED MUST NOT be installed.** The message backend now lives in [`seed-life-dashboard-viewer`](https://github.com/plow-pbc/seed-life-dashboard-viewer) and runs on the household Pi; the umbrella [`seed-life-dashboard`](https://github.com/plow-pbc/seed-life-dashboard) mints the token and derives the endpoint — no Vercel or Upstash account exists in the graph anymore. The retired deploy/verify contract (Vercel project, Upstash KV, state-file handoff, `ref/deploy.sh`, `ref/verify.sh`) is owned by git history (`git log -- SEED.md`); `ref/` is retained as historical reference only and is not normatively linked. There is nothing to collect at preflight.

The SEED's one executable block halts unconditionally, so an agent walking this SEED cannot provision the obsolete relay:

```bash
echo "SUPERSEDED: seed-life-dashboard-relay is retired — install" >&2
echo "https://github.com/plow-pbc/seed-life-dashboard instead (Pi-hosted backend)." >&2
exit 1
```

## Verification

> Retired — there is no live deployment contract to verify. Do not run `ref/verify.sh`.

## Feedback

(default)

## Open Items

- **Uninstall an old deploy** (the one intentionally live procedure): `vercel projects rm life-dashboard-<id>`, `rm -rf ~/Library/Application\ Support/seed-life-dashboard-relay`, `rm -rf ~/Library/Caches/seed-life-dashboard-relay`. If the household's Upstash KV resource is no longer used by anything else, remove it from the Vercel dashboard's integrations page.

## Non-Goals

- Not installable. Superseded by the Pi-hosted backend (see Dependencies).
