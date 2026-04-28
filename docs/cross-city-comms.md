# Cross-City Communications

> **Status:** implemented and running between yggdrasil ↔ asgard ↔ midgard. The plumbing described here ships in `packs/gascity-comms/`. Per-host config (Caddyfile, tokens, `peers.toml`, `~/.gc/bin/gcx` symlink, launchd plist) lives outside the pack.

## The problem

A single Gas City supervisor binds its TCP API to `127.0.0.1:8372` and that bind address is hardcoded in the gc binary — there is no config knob to expose it on Tailscale. The supervisor itself only does CSRF checks on mutations; it has no notion of authentication. So the natural option ("just point another host at port 8372") is doubly unworkable: the port isn't reachable, and even if it were there's no way to authenticate the caller.

Mail wisps live in the *sender's* local Dolt database, partitioned by rig prefix (`yg` for yggdrasil, `mg` for midgard, `as` for asgard). That means each city's `wisps` table is naturally isolated — there is no built-in cross-city delivery, and no shared queue you could poll from elsewhere. `gc mail send mayor` is also ambiguous when both yggdrasil and midgard have a "mayor": each city's command sees only its own.

Finally, `gc session nudge` — the primitive that wakes a sleeping named session — is implemented over the controller's local Unix socket, not the supervisor's TCP API. So even with HTTP plumbing in place, the sender side can't tell a remote session "you have new mail." Wakeups have to originate on the recipient's host.

## The architecture

Five pieces, all per-host except where noted. Components on this host as of 2026-04-28:

1. **Caddy gateway.** Binds the host's Tailscale IP on port `8472`, validates `Authorization: Bearer <token>` against `$GC_GATEWAY_TOKEN`, strips the header, injects `X-GC-Request: 1`, and reverse-proxies to `127.0.0.1:8372`. Config: `~/.gc/gateway/Caddyfile`. Launchd-managed via `~/Library/LaunchAgents/dev.gascity.gateway.plist` (the plist exports the token env var from `~/.gc/tokens/<peer>-gateway.token` before exec'ing `caddy run`). One gateway per host serves all cities running on that host (yggdrasil + asgard share `100.121.222.11:8472`; midgard runs its own at `100.124.163.125:8472`).
2. **Per-host token store.** `~/.gc/tokens/<peer>-gateway.token`, mode 0600. One token per host's gateway. The token authenticates a caller to the host's supervisor — which serves *all* cities on that host — so despite the file naming convention it is per-host, not per-city.
3. **Per-host peer registry.** `~/.gc/peers.toml`. Maps each city name the host wants to reach to a `url` and `token_file`. Optional `local_path` is informational (local cities can be listed too — `gcx` will exercise the same gateway code path). Tokens stay outside the pack; `peers.toml` stays outside the pack (per-host).
4. **`gcx` wrapper.** Python 3.9-compatible CLI at `packs/gascity-comms/assets/scripts/gcx`. Routes `<city>:<alias>` sends, `@<city>` browses, and `<city>:<wisp-id>` reads through each peer's gateway. Falls through to plain `gc` for non-cross-city calls. Stamps an in-band `X-Gascity-Origin: <city>:<alias>` header at the top of outgoing bodies so replies can route back via the origin (`gcx mail reply <id>` parses the header and POSTs back to the source city).
5. **`mail-nudge` order.** Cooldown-triggered every 20 s on each city's controller (`packs/gascity-comms/orders/mail-nudge.toml` + `assets/scripts/mail-nudge.sh`). Scans active named sessions in this city, parses `gc mail count <alias>`, and nudges any whose unread count grew since the previous tick. Per-session state in `$GC_CITY_RUNTIME_DIR/mail-nudge/<alias>.last_unread`. Uses `--delivery wait-idle` so sessions in mid-turn aren't interrupted.

### Request flow

```
[sender on host A]
        │
        │  gcx mail send midgard:mayor -s S -m M
        ▼
[gcx wrapper]
        │  • parse target → (city=midgard, alias=mayor)
        │  • read ~/.gc/peers.toml → peers.midgard.{url, token_file}
        │  • prepend "X-Gascity-Origin: <home>:<alias>\n\n" to body
        │  • POST <peer.url>/v0/city/midgard/mail
        │       Authorization: Bearer <token>
        │       Content-Type:  application/json
        │       X-GC-Request:  1
        ▼
[Tailnet  ──►  Caddy on host B :8472, bound to Tailscale IP]
        │  • match @authorized (Bearer == $GC_GATEWAY_TOKEN)
        │  • strip Authorization, inject X-GC-Request: 1
        │  • reverse_proxy 127.0.0.1:8372
        ▼
[gc supervisor on host B :8372]
        │  • insert wisp into mg.wisps (body includes the origin header)
        ▼
[mail-nudge order on host B (every 20s)]
        │  • for each active named session in midgard:
        │       unread = parse `gc mail count <alias>`
        │       if unread > <state_dir>/<alias>.last_unread:
        │           gc session nudge <alias> "📬 inbox grew by N…" \
        │                          --delivery wait-idle
        ▼
[recipient session on host B resumes]
        │  • UserPromptSubmit hook surfaces unread mail, marks them read
        │  • `gcx mail read midgard:<id>` → From: yggdrasil:<sender>
```

The reply path runs the diagram in reverse: `gcx mail reply <wisp-id>` GETs the wisp from the source city's gateway, parses the `X-Gascity-Origin` header, looks up the origin city in `peers.toml`, and POSTs the reply back — stamping its own reverse origin header so further replies continue to round-trip.

## How addressing works

`gcx` recognizes three address forms; everything else falls through to plain `gc`:

| Form | Meaning | Routes via |
|------|---------|------------|
| `<city>:<alias>` | Point-to-point send / read in `<city>` | `peers.<city>` gateway |
| `@<city>` | City-scoped browse (whole inbox) | `peers.<city>` gateway |
| `<alias>` (no colon, no `@`) | Local | `gc` directly |

```bash
gcx mail send midgard:mayor -s "ping" -m "..."   # POST to midgard's gateway
gcx mail send mayor          -s "ping" -m "..."  # local: exec gc
gcx mail inbox @midgard                          # GET midgard's inbox
gcx mail inbox @midgard mayor                    # GET filtered by assignee
gcx mail read midgard:mg-abc123                  # GET single wisp
gcx mail reply mg-abc123 -m "pong"               # parse origin header → POST reverse
gcx cities                                       # list peers + reachability
```

Reply routing keys on the wisp-id prefix (`mg-…` → midgard) — `gcx` matches against peer names that start with the same letters (`midgard` starts with `mg`, `asgard` with `as`, `yggdrasil` with `yg`). If the wisp body has an `X-Gascity-Origin` header, that takes precedence over the prefix match for choosing the reply target. If no origin and no peer match, `gcx` falls through to `gc mail reply` (which currently errors with "no sender to reply to" — see Limitations).

## Per-host bootstrap

One-time, on every host that needs to participate:

```bash
# 1. Install Caddy (any 2.x)
brew install caddy

# 2. Generate a per-host gateway token (32+ random bytes, hex)
mkdir -p ~/.gc/tokens
openssl rand -hex 32 > ~/.gc/tokens/<this-host>-gateway.token
chmod 600 ~/.gc/tokens/<this-host>-gateway.token

# 3. Drop in the gateway Caddyfile (substitute this host's Tailscale IP)
mkdir -p ~/.gc/gateway
cat > ~/.gc/gateway/Caddyfile <<'EOF'
{
    auto_https off
    admin off
    log {
        output file /Users/<you>/.gc/gateway/access.log
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

# 4. Launchd plist so the gateway survives reboots
cat > ~/Library/LaunchAgents/dev.gascity.gateway.plist <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>            <string>dev.gascity.gateway</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/zsh</string>
        <string>-c</string>
        <string>export GC_GATEWAY_TOKEN="$(cat /Users/<you>/.gc/tokens/<this-host>-gateway.token)" &amp;&amp; exec /opt/homebrew/bin/caddy run --config /Users/<you>/.gc/gateway/Caddyfile</string>
    </array>
    <key>RunAtLoad</key>        <true/>
    <key>KeepAlive</key>        <true/>
    <key>StandardOutPath</key>  <string>/Users/<you>/.gc/gateway/launchd.out.log</string>
    <key>StandardErrorPath</key><string>/Users/<you>/.gc/gateway/launchd.err.log</string>
</dict>
</plist>
EOF
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/dev.gascity.gateway.plist

# 5. Install the pack's tooling on PATH
ln -sf ~/dv-gascity-utils/packs/gascity-comms/assets/scripts/gcx ~/.gc/bin/gcx

# 6. Initialize the peer registry
cp ~/dv-gascity-utils/packs/gascity-comms/assets/templates/peers.toml.template \
   ~/.gc/peers.toml
# then edit: add [peers.<city>] blocks for every city this host should reach,
# pointing token_file at the matching ~/.gc/tokens/<peer>-gateway.token

# 7. Distribute tokens. Each host's gateway token must be readable by
#    every other host that will call into it (copy the file over a
#    secure channel and place it under ~/.gc/tokens/<peer>-gateway.token
#    on the calling host, mode 0600).

# 8. Enable the mail-nudge order in your city's pack imports
#    (packs/gascity-comms is imported via your city's pack.toml; the
#    order ships with the pack and runs once the pack is loaded).
```

Verify:

```bash
gcx cities                              # all peers reachable, status: running
gcx mail send <some-peer>:<self>  \
    -s test -m "loopback"               # send a wisp to yourself via the gateway
gcx mail inbox @<some-peer> <self>      # see it land
```

## Worked example: yggdrasil → midgard

Concrete trace of a single mail from `wesley` on yggdrasil to `mayor` on midgard, with state changes called out at each hop. Hosts and addresses are real values from the current setup.

**1. Sender invokes gcx.**

```
$ gcx mail send midgard:mayor -s "ping" -m "are you up?"
```

The session has `GC_CITY_NAME=yggdrasil`, `GC_ALIAS=wesley`. `gcx` parses `midgard:mayor` into `(city=midgard, alias=mayor)`, reads `~/.gc/peers.toml`, and finds:

```toml
[peers.midgard]
url = "http://100.124.163.125:8472"
token_file = "/Users/mani/.gc/tokens/midgard-gateway.token"
```

**2. gcx stamps origin and POSTs.**

Because home (`yggdrasil`) ≠ target (`midgard`), gcx prepends an `X-Gascity-Origin` line:

```http
POST /v0/city/midgard/mail HTTP/1.1
Host: 100.124.163.125:8472
Authorization: Bearer <contents of midgard-gateway.token>
Content-Type: application/json
X-GC-Request: 1

{
  "to": "mayor",
  "subject": "ping",
  "body": "X-Gascity-Origin: yggdrasil:wesley\n\nare you up?"
}
```

**3. Caddy on midgard's host accepts.**

The request hits `100.124.163.125:8472`. Caddy matches `@authorized` (the Bearer token equals midgard's `$GC_GATEWAY_TOKEN`), strips `Authorization`, injects `X-GC-Request: 1`, and reverse-proxies to `127.0.0.1:8372`. Unauthenticated calls get `401 unauthorized`.

**4. midgard's supervisor inserts the wisp.**

The supervisor accepts the POST, mints a wisp id (e.g. `mg-7q2k`), and inserts a row into `mg.wisps` with `assignee=mayor` and the body verbatim — including the origin header. Returns:

```json
{ "id": "mg-7q2k", "ok": true }
```

`gcx` prints `Sent mg-7q2k to midgard:mayor`.

**5. mail-nudge wakes the mayor.**

Within 20 s, the `mail-nudge` order on midgard's controller ticks:

```bash
# on midgard's host
gc mail count mayor                  # → "5 total, 1 unread for mayor"
# previous tick wrote 0 to ~/.../mail-nudge/mayor.last_unread
# 1 > 0  →  nudge fires
gc session nudge mayor \
    "📬 inbox grew by 1 (now 1 unread). run 'gc mail inbox' to see them." \
    --delivery wait-idle
# update state file → 1
```

`--delivery wait-idle` queues the nudge until the recipient session is at a safe boundary (between turns), so it doesn't interrupt mid-turn work.

**6. mayor reads the wisp.**

The mayor session resumes. Its UserPromptSubmit hook surfaces unread mail in a `<system-reminder>` and marks the wisp as read. Reading via gcx surfaces the origin cleanly:

```
$ gcx mail read midgard:mg-7q2k
ID:       mg-7q2k
From:     yggdrasil:wesley
To:       midgard:mayor
Subject:  ping
Sent:     2026-04-28T00:42:58Z
Body:
are you up?
```

(Plain `gc mail read mg-7q2k` shows the same wisp, but the `X-Gascity-Origin: yggdrasil:wesley` line appears as the first line of the body rather than as a `From:` header — cosmetic only.)

**7. Mayor replies.**

```
$ gcx mail reply mg-7q2k -m "yes"
```

`gcx` derives `src_city=mg` from the wisp-id prefix, matches it to peer `midgard`, GETs `/v0/city/midgard/mail/mg-7q2k`, parses the origin header → `(city=yggdrasil, alias=wesley)`, looks up `peers.yggdrasil`, and POSTs the reply to `http://100.121.222.11:8472/v0/city/yggdrasil/mail` with body `X-Gascity-Origin: midgard:mayor\n\nyes`. Yggdrasil's `mail-nudge` will wake `wesley` on the next tick. The loop closes.

## Known limitations

- **Body-header origin, not structured metadata.** The supervisor's mail API rejects extra body properties (`metadata` returns 422), so `gcx` smuggles origin info as an `X-Gascity-Origin` header at the top of the body. Plain `gc mail read` shows it inline; `gcx mail read` strips and re-surfaces it as `From:`.

- **`gc mail reply` errors on cross-city wisps.** The wisp `sender` field comes back empty from the gateway intake path, so `gc mail reply <id>` fails with "no sender to reply to". `gcx mail reply` works around it by reading the origin header. Tracked: `yg-e1xt`.

- **Nudge isn't HTTP-exposed.** The `nudge` capability lives on the controller's local Unix socket only. Cross-host wakeups can't originate from the sender — every recipient host runs its own `mail-nudge` order to wake its own sessions when their inboxes grow.

- **`mail-nudge` races with the UserPromptSubmit hook on interactive sessions.** The order is reliable for **agent sessions** (deacon, witness, polecats) — those run in a work-loop, the nudge text resumes the loop, and every nudge causes useful action. For **interactive Claude Code sessions** like the mayors there's a race against the existing UserPromptSubmit hook, which auto-marks unread mail as read when surfacing it on the user's next turn:

  - Order tick (every 20 s):  if `unread > prev_seen` → nudge.
  - UserPromptSubmit hook (every user turn):  surfaces unread mail in `<system-reminder>`, **marks read**.

  If the user types a prompt before the next order tick, the unread count is back to 0 by the time the order looks — the order sees no growth and no nudge fires. So an interactive mayor will *see* mail on their next turn regardless, but they won't be *autonomously* woken if they're sitting idle and a user hasn't pressed Enter recently. In practice the order works well for agent-to-agent flows (the agent isn't typing prompts) and is best-effort for mayor wake-up.

  The proper fix is supervisor-level: a "wake into a new turn" primitive that mounts the recipient agent for a turn rather than just queuing nudge text against an existing one. Out of scope for this pack.

- **No auto-distribution of the pack itself.** `gc pack add <git-url>` isn't wired up here yet, so onboarding a new host means cloning `dv-gascity-utils` and running the bootstrap above by hand. Tokens have to be ferried out-of-band to every other host (each host's gateway token must be present in `~/.gc/tokens/` on every caller).

- **One gateway port per host.** The Caddyfile binds `8472` directly. Co-tenanted cities on the same host (yggdrasil + asgard here) share that port and that token by design — there is no per-city auth. If you need per-city authorization you'd add it inside the supervisor or split hosts.

## Reference

- Live gateways:
  - `100.121.222.11:8472` on `mani-mac-mini` (serves yggdrasil + asgard)
  - `100.124.163.125:8472` on `sol-mac-mini` (serves midgard)
- Live config on this host:
  - `~/.gc/peers.toml` — peer registry
  - `~/.gc/tokens/{yggdrasil,midgard}-gateway.token` — per-host bearer tokens (mode 0600)
  - `~/.gc/gateway/Caddyfile` — gateway config
  - `~/Library/LaunchAgents/dev.gascity.gateway.plist` — launchd service
- Pack contents (in this repo):
  - `packs/gascity-comms/assets/scripts/gcx` — the wrapper
  - `packs/gascity-comms/assets/scripts/mail-nudge.sh` — order body
  - `packs/gascity-comms/orders/mail-nudge.toml` — order definition
  - `packs/gascity-comms/assets/templates/peers.toml.template` — registry starter
- Background: `~/.claude/projects/-Users-mani-yggdrasil/memory/cross_city_architecture.md` and `…/gascity_comms_pack.md`.
- Related docs: `multi-city-shared-dolt.md` (city-level shared dolt), `shared-rig-prefix.md` (multiple cities working on the same rig).
