# dv-gascity-utils

DataViking-Tech utilities and patterns for [Gas City](https://docs.gascityhall.com/) multi-city deployments.

## Contents

### Packs

- **`packs/gascity-comms/`** — cross-city mail tooling. Ships `gcx` (city-aware mail wrapper), the `mail-nudge` order (auto-wakes recipient sessions when their inbox grows), `gc-rig-join` (joins an existing shared-prefix rig from a second city — see `docs/shared-rig-prefix.md`), and a peers.toml template. Importable into any Gas City workspace.

### Docs

- **`docs/multi-city-shared-dolt.md`** — running multiple cities (each with its own gc supervisor) against a single shared Dolt server, including how rigs partition into separate databases by prefix and how cross-city mail flows between them.
- **`docs/cross-city-comms.md`** — the architecture: per-host Caddy gateway on the Tailscale interface, bearer auth, `peers.toml` registry, the `gcx` wrapper, the in-band `X-Gascity-Origin` header convention for reply routing, and the per-city `mail-nudge` order for autonomous wake-on-arrival.
- **`docs/shared-rig-prefix.md`** — open design problem: how do multiple cities work on the same logical rig (same dolt prefix, same beads pool, polecats from any host) instead of each city auto-creating its own duplicate.

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
cp ~/dv-gascity-utils/packs/gascity-comms/assets/templates/peers.toml.template ~/.gc/peers.toml
# fill in url + token_file for each peer
```

Tokens stay outside the pack (per-host, mode 0600 in `~/.gc/tokens/`). `peers.toml` stays per-host.
