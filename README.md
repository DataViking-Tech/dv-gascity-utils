# dv-gascity-utils

DataViking-Tech utilities and patterns for [Gas City](https://docs.gascityhall.com/) multi-city deployments.

## Contents

### Packs

- **`packs/gascity-comms/`** — cross-city mail tooling. Ships `gcx` (city-aware mail wrapper), the `mail-nudge` order (auto-wakes recipient sessions when their inbox grows), `gc-rig-join` (joins an existing shared-prefix rig from a second city — see `docs/shared-rig-prefix.md`), `gc-audit-alias-mismatch` + `gc-fix-alias-mismatch` (find and rewrite short-form agent aliases to canonical `<rig>/gastown.<role>` across installed system packs; idempotent — see `docs/alias-canonicalization.md`; supersedes the narrower `gc-fix-refinery-routing`, preserved as a deprecation shim), a doctor check (`doctor/check-alias-mismatch`) that surfaces drift, `gc-fix-merge-strategy` (one-shot: makes the polecat done-sequence auto-detect PR-protected branches and set `metadata.merge_strategy=mr` so the refinery opens a PR instead of failing GH013 on direct merge — see `docs/rig-merge-strategy.md`), a peers.toml template, the `collaborative-loop-suggest` mayor-prompt template fragment (see `docs/collaborative-loops.md`), and the `cross-city-prime` template fragment (orients freshly-restarted mayor sessions to the cross-city setup — see `docs/mayor-prompt-prime-recipe.md`). Importable into any Gas City workspace.

### Docs

- **`docs/new-city-bootstrap.md`** — start here when scaffolding a new host. Walks the `gc-city-bootstrap` script + the manual follow-up checklist (city init, peers.toml, token distribution, polecat scaling, verification).
- **`docs/multi-city-shared-dolt.md`** — running multiple cities (each with its own gc supervisor) against a single shared Dolt server, including how rigs partition into separate databases by prefix and how cross-city mail flows between them.
- **`docs/cross-city-comms.md`** — the architecture: per-host Caddy gateway on the Tailscale interface, bearer auth, `peers.toml` registry, the `gcx` wrapper, the in-band `X-Gascity-Origin` header convention for reply routing, and the per-city `mail-nudge` order for autonomous wake-on-arrival.
- **`docs/cross-city-mail-protocol.md`** — payload-level contract for cross-city wisps: why `X-Gascity-Origin` lives in body line 1 (canonical) vs. the HTTP header (forward-compat only, currently dropped by both gateway receive paths), how `gcx mail reply` parses it, and the sender contract for raw-curl callers.
- **`docs/shared-rig-prefix.md`** — open design problem: how do multiple cities work on the same logical rig (same dolt prefix, same beads pool, polecats from any host) instead of each city auto-creating its own duplicate.
- **`docs/alias-canonicalization.md`** — why `<rig>/gastown.<role>` is the canonical agent alias form, how short-form leaks cause silent routing failures, and the `gc-audit-alias-mismatch` / `gc-fix-alias-mismatch` workflow.
- **`docs/rig-merge-strategy.md`** — how the polecat picks `direct` vs `mr` merge mode at submit time, the resolution order (existing metadata > per-rig override file > auto-detect via GitHub branches API > fallback `direct`), and how to install the `gc-fix-merge-strategy` patch helper.
- **`docs/collaborative-loops.md`** — protocol for collaborative `/loop`s between mayors on different cities: the structural autonomy gap that motivates it, the active-thread heuristic, the in-band suggestion shape, the `ScheduleWakeup` cadence table, and three opt-in mechanisms (cleanest first). Pairs with the `collaborative-loop-suggest` template fragment.
- **`docs/agent-scaling.md`** — schema-valid recipe for overriding scaling fields (`min_active_sessions`, `max_active_sessions`, `idle_timeout`, …) on rig-scoped agents (witness/refinery/polecat) via `[[rigs.overrides]]` in `city.toml`. The right knob for keeping one polecat warm per rig.
- **`docs/host-prime-stub.md`** — convention for the per-host `local-prime` template stub that complements the city-agnostic `cross-city-prime` fragment.
- **`docs/mayor-prompt-prime-recipe.md`** — opt-in recipe for hosts to override their mayor prompt template so freshly-restarted mayors come up oriented to the cross-city setup.

## Status

Pre-alpha. Built during initial multi-city setup of `yggdrasil` (HQ on `mani-mac-mini`), `midgard` (`sol-mac-mini`), and `asgard` (external-agent home, also on mani-mac-mini). Patterns and pack contents are evolving as the architecture firms up.

## Bootstrapping a new host

The fast path is `gc-city-bootstrap`:

```bash
curl -fsSL https://raw.githubusercontent.com/DataViking-Tech/dv-gascity-utils/main/packs/gascity-comms/assets/scripts/gc-city-bootstrap \
    -o /tmp/gc-city-bootstrap
chmod +x /tmp/gc-city-bootstrap
/tmp/gc-city-bootstrap --dry-run    # preview
/tmp/gc-city-bootstrap              # apply
```

The script clones dv-gascity-utils, symlinks the helpers into
`~/.gc/bin/`, generates a gateway token, drops a Caddyfile + LaunchAgents,
and runs the `gc-fix-*` helpers once against any installed city packs.
It's idempotent — re-running on a partially-set-up host is safe.

What stays manual (operator decisions the script can't make for you):

- `gc init <city-name>` and `gc rig add` for each project
- Editing `~/.gc/peers.toml` from the template + distributing your
  gateway token to peer hosts via secure channel
- Polecat warm-pool overrides in `city.toml` (per-rig decision; see
  `docs/agent-scaling.md`)

End-to-end recipe with the manual checklist: **`docs/new-city-bootstrap.md`**.

## Importing the pack manually

If you need to apply the gascity-comms pack to a city without running
the bootstrap script:

```bash
git clone https://github.com/DataViking-Tech/dv-gascity-utils ~/dv-gascity-utils
# In your city's pack.toml:
[imports.gascity-comms]
  source = "/absolute/path/to/dv-gascity-utils/packs/gascity-comms"
gc reload
```

Per-host symlinks the bootstrap script handles automatically:

```bash
for h in gcx gc-rig-join gc-audit-alias-mismatch gc-fix-alias-mismatch \
         gc-fix-refinery-routing gc-fix-merge-strategy gc-fix-refinery-pr-body \
         gc-fix-watch gc-warm-rig-pool gc-tune-refinery-loop gc-city-bootstrap; do
    ln -sf "$HOME/dv-gascity-utils/packs/gascity-comms/assets/scripts/$h" "$HOME/.gc/bin/$h"
done
cp ~/dv-gascity-utils/packs/gascity-comms/assets/templates/peers.toml.template ~/.gc/peers.toml
# fill in url + token_file for each peer
```

The `gc-fix-*` helpers are one-shot patchers, not ambient daemons —
symlinking only puts them on `$PATH`. After the symlinks land, run each
once on this host so the per-host gastown system pack picks up the
fixes:

```bash
gc-fix-alias-mismatch ~/<town>     # or just `gc-fix-alias-mismatch` to scan ~/*
gc-fix-merge-strategy ~/<town>
gc-fix-refinery-pr-body ~/<town>
```

All three are idempotent — re-runs report `already fixed`. See
`docs/alias-canonicalization.md` and `docs/rig-merge-strategy.md` for
what each one rewrites and why.

Tokens stay outside the pack (per-host, mode 0600 in `~/.gc/tokens/`). `peers.toml` stays per-host.
