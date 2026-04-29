# Gas City Setup Guide

> **Audience:** an operator (human or coding agent) handed a fresh machine and this repo, who needs to scaffold a working Gas City deployment from scratch. Linear order. Every step has a checkpoint to verify before moving on.

This guide walks you through:

1. Single-city bootstrap with `gc init`
2. Adopting the `gastown` pack (city-scoped agents)
3. Adding gastown to the HQ rig (rig-scoped agents)
4. Standing up a second co-located city against shared dolt
5. Caddy gateway + token plumbing for cross-host comms
6. `peers.toml` + `gcx` + the `X-Gascity-Origin` reply convention
7. Adding a project rig (`gc rig add`)
8. Joining a shared rig from a second city
9. Per-rig merge strategy (direct vs. mr)
10. Where to look when something breaks

Throughout: `<CITY>` is the absolute path to a city directory (e.g. `/Users/mani/yggdrasil`). `<HOST>` is a host's Tailscale IP (e.g. `100.121.222.11`).

## Prerequisites

- macOS (the live deployments are on mac mini hardware; the patterns are POSIX-ish but launchd-specific paths show up)
- Tailscale installed and authenticated (every host needs to be on the tailnet)
- `gc` and `bd` binaries on `PATH` (1.0.0 / 1.0.3 are the live versions)
- `caddy` (any 2.x) — `brew install caddy`
- `openssl` for token generation

## 1. Single-city bootstrap

A "city" is a workspace root holding the gc supervisor, controller, runtime tree, and one or more rigs.

```bash
gc init /path/to/<city>          # e.g. /Users/mani/yggdrasil
cd /path/to/<city>
```

`gc init` creates:

- `<CITY>/.gc/` — runtime tree (sockets, logs, runtime/)
- `<CITY>/.beads/` — local dolt data dir + config.yaml (embedded mode by default)
- `<CITY>/city.toml` — top-level workspace declaration
- `<CITY>/pack.toml` — pack imports
- A randomly-hashed dolt port (from the city path) for the embedded server

### bd init issue_prefix gotcha

In embedded mode `bd init` reliably seeds the `issue_prefix` config row. **In external (shared-dolt) mode it sometimes does not** — and `bd` cannot mint new bead IDs without it. After every fresh prefix on a shared server, hand-seed:

```bash
gc --city <CITY> dolt sql -q "USE \`<prefix>\`; \
  INSERT INTO config VALUES('issue_prefix','<prefix>'); \
  CALL DOLT_COMMIT('-Am','seed issue_prefix');"
```

Reserved-word prefixes (`as`, `is`, `or`, `to`, `in`, `on`) need backticks in raw SQL anywhere they appear. `gc` and `bd` quote correctly internally; only ad-hoc SQL needs the discipline.

### You should now have

```bash
gc status                         # supervisor running, no rigs yet
bd list                           # 0 issues, no error
gc dolt status                    # listening on the city's hashed port (embedded mode)
```

## 2. Adopting the gastown pack

`gastown` ships two scopes of agents:

- **City-scoped:** `mayor`, `deacon`, `boot`, `dog`
- **Rig-scoped:** `witness`, `refinery`, `polecat`

Each scope is wired separately.

### City-scoped — workspace `pack.toml`

```toml
[imports]
  [imports.gastown]
    source = ".gc/system/packs/gastown"
```

If the workspace already had a local `[[agent]] name = "mayor"` block, remove it. If `<CITY>/agents/mayor/` exists as an auto-discovered dir, move it aside (e.g. `mv agents/mayor .bak/mayor.local/`). Otherwise the local mayor shadows the pack's and validation errors.

### Pack-discovery gotcha (empty dirs required)

`gascity-comms` (and any pack with only `orders/`) won't have its orders scanned by the supervisor unless `agents/` and `formulas/` directories exist in the pack root — even if empty. Symptom: orders never tick. Fix:

```bash
mkdir -p <CITY>/.gc/system/packs/<your-pack>/agents
mkdir -p <CITY>/.gc/system/packs/<your-pack>/formulas
gc reload
```

### You should now have

```bash
gc status                         # mayor/deacon/dog visible (city-scoped)
gc reload                         # no validation errors
```

## 3. Adding gastown to the HQ rig

The HQ rig is the rig that matches the workspace name. Rig-scoped agents (witness, refinery, polecat) require an explicit `[[rigs]]` block in `city.toml`:

```toml
[[rigs]]
name = "<workspace-name>"

[rigs.imports.gastown]
source = ".gc/system/packs/gastown"
```

### Doctor false-positive

`gc doctor` will flag `rig "<name>": prefix "<prefix>" collides with HQ`. **Ignore this.** Runtime treats both as the same rig and the agents expand correctly. Tried-and-rejected workarounds (none work):

- Omitting the `[[rigs]]` block → loses rig-scoped agents
- Adding `hq = true` → `unknown field "rigs.hq"` warning
- Using `[defaults.rig.imports.gastown]` in `pack.toml` → only applies to non-HQ rigs

Keep the `[[rigs]]` block, ignore the warning.

### You should now have

```bash
gc status   # shows <rig>/gastown.witness, <rig>/gastown.refinery,
            #       <rig>/gastown.polecat (5 polecat slots:
            #       furiosa, nux, slit, rictus, capable)
```

The polecat slots will say `reserved-unmaterialized (on_demand)` until work shows up. That's normal.

## 4. Shared dolt with a second co-located city

Two cities on the same machine can share one `dolt sql-server` process. One is *canonical* (owns the data dir, runs the server); the rest are *external* (point at the canonical endpoint over loopback).

This was the asgard story: `asgard` lives on the same mac mini as `yggdrasil` and now writes into yggdrasil's dolt at `127.0.0.1:16022`.

### 4a. Confirm the canonical server is up

```bash
gc --city /Users/mani/yggdrasil dolt status
gc --city /Users/mani/yggdrasil dolt start    # if not running
```

The canonical port (`16022` for yggdrasil) is hashed from the city path — stable per city, not predictable. Read it from `<canonical>/.gc/runtime/packs/dolt/dolt-config.yaml`.

### 4b. Point the external city at the shared endpoint

```bash
gc beads city use-external \
  --city /Users/mani/asgard \
  --host 127.0.0.1 \
  --port 16022 \
  --user root \
  --adopt-unverified
```

This rewrites `<asgard>/.beads/config.yaml`:

- Adds `dolt.host`, `dolt.port`, `dolt.user`
- Sets `dolt.auto-start: false`
- Sets `gc.endpoint_origin: city_canonical`
- Sets `gc.endpoint_status: unverified` (because of `--adopt-unverified`)

`--dry-run` shows the planned rewrites without applying.

### 4c. Create the database on the shared server

`use-external` does not create the DB. Backticks if reserved word:

```bash
gc --city /Users/mani/yggdrasil dolt sql -q "CREATE DATABASE \`as\`"
```

### 4d. Hand-seed `issue_prefix` (the gotcha from §1)

```bash
gc --city /Users/mani/yggdrasil dolt sql -q "USE \`as\`; \
  INSERT INTO config VALUES('issue_prefix','as'); \
  CALL DOLT_COMMIT('-Am','seed issue_prefix');"
```

### 4e. Verify

```bash
cd /Users/mani/asgard
gc bd list                # should hit the shared server (no error)
gc dolt list              # should now include `as` from any city
```

### Cross-host sharing is not supported

The dolt listener defaults to `0.0.0.0` but the gc tooling assumes loopback when a city is external. Cities on different machines each run their own server. Cross-host coordination flows through the mail gateway (§5–6), not the SQL server.

For full detail: `docs/multi-city-shared-dolt.md`.

## 5. Caddy gateway (per host, one-time)

Cross-city mail goes over the Tailnet via a per-host Caddy gateway that bears-auths and reverse-proxies to the local supervisor on `:8372`. The supervisor's bind is hardcoded — Caddy is the only way to expose it on Tailscale.

### 5a. Generate the host's gateway token

```bash
mkdir -p ~/.gc/tokens
openssl rand -hex 32 > ~/.gc/tokens/<this-host>-gateway.token
chmod 600 ~/.gc/tokens/<this-host>-gateway.token
```

The token is **per-host, not per-city** — one host's gateway serves every city on that host. The filename convention says `<this-host>-gateway.token`; you are free to choose any name.

### 5b. Drop in the Caddyfile

```bash
mkdir -p ~/.gc/gateway
cat > ~/.gc/gateway/Caddyfile <<EOF
{
    auto_https off
    admin off
    log {
        output file $HOME/.gc/gateway/access.log
        format console
    }
}

http://<TAILSCALE_IP>:8472 {
    bind <TAILSCALE_IP>
    @authorized header Authorization "Bearer {env.GC_GATEWAY_TOKEN}"

    handle @authorized {
        reverse_proxy 127.0.0.1:8372 {
            header_up X-GC-Request 1
            header_up -Authorization
        }
    }

    handle {
        respond "unauthorized" 401
    }
}
EOF
```

Substitute `<TAILSCALE_IP>` with this host's Tailscale IP (`tailscale ip -4`).

### 5c. Launchd plist (so the gateway survives reboots)

```bash
cat > ~/Library/LaunchAgents/dev.gascity.gateway.plist <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>            <string>dev.gascity.gateway</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/zsh</string>
        <string>-c</string>
        <string>export GC_GATEWAY_TOKEN="\$(cat $HOME/.gc/tokens/<this-host>-gateway.token)" &amp;&amp; exec /opt/homebrew/bin/caddy run --config $HOME/.gc/gateway/Caddyfile</string>
    </array>
    <key>RunAtLoad</key>        <true/>
    <key>KeepAlive</key>        <true/>
    <key>StandardOutPath</key>  <string>$HOME/.gc/gateway/launchd.out.log</string>
    <key>StandardErrorPath</key><string>$HOME/.gc/gateway/launchd.err.log</string>
</dict>
</plist>
EOF
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/dev.gascity.gateway.plist
```

### 5d. Distribute tokens out-of-band

Every host that should be reachable from this host needs *its* token under `~/.gc/tokens/<peer-host>-gateway.token` on this host. SCP it over Tailscale:

```bash
# on host A, copy host B's token to host A so A can call B
scp <userB>@<host-B-tailscale-ip>:~/.gc/tokens/<host-B>-gateway.token \
    ~/.gc/tokens/<host-B>-gateway.token
chmod 600 ~/.gc/tokens/<host-B>-gateway.token
```

Manual `rsync`/`scp` requires SSHd running (often disabled by default on macOS). Base64-via-mail works but doesn't scale. There is no first-class distribution today.

### You should now have

```bash
curl -m 5 -H "Authorization: Bearer $(cat ~/.gc/tokens/<this-host>-gateway.token)" \
     http://<TAILSCALE_IP>:8472/v0/cities    # from another host
# → 200 with city list JSON
```

If that 401s: token mismatch. If it times out: Caddy isn't bound to the Tailscale IP, or Tailscale is blocking the port — `lsof -i :8472` to confirm Caddy is listening on the right interface.

## 6. peers.toml + gcx + X-Gascity-Origin

Per host: register every other host's gateway in `~/.gc/peers.toml`, symlink `gcx` onto `PATH`, and you can address sessions in remote cities as `<city>:<alias>`.

### 6a. Symlink gcx

```bash
ln -sf <CITY>/.gc/system/packs/gascity-comms/assets/scripts/gcx ~/.gc/bin/gcx
```

If you cloned `dv-gascity-utils` separately:

```bash
ln -sf ~/dv-gascity-utils/packs/gascity-comms/assets/scripts/gcx ~/.gc/bin/gcx
```

### 6b. Initialize the peer registry

```bash
cp <CITY>/.gc/system/packs/gascity-comms/assets/templates/peers.toml.template \
   ~/.gc/peers.toml
```

Then edit `~/.gc/peers.toml`:

```toml
[peers.midgard]
url = "http://100.124.163.125:8472"
token_file = "/Users/<you>/.gc/tokens/midgard-gateway.token"

[peers.yggdrasil]
url = "http://100.121.222.11:8472"
token_file = "/Users/<you>/.gc/tokens/yggdrasil-gateway.token"
```

Tokens live outside the pack (per-host). `peers.toml` lives outside the pack (per-host). Never commit these.

### 6c. The X-Gascity-Origin convention

The supervisor's mail API rejects extra body properties (`metadata` returns 422), so `gcx` smuggles the sender identity as an in-band header at the top of the message body:

```
X-Gascity-Origin: yggdrasil:wesley

are you up?
```

`gcx mail read` and `gcx mail inbox` strip + re-surface it as a `From:` field. `gcx mail reply` parses it to know which city to POST the reply to. Plain `gc mail read` shows the header inline (cosmetic only).

### 6d. The mail-nudge order

Cooldown-triggered every 20 s on each city's controller. Scans active named sessions in the local city, parses `gc mail count <alias>`, and nudges any whose unread count grew since the previous tick. State per session: `<CITY>/.gc/runtime/mail-nudge/<alias>.last_unread`.

This is what makes the recipient agent *autonomously* wake on incoming mail. It runs locally on the recipient host — cross-host nudge from the sender side is not supported (the nudge primitive is on the controller's local Unix socket only).

### 6e. The interactive-mayor autonomy gap (read this BEFORE deploying)

`mail-nudge` works perfectly for **agent sessions** (deacons, witnesses, polecats) that run in a work-loop. Each nudge resumes the loop and causes useful action.

For **interactive Claude Code sessions** like the mayors, there's a structural race:

- `mail-nudge` order tick (every 20 s): if `unread > prev_seen` → nudge.
- `UserPromptSubmit` hook (every user turn): surfaces unread mail in `<system-reminder>` and **marks read**.

If the user types a prompt before the next order tick, the unread count is back to 0 by the time the order looks. The order sees no growth and no nudge fires. Net effect: an interactive mayor will *see* mail on their next turn regardless, but won't be *autonomously* woken if they're idle and the user hasn't pressed Enter recently.

The proper fix is a supervisor-level "wake into a new turn" primitive that mounts the recipient agent for a turn instead of just queuing nudge text against an existing one. Out of scope for this pack.

Mitigation: when a cross-city thread heats up, the human kicks off `/loop` once with adaptive `ScheduleWakeup` (60 s ↔ 15 min depending on activity). One gesture, then autonomous until the thread closes. Tracked under `dgu-yxb8`.

### You should now have

```bash
gcx cities                        # all peers reachable, status: running
gcx mail send <peer>:<self> \
    -s test -m loopback           # send to yourself via the gateway
gcx mail inbox @<peer> <self>     # see it land
```

For full detail: `docs/cross-city-comms.md`.

## 7. Adding a project rig

A "rig" is an isolated git project with its own bead pool, polecat workers, refinery merge queue, and witness monitor.

```bash
gc rig add /path/to/<project> --name <project-name>
```

Default behavior: derives prefix from `<project-name>`, creates database `<prefix>` on the city's dolt server, registers `[[rig]]` in `<CITY>/.gc/site.toml`, runs `bd init`.

### .beads/ placeholder gotcha

Some repos (anything cloned from a template that included `.beads/` content) ship with a non-empty `.beads/` directory. `gc rig add` refuses if `.beads/` exists:

```
gc rig add: <path>/.beads already exists; use --adopt …
```

Two options:

1. **Adopt** if the existing `.beads/` is the canonical state (you want to join, not initialize):

   ```bash
   gc rig add /path/to/project --name <name> --prefix <p> --adopt
   ```

   Requires valid `.beads/metadata.json` and `.beads/config.yaml` with `issue_prefix` already in place.

2. **Move and re-init** if the `.beads/` is template cruft:

   ```bash
   mv /path/to/project/.beads /path/to/project/.beads.template-bak
   gc rig add /path/to/project --name <name>
   ```

### You should now have

```bash
gc rig list                       # new rig appears with prefix
gc rig status <name>              # endpoint resolves; agents can spawn
bd list                           # from inside the rig dir, no error
```

## 8. Joining a shared rig from a second city

The "second city wants to work on the same logical project as the first city" pattern. Same git repo, same bead pool, polecats from any host.

This is a substantial design — full detail in `docs/shared-rig-prefix.md`. The short version:

1. **Pre-stage `.beads/` stub on the joiner** with `issue_prefix` set but `project_id` omitted.
2. **Pull the canonical project_id from the shared dolt** via `gc dolt-state ensure-project-id` (source: database).
3. **Register the rig** with `gc rig add --adopt --prefix <p>`.

The `gc-rig-join` helper (in `packs/gascity-comms/assets/scripts/`) wraps the recipe with pre-flight checks (collision, reachability, missing-DB, bad-prefix). Symlink:

```bash
ln -sf <CITY>/.gc/system/packs/gascity-comms/assets/scripts/gc-rig-join \
       ~/.gc/bin/gc-rig-join
```

Then on the joiner:

```bash
gc-rig-join /local/path \
    --prefix <p> --name <project> \
    --host <shared-dolt-host> --port 16022
```

Both `ensure-project-id` and the hand-pinned 4-file recipe produce identical state. See `docs/shared-rig-prefix.md` for the choice between them.

## 9. Per-rig merge strategy

Polecats default to `merge_strategy=direct`: refinery merges the polecat's branch directly into `main`. **PR-protected rigs (e.g. branch protection on `main`) reject this** with `GH013`, and the refinery escalates to the mayor.

The fix is shipped as the `gc-fix-merge-strategy` helper in this pack (`dgu-26ptn`). It patches the per-host gastown system pack so the polecat's submit-and-exit step auto-resolves `merge_strategy` in this order:

1. `metadata.merge_strategy` already set on the work bead (caller intent)
2. Per-rig override file `<rig-root>/.gc-merge-strategy` (single-line `mr`/`direct`)
3. Auto-detect via `gh api repos/<r>/branches/<t> --jq '.protected'`
4. Fallback `direct`

Install once per host (idempotent):

```bash
ln -sf <CITY>/.gc/system/packs/gascity-comms/assets/scripts/gc-fix-merge-strategy \
       ~/.gc/bin/gc-fix-merge-strategy
gc-fix-merge-strategy        # patches every <town>/.gc/system/packs/gastown it finds
```

Once installed, polecat work in protected rigs (e.g. `traitprint`, `traitprint-cloud`) auto-routes through `mr` and the refinery opens the PR. The companion `pr-ci-watch` order (`dgu-yrnmv`, also in this pack) closes the loop on the PR side: it auto-reslings on CI failure and stops tracking on merge.

Full detail: `docs/rig-merge-strategy.md` (resolution order, override file usage) and `docs/diagnostic-runbook.md` §9 (PR-autonomy stuck states).

### You should now have

```bash
gc-fix-merge-strategy --dry-run      # reports "already fixed" for every gastown pack on host
gc config show | grep -A 2 pr-ci-watch  # cooldown order loaded
```

## 10. Diagnostic primitives + recovery recipes

For each common failure mode (controller wedge, supervisor wedge, mail-nudge race, missing `issue_prefix`, alias-mismatch, etc.), see:

- `docs/diagnostic-runbook.md` — symptom → diagnostic command → recovery.
- `docs/lessons-learned.md` — patterns + gotchas distilled from the live build.

The two together cover everything we hit during the multi-city scaffold.

## What you should have at the end

A working Gas City deployment with:

- One canonical city per host, running its own dolt server (or sharing one canonical host's)
- `gastown` pack adopted at workspace and HQ-rig scope
- A Caddy gateway on each host's Tailscale interface
- `peers.toml` registering every other host this host can reach
- `gcx` on `PATH`, `mail-nudge` order ticking
- One or more project rigs with polecat slots, refinery, and witness running
- Cross-city mail working: `gcx mail send <peer>:<alias> -s ... -m ...` lands, recipient is nudged, reply round-trips

If any of those don't work, walk back up the relevant section's checkpoint and confirm.
