# Bootstrapping a new Gas City

End-to-end recipe for bringing a new host into a multi-city Gas City
deployment. The mechanical steps are wrapped in `gc-city-bootstrap`;
this doc walks the manual decisions around it.

If you're scaffolding a fresh city in a new repo, run the script first,
then come back here for the manual checklist.

## What you need before starting

- macOS or Linux host with `git`, `bash` (3.2+), `openssl`, `caddy`
  (any 2.x), `gh` (GitHub CLI), and `gc` (homebrew-installed Gas City
  binary).
- Tailscale running on this host. The gateway binds the host's
  Tailscale IP for cross-city RPC.
- SSH or other secure channel to peer hosts you want to talk to. Tokens
  must travel out-of-band.
- A name for this city (`gc init <name>` later — pick a stable one;
  it's the city slug other hosts use to address you).

## TL;DR

```bash
# 1. Run the bootstrap script. It clones dv-gascity-utils, symlinks
#    helpers, generates a gateway token, drops Caddyfile + LaunchAgents,
#    and runs the fix-* helpers once against any city packs already
#    installed.
curl -fsSL https://raw.githubusercontent.com/DataViking-Tech/dv-gascity-utils/main/packs/gascity-comms/assets/scripts/gc-city-bootstrap \
    -o /tmp/gc-city-bootstrap
chmod +x /tmp/gc-city-bootstrap
/tmp/gc-city-bootstrap --dry-run    # preview
/tmp/gc-city-bootstrap              # apply

# 2. Initialize the city (or skip if you already have one).
gc init my-new-city

# 3. Edit ~/.gc/peers.toml from the template (manual; see below).

# 4. Distribute ~/.gc/tokens/<this-host>-gateway.token to peer hosts
#    via secure channel.

# 5. Apply polecat scaling overrides in city.toml (manual; depends on
#    rig profile).
```

After step 1 you have a working host with helpers + watcher + gateway
ready to go. Steps 2-5 are operator decisions the script can't make for
you.

## What gc-city-bootstrap does

The script is in `packs/gascity-comms/assets/scripts/gc-city-bootstrap`
and is idempotent — re-running on a partially-configured host is safe.

| Step | Action | Notes |
|------|--------|-------|
| 1 | Clone or fast-forward `~/dv-gascity-utils` | Skipped if already cloned and clean. |
| 2 | Symlink `gcx`, `gc-fix-*`, `gc-rig-join`, etc into `~/.gc/bin/` | Idempotent. |
| 3 | Generate `~/.gc/tokens/<host>-gateway.token` if missing | 32 bytes hex via `openssl rand`. Mode 0600. |
| 4 | Render `~/.gc/gateway/Caddyfile` with this host's Tailscale IP | Auto-detects via `tailscale ip -4`; fallback `--ts-ip`. |
| 5 | Render LaunchAgent plists for fix-watch + gateway | macOS only; Linux uses systemd templates from `pack-template-resilience.md`. |
| 6 | Load both LaunchAgents | `bootout` + `bootstrap`, idempotent. |
| 7 | Run each `gc-fix-*` helper once per discovered town | Skipped on hosts with no city packs yet — re-run after `gc init`. |

What it does NOT do (intentionally — these need human decisions):

- **`gc init <name>`** — depends on what you call the city.
- **`gc rig add <path>`** — depends on which projects you want to host.
- **`peers.toml`** — depends on which other cities you want to reach
  and what their gateway URLs are.
- **Token distribution** — security-sensitive; tokens must move
  out-of-band to peers.
- **Polecat warm-pool config** — depends on rig load profile (see
  `agent-scaling.md` "Cost of warm pools").

## Manual follow-up checklist

### A. Initialize the city (if not yet)

```bash
gc init my-new-city
cd ~/my-new-city
gc rig add /path/to/project1 --include packs/gastown
gc rig add /path/to/project2 --include packs/gastown
```

If you're joining an existing shared-prefix rig, use `gc-rig-join`
instead of `gc rig add` — see `docs/shared-rig-prefix.md`.

After `gc init`, re-run the bootstrap with `--skip-helpers=0` (default)
so the fix-* helpers patch the freshly-installed embedded packs:

```bash
~/.gc/bin/gc-city-bootstrap
```

### B. Edit ~/.gc/peers.toml

Copy the template + fill in peer entries:

```bash
cp ~/dv-gascity-utils/packs/gascity-comms/assets/templates/peers.toml.template ~/.gc/peers.toml
chmod 600 ~/.gc/peers.toml
$EDITOR ~/.gc/peers.toml
```

Each peer entry needs:

```toml
[peers.<peer-city-name>]
url = "http://<peer-tailscale-ip>:8472"
token_file = "/Users/<you>/.gc/tokens/<peer-host>-gateway.token"
```

`token_file` should point at a per-peer token you've placed at that
path. The token authenticates THIS host to the peer's gateway — so the
peer generated it, not you. (Yours, in `~/.gc/tokens/<this-host>-gateway.token`,
goes the OTHER direction: peers store it under that filename to talk
to you.)

### C. Distribute your gateway token to peers

Out-of-band channel of your choice (encrypted Slack DM, signal, an SSH
copy, whatever). Each peer puts your token at:

```
~/.gc/tokens/<this-host>-gateway.token  (mode 0600)
```

…where `<this-host>` matches the city name in their `peers.toml`. They
then add an entry to their own `peers.toml` pointing at your gateway URL.

Verify the round-trip:

```bash
# From this host, addressing a peer:
gcx mail send <peer-city>:mayor -s "ping" -m "first contact from $(hostname -s)"

# From the peer, addressing you (after they've set up their side):
gcx mail send <this-city>:mayor -s "pong" -m "received"

# Both sides should see the wisp arrive in their inbox via:
gc mail inbox
```

If the send fails with `403 Unauthorized`, the token is wrong. If it
fails with `connection refused`, the gateway isn't running on the
target. If it succeeds but the recipient doesn't see the wisp, check
`~/.gc/gateway/access.log` on the receiving side.

### D. Polecat scaling overrides

The default polecat `min_active_sessions` is `0` (cold pool). If you
want a warm polecat per rig — faster first-claim latency at the cost
of one idle session per rig — add `[[rigs.overrides]]` blocks per
`docs/agent-scaling.md`.

Heuristic: leave it cold (the default) unless you've observed
first-claim latency pain on a specific rig. Warm-pool churn is real
(see "Cost of warm pools" section in that doc).

### E. Verify the host is healthy

```bash
# Helpers are on PATH and runnable
ls ~/.gc/bin/gc-* | head -10

# Watcher is alive and running v2
launchctl list | grep dv-gascity.fix-watch
tail -3 ~/Library/Logs/gc-fix-watch.log
# expect: a recent 'baseline:' line

# Gateway is listening on Tailscale interface
launchctl list | grep dev.gascity.gateway
tail -3 ~/.gc/gateway/launchd.out.log
# expect: 'serving initial configuration'

# Pack-tree pool fields are canonical
grep '^pool ' ~/<city>/.gc/system/packs/dolt/orders/mol-dog-*.toml
# expect: pool = "gastown.dog"

# Audit reports clean
~/.gc/bin/gc-audit-alias-mismatch ~/<city>
# expect: 'no short-form findings'
```

## Known caveats this host will hit

The new host will see the same gc binary bugs documented in
`docs/known-binary-bugs.md`. Specifically:

- **Pack-template wipe on supervisor startup**: `gc-fix-watch` is
  installed by the bootstrap, so this is auto-handled in steady state.
  If the watcher crashes, KeepAlive restarts it (PR #8 set-e fix).
- **dolt/orders/* dog orders permanently stuck after bd-error**: not
  preventable host-side. Symptoms appear days into operation. See the
  "Supervisor restart — caveats and workaround" section in
  `docs/diagnostic-runbook.md` for the manual workaround when it hits.
- **`gc supervisor stop` may ignore SIGTERM**: same runbook section
  has the SIGKILL escalation.

Read `known-binary-bugs.md` end-to-end before going into production.
Every entry has a workaround and a tracker.

## Going further

- `docs/cross-city-comms.md` — gateway architecture, peers.toml schema,
  full setup detail (this doc summarizes; that one is canonical).
- `docs/cross-city-mail-protocol.md` — wire format for cross-city wisps;
  body-line-1 origin convention.
- `docs/multi-city-shared-dolt.md` — running multiple cities against a
  shared Dolt server.
- `docs/agent-scaling.md` — `[[rigs.overrides]]` for per-rig agent
  scaling tweaks.
- `docs/diagnostic-runbook.md` — recovery recipes when things go wrong.
- `docs/pack-template-resilience.md` — gc-fix-watch design + Linux
  systemd unit template.

## When the bootstrap script can't help

- **Air-gapped host**: clone dv-gascity-utils manually from a tarball,
  then run `gc-city-bootstrap` with `$DV_REPO_PATH` already populated.
- **Custom Tailscale topology** (multiple interfaces, etc): pass
  `--ts-ip` explicitly.
- **Non-default homebrew location**: the gateway plist hardcodes
  `/opt/homebrew/bin/caddy`. Edit before loading if Caddy lives
  elsewhere.
- **Linux**: the script ships LaunchAgent plists (macOS only). Linux
  hosts use the systemd unit at
  `packs/gascity-comms/assets/systemd/gc-fix-watch.service.template`
  and a similar systemd unit for the gateway (write your own —
  template not yet shipped here).
