# Cross-city mail protocol

How origin metadata travels between cities so replies can route back to
the sender. This formalizes the wire format used by `gcx mail send` /
`gcx mail reply` and explains why the HTTP `X-Gascity-Origin` header is
NOT load-bearing today.

## TL;DR

- **Canonical origin format**: a single line `X-Gascity-Origin: <city>:<alias>`
  at the top of the message body, followed by a blank line, then the real
  body content.
- **HTTP header `X-Gascity-Origin`**: sent by `gcx mail send` for
  forward-compat. Both yg-side and mg-side gateways currently DROP it on
  receive — it is not persisted into bead metadata. **Receivers MUST
  parse the body-line-1 form**, not the header.
- **Reply routing**: `gcx mail reply <wisp-id>` parses body-line-1,
  looks up the origin city in `~/.gc/peers.toml`, and POSTs back through
  that city's gateway. Reply works as long as the original send went
  through `gcx`.

## Why this exists separately from cross-city-comms.md

`docs/cross-city-comms.md` describes the gateway architecture
(Caddy + bearer auth + reverse-proxy to the supervisor's mail handler).
That doc focuses on transport. This doc focuses on the **payload-level
contract** — what bytes end up in the bead — which is where the
header-vs-body-line-1 confusion actually lives.

## The wire format

A cross-city wisp body looks like:

```
X-Gascity-Origin: midgard:mayor

Real message content starts here, after exactly one blank line.
Multiple paragraphs are fine; only the first line is reserved.
```

Strict requirements:

- Line 1 starts with the literal string `X-Gascity-Origin: `.
- The value is `<city>:<alias>` — colon-separated, no spaces, no extra
  punctuation. `city` matches a key in `peers.toml`; `alias` is the
  sender's role qualifier (e.g. `mayor`, `gastown.deacon`).
- Line 2 is blank.
- Line 3 onward is the real body.

`gcx mail send` writes this format automatically (lines 141–149 of
`packs/gascity-comms/assets/scripts/gcx`). `gcx mail reply` parses it
(lines 156, 205–208 of the same script).

## Why not just use the HTTP header?

`gcx mail send` DOES send `X-Gascity-Origin: <city>:<alias>` as an HTTP
request header, intentionally — once the receiving gateways persist it
into bead metadata, the body-line-1 convention becomes vestigial and we
can deprecate it. Today, the header is forward-compat only:

- **yg-receive**: persists `metadata.from` (extracted from a body JSON
  field if present), but NOT `X-Gascity-Origin`. The HTTP header lands
  at Caddy, gets reverse-proxied to the supervisor's mail handler, and
  the handler ignores it.
- **mg-receive**: same shape — header sent, header dropped. Body 'from'
  field (if present) does NOT get persisted on mg-side either; mg's
  receive path drops both.

Both receive paths are blind to the header because the gc binary's mail
ingest handler doesn't read it. Fixing this requires a binary change
(the receive path is embedded — see `docs/rig-merge-strategy.md` for
why "the pack source is in the binary" is a recurring constraint).
Until then, body-line-1 is the durable contract.

Tracking: classified as a Class C bug (gc binary fix needed) per the
classification taxonomy yg-mayor and mg-mayor settled on
2026-04-29. The body-line-1 workaround is a Class A protocol convention
that doesn't require any binary patching.

## What the receiver sees

A `gcx`-routed inbound wisp has these properties on the receiving city:

```json
{
  "id": "yg-wisp-...",
  "metadata": {
    "from": "midgard:mayor"     // present only if mg-side put a JSON 'from' in body
  },
  "description": "X-Gascity-Origin: midgard:mayor\n\nReal body...\n"
}
```

The `metadata.from` field is opportunistic — yg-receive grabs it from a
body-level JSON `from` key if mg-mayor used `gcx` (which doesn't set
that key). It is NOT a reliable signal of cross-city origin. The only
reliable signal is body-line-1.

The wisp's `created_by` field is whoever the receiving supervisor's
authenticated user is, NOT the cross-city sender. Don't read origin
from `created_by`.

## Reply routing

`gcx mail reply <wisp-id>`:

1. GETs the wisp via the receiving city's gateway.
2. Parses body-line-1. If absent, warns `using local reply` and falls
   through to plain `gc mail reply`.
3. If present, looks up `origin.city` in `peers.toml`.
4. POSTs the reply back through the origin city's gateway.
5. Stamps its OWN `X-Gascity-Origin` header on the outbound (so further
   replies continue to round-trip).

The "no origin metadata — replying locally via gc" warning that gcx
historically printed when body-line-1 was missing is misleading. Reply
DOES work as long as the original was gcx-sent. The warning should be
softened or suppressed; the actual failure mode is "neither header nor
body-line-1 present", which only happens when someone uses raw curl
without prepending the body-line-1.

## Sender contract

Two guarantees from any cross-city sender:

1. **Always go through `gcx`** for cross-city sends (`gcx mail send
   <city>:<alias>`). The wrapper handles body-line-1 and the redundant
   HTTP header.
2. **Never use plain `gc mail send` for cross-city.** It writes a bead
   with no origin signal of any kind. Replies cannot route back.

If you must use raw curl (debugging, custom adapters), prepend the
body-line-1 manually to your POST body:

```bash
BODY="X-Gascity-Origin: $(hostname -s):mayor

Real body here."
curl -H "Authorization: Bearer $TOKEN" \
     -H "Content-Type: application/json" \
     -d "{\"subject\":\"...\",\"description\":\"$BODY\",\"to\":\"mayor\"}" \
     http://<peer-ip>:8472/v0/cities/<city>/mail
```

The HTTP header `X-Gascity-Origin` is optional but harmless — include it
so when the binary fix lands, your tools start working with metadata
persistence automatically.

## What lives on each host

- `~/.gc/bin/gcx` — the wrapper (symlinked from
  `dv-gascity-utils/packs/gascity-comms/assets/scripts/gcx`).
- `~/.gc/peers.toml` — peer registry mapping city name → URL +
  token_file. Per-host, not in the pack.
- `~/.gc/tokens/<peer>-gateway.token` — bearer token for the peer's
  gateway. 0600 mode, per-host.
- `~/.gc/gateway/Caddyfile` — local gateway config. Forwards
  authenticated requests to `127.0.0.1:8372` (the supervisor).

See `docs/cross-city-comms.md` for transport-level setup detail.

## Future: when the binary lands header persistence

When `X-Gascity-Origin` becomes a first-class metadata field, the
migration is gentle:

1. New gc binary reads the HTTP header into `metadata.gc.origin`.
2. `gcx mail reply` checks `metadata.gc.origin` first, falls back to
   body-line-1 for old wisps that predate the binary fix.
3. Body-line-1 stamping in `gcx mail send` becomes optional — leave it
   on for a release cycle (cross-version compat) then deprecate.
4. The "warning: replying locally" branch can be removed entirely once
   no wisps lack origin in either form.

Until that lands, this doc is the contract.
