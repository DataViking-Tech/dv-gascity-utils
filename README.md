# dv-gascity-utils

DataViking-Tech utilities and patterns for [Gas City](https://docs.gascityhall.com/) multi-city deployments.

## Contents

### Packs

- **`packs/gascity-comms/`** — cross-city mail tooling. Ships `gcx` (city-aware mail wrapper), the `mail-nudge` order (auto-wakes recipient sessions when their inbox grows), `gc-rig-join` (joins an existing shared-prefix rig from a second city — see `docs/shared-rig-prefix.md`), `gc-audit-alias-mismatch` + `gc-fix-alias-mismatch` (find and rewrite short-form agent aliases to canonical `<rig>/gastown.<role>` across installed system packs AND patch the refinery patrol formula + prompt to derive a base alias for work-bead claim queries when `min_active_sessions` adds a slot suffix; idempotent — see `docs/alias-canonicalization.md`; supersedes the narrower `gc-fix-refinery-routing`, preserved as a deprecation shim), a doctor check (`doctor/check-alias-mismatch`) that surfaces drift, `gc-fix-merge-strategy` (one-shot: makes the polecat done-sequence auto-detect PR-protected branches and set `metadata.merge_strategy=mr` so the refinery opens a PR instead of failing GH013 on direct merge — see `docs/rig-merge-strategy.md`), a peers.toml template, and the `collaborative-loop-suggest` mayor-prompt template fragment (see `docs/collaborative-loops.md`). Importable into any Gas City workspace.

### Docs

- **`docs/multi-city-shared-dolt.md`** — running multiple cities (each with its own gc supervisor) against a single shared Dolt server, including how rigs partition into separate databases by prefix and how cross-city mail flows between them.
- **`docs/cross-city-comms.md`** — the architecture: per-host Caddy gateway on the Tailscale interface, bearer auth, `peers.toml` registry, the `gcx` wrapper, the in-band `X-Gascity-Origin` header convention for reply routing, and the per-city `mail-nudge` order for autonomous wake-on-arrival.
- **`docs/shared-rig-prefix.md`** — open design problem: how do multiple cities work on the same logical rig (same dolt prefix, same beads pool, polecats from any host) instead of each city auto-creating its own duplicate.
- **`docs/alias-canonicalization.md`** — why `<rig>/gastown.<role>` is the canonical agent alias form, how short-form leaks cause silent routing failures, and the `gc-audit-alias-mismatch` / `gc-fix-alias-mismatch` workflow.
- **`docs/rig-merge-strategy.md`** — how the polecat picks `direct` vs `mr` merge mode at submit time, the resolution order (existing metadata > per-rig override file > auto-detect via GitHub branches API > fallback `direct`), and how to install the `gc-fix-merge-strategy` patch helper.
- **`docs/collaborative-loops.md`** — protocol for collaborative `/loop`s between mayors on different cities: the structural autonomy gap that motivates it, the active-thread heuristic, the in-band suggestion shape, the `ScheduleWakeup` cadence table, and three opt-in mechanisms (cleanest first). Pairs with the `collaborative-loop-suggest` template fragment.
- **`docs/agent-scaling.md`** — schema-valid recipe for overriding scaling fields (`min_active_sessions`, `max_active_sessions`, `idle_timeout`, …) on rig-scoped agents (witness/refinery/polecat) via `[[rigs.overrides]]` in `city.toml`. The right knob for keeping one polecat warm per rig.

## Status

Pre-alpha. Built during initial multi-city setup of `yggdrasil` (HQ on `mani-mac-mini`), `midgard` (`sol-mac-mini`), and `asgard` (external-agent home, also on mani-mac-mini). Patterns and pack contents are evolving as the architecture firms up.

## Importing the pack

Until `gc pack add <git-url>` is wired up here, the bootstrap is manual:

```bash
git clone https://github.com/DataViking-Tech/dv-gascity-utils ~/dv-gascity-utils
# In your city's pack.toml:
[imports.gascity-comms]
  source = "/absolute/path/to/dv-gascity-utils/packs/gascity-comms"
gc reload
```

Then per-host:

```bash
ln -sf ~/dv-gascity-utils/packs/gascity-comms/assets/scripts/gcx ~/.gc/bin/gcx
ln -sf ~/dv-gascity-utils/packs/gascity-comms/assets/scripts/gc-rig-join ~/.gc/bin/gc-rig-join
ln -sf ~/dv-gascity-utils/packs/gascity-comms/assets/scripts/gc-audit-alias-mismatch ~/.gc/bin/gc-audit-alias-mismatch
ln -sf ~/dv-gascity-utils/packs/gascity-comms/assets/scripts/gc-fix-alias-mismatch ~/.gc/bin/gc-fix-alias-mismatch
# gc-fix-refinery-routing is now a deprecation shim that forwards to
# gc-fix-alias-mismatch — keep it symlinked only if you have existing
# scripts or muscle memory that calls it by its old name:
ln -sf ~/dv-gascity-utils/packs/gascity-comms/assets/scripts/gc-fix-refinery-routing ~/.gc/bin/gc-fix-refinery-routing
ln -sf ~/dv-gascity-utils/packs/gascity-comms/assets/scripts/gc-fix-merge-strategy ~/.gc/bin/gc-fix-merge-strategy
cp ~/dv-gascity-utils/packs/gascity-comms/assets/templates/peers.toml.template ~/.gc/peers.toml
# fill in url + token_file for each peer
```

Tokens stay outside the pack (per-host, mode 0600 in `~/.gc/tokens/`). `peers.toml` stays per-host.
