# Cross-City Communications

> **Status:** skeleton. Polecat: write this up from the live setup. The architecture is implemented and working between yggdrasil ↔ asgard ↔ midgard.

## The problem

(Polecat: 2-3 paragraphs.)
- gc supervisor TCP API is hardcoded to `127.0.0.1:8372` — no config knob to expose it on Tailscale.
- Mail wisps live in the sender's local DB (yg.wisps for yggdrasil, mg.wisps for midgard) — naturally city-isolated, no cross-city delivery.
- `gc mail send mayor` is ambiguous when both yggdrasil and midgard have a "mayor" — they each see their own.

## The architecture

(Polecat: draw / describe.)
1. **Per-host Caddy gateway** binds the host's Tailscale IP on port `8472`, validates `Authorization: Bearer <token>`, injects `X-GC-Request: 1`, forwards to `127.0.0.1:8372`. (Caddyfile lives at `~/.gc/gateway/Caddyfile`, launchd-managed via `~/Library/LaunchAgents/dev.gascity.gateway.plist`.)
2. **Per-host token store** at `~/.gc/tokens/<peer>-gateway.token` (mode 0600). One token per host's gateway.
3. **Per-host peer registry** at `~/.gc/peers.toml` mapping city name → gateway URL + token file. Tokens stay outside the pack; peers.toml stays outside the pack (per-host).
4. **`gcx`** (in this pack at `packs/gascity-comms/assets/scripts/gcx`) — Python wrapper for `mail send|reply|inbox|read` and `cities`. Falls through to plain `gc` for non-cross-city calls. Stamps an in-band `X-Gascity-Origin: <city>:<alias>` header at the top of outgoing bodies so replies can route back via the origin.
5. **`mail-nudge` order** (in this pack at `packs/gascity-comms/orders/mail-nudge.toml`) — every 20s, scans active named sessions in this city, nudges any whose unread count grew since the last tick. Per-session state in `$GC_CITY_RUNTIME_DIR/mail-nudge/<alias>.last_unread`. Uses `--delivery wait-idle` so sessions in mid-turn aren't interrupted.

## How addressing works

(Polecat: explain the syntax.)
- `gcx mail send <city>:<alias> -s <subject> -m <body>` — POST to `<peer-gateway>/v0/city/<city>/mail`
- `gcx mail send mayor -s ... -m ...` — falls through to local `gc`
- `gcx mail inbox @<city>` — list inbox at peer (broadcast/browse)
- `gcx mail reply <wisp-id> -m <body>` — reads X-Gascity-Origin from the wisp, routes back to origin city. Falls back to local `gc mail reply` if origin missing.

## Per-host bootstrap

(Polecat: copy from `mg-comms` bead's recipe — that's the canonical install steps.)

## Known limitations

- API rejects extra body properties (`metadata` field) — that's why origin is in the body header instead of structured metadata.
- Wisp `sender` field comes back empty from the gateway intake path. `gc mail reply` errors with "no sender to reply to". `gcx mail reply` works around it via the origin header. (Tracked: yg-e1xt.)
- Nudge capability isn't exposed over HTTP — that's why nudges are local (each city's controller nudges its own sessions via the local `mail-nudge` order, not from the sender side).

## Reference

- Live gateways: `mani-mac-mini.tail032ed9.ts.net:8472` (serves yggdrasil + asgard), `sol-mac-mini.tail032ed9.ts.net:8472` (serves midgard).
- Memory file: `~/.claude/projects/-Users-mani-yggdrasil/memory/cross_city_architecture.md` for the full setup walkthrough.
