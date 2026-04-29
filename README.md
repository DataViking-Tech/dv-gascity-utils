# dv-gascity-utils

DataViking-Tech utilities and patterns for [Gas City](https://docs.gascityhall.com/) multi-city deployments.

## Where to start

| You're here because… | Open this |
|---|---|
| You have a fresh machine and want a working Gas City | **[docs/SETUP-GUIDE.md](docs/SETUP-GUIDE.md)** — linear scaffold-from-scratch walkthrough |
| Something is broken and you need to fix it now | **[docs/diagnostic-runbook.md](docs/diagnostic-runbook.md)** — symptom → command → recovery |
| You want to know *why* the architecture looks the way it does | **[docs/lessons-learned.md](docs/lessons-learned.md)** — patterns and gotchas from the live build |

## Reference docs

- **[docs/cross-city-comms.md](docs/cross-city-comms.md)** — Caddy gateway + `peers.toml` + `gcx` wrapper + the in-band `X-Gascity-Origin` reply convention + per-city `mail-nudge` order.
- **[docs/multi-city-shared-dolt.md](docs/multi-city-shared-dolt.md)** — running multiple co-located cities against a single shared Dolt server; one database per rig prefix; the `asgard → yggdrasil` migration recipe; reserved-word prefix gotchas.
- **[docs/shared-rig-prefix.md](docs/shared-rig-prefix.md)** — joining the *same* rig from multiple cities (one bead pool, polecats from any host) instead of forking duplicate prefix databases. Recipe + helper + `metadata`-table audit.
- **[docs/rig-merge-strategy.md](docs/rig-merge-strategy.md)** — how the polecat picks `direct` vs `mr` merge mode at submit time, the resolution order (existing metadata > per-rig override file > auto-detect via GitHub branches API > fallback `direct`), and how to install the `gc-fix-merge-strategy` patch helper.
- **[docs/refinery-materialization.md](docs/refinery-materialization.md)** — root-cause writeup for the on-demand refinery slot stuck at `reserved-unmaterialized`, manual wake recipe, sister-bug coverage for the refinery rejection bounce.

## Packs

- **`packs/gascity-comms/`** — cross-city mail tooling and per-host helpers. Ships:
  - `gcx` — city-aware mail wrapper (`send`, `reply`, `inbox`, `read` across `<city>:<alias>` / `@<city>` addressing)
  - `mail-nudge` order — auto-wakes recipient sessions when their inbox grows
  - `pr-ci-watch` order — closes the loop on PR-protected rigs: tracks `merge_result=pull_request` / `merge_result=blocked` beads, auto-reslings on CI failure (preserves `existing_pr` so the same PR is reused), bails to mayor at `resling_count >= 3`
  - `gc-rig-join` — joins an existing shared-prefix rig from a second city (see `docs/shared-rig-prefix.md`)
  - `gc-fix-refinery-routing` — idempotent in-place patch of the gastown system pack so polecat done-sequence and refinery rejection-bounce both write the full-form `<rig>/gastown.refinery` / `<rig>/gastown.polecat` (see `docs/refinery-materialization.md`)
  - `gc-fix-merge-strategy` — idempotent in-place patch of the gastown system pack so the polecat's submit-and-exit step auto-detects PR-protected branches and sets `metadata.merge_strategy=mr` (see `docs/rig-merge-strategy.md`)
  - `peers.toml.template` — starter for the per-host peer registry

  Importable into any Gas City workspace.

## Status

Pre-alpha. Built during initial multi-city setup of `yggdrasil` (HQ on `mani-mac-mini`), `midgard` (`sol-mac-mini`), and `asgard` (external-agent home, also on `mani-mac-mini`). Patterns and pack contents are evolving as the architecture firms up.

## Importing the pack

```bash
gc pack add https://github.com/DataViking-Tech/dv-gascity-utils
```

Then in your city's `pack.toml`:

```toml
[imports.gascity-comms]
  source = ".gc/system/packs/gascity-comms"
```

Per-host one-time setup (symlinks + peer registry):

```bash
ln -sf <CITY>/.gc/system/packs/gascity-comms/assets/scripts/gcx ~/.gc/bin/gcx
ln -sf <CITY>/.gc/system/packs/gascity-comms/assets/scripts/gc-rig-join ~/.gc/bin/gc-rig-join
ln -sf <CITY>/.gc/system/packs/gascity-comms/assets/scripts/gc-fix-refinery-routing ~/.gc/bin/gc-fix-refinery-routing
ln -sf <CITY>/.gc/system/packs/gascity-comms/assets/scripts/gc-fix-merge-strategy ~/.gc/bin/gc-fix-merge-strategy
cp <CITY>/.gc/system/packs/gascity-comms/assets/templates/peers.toml.template ~/.gc/peers.toml
# then edit ~/.gc/peers.toml — fill in url + token_file for each peer
```

Tokens stay outside the pack (per-host, mode 0600 in `~/.gc/tokens/`). `peers.toml` stays per-host. Never commit either.

For the full bootstrap (Caddy gateway, launchd plist, token distribution): see [docs/SETUP-GUIDE.md §5–6](docs/SETUP-GUIDE.md).
