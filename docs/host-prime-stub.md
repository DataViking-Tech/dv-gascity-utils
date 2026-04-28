# Per-Host Prime Stub Convention

> **Status:** convention only — no code change required. Each host that
> imports `packs/gascity-comms` and opts into the cross-city prime
> fragment writes its own short local stub describing host-specific
> facts. The cross-city-prime fragment is generic; the local stub
> carries everything the new mayor needs to know about THIS host that
> it cannot derive from reading code.

## What goes in the local stub

The local stub answers four questions a freshly-restarted mayor would
otherwise have to re-discover:

1. **Where am I on the tailnet?** Local Tailscale IP, gateway URL,
   gateway plist label.
2. **Who are my peers?** Each entry in `~/.gc/peers.toml` — city name,
   gateway URL, who lives there (e.g. "midgard's mayor is `mayor`,
   their refinery is `mg/refinery`").
3. **What rigs run on this host?** Each rig name, its prefix, what it
   does, and any cross-city sharing of that prefix.
4. **What did we just decide?** Locally-significant durable decisions
   from the last few days that aren't obvious from `bd list` (because
   they were inferred from incidents, mailed across cities, or
   resolved via convention rather than commits).

Anything that depends on the specific host belongs here. Anything that
applies to every host belongs in `cross-city-prime.template.md`.

## Where to put the stub

By convention, each host stores its stub at:

```
<rig-root>/<city>/agents/mayor/prime.local.md
```

For yggdrasil on this host that resolves to:

```
~/yggdrasil/yggdrasil/agents/mayor/prime.local.md
```

Hosts running multiple cities (like `mani-mac-mini` running yggdrasil
and asgard) write one stub per city. The stub is checked into the
host's local pack repo, NOT into `dv-gascity-utils` — it contains
host-specific facts and is by design unshared.

## Stub structure

The stub defines a `local-prime` template that the override mayor
prompt invokes (see `docs/mayor-prompt-prime-recipe.md`):

```gotemplate
{{ define "local-prime" }}
### This Host: <city> on <hostname>

- **Tailscale IP**: <ip>:8472 (gateway plist:
  `dev.gascity.gateway`).
- **Peers in `~/.gc/peers.toml`**:
  - `<peer-city>` — `http://<peer-ip>:8472`
    (token: `~/.gc/tokens/<peer>-gateway.token`)
  - ...
- **Active rigs**:
  - `<rig-name>` (prefix `<p>`) — <one-line purpose>; <shared with
    which cities, if any>.
  - ...

### Recent local decisions

- <date> — <what was decided, in one line, and why it isn't
  derivable from git/bd>.
- ...
{{ end }}
```

Keep the stub under ~40 rendered lines. Anything longer means it
should be a doc the prime points at, not a fact list inlined into
every mayor turn.

## What NOT to put in the stub

- **Tokens or secrets.** `~/.gc/tokens/` paths are fine; the contents
  are not. The stub gets rendered into every mayor's prompt.
- **Generic comms facts.** `gcx`, the gateway shape, the `mail-nudge`
  cadence — those live in `cross-city-prime.template.md`. If you
  catch yourself describing how `gcx` works, move it back upstream.
- **Per-session state.** Whatever the mayor was doing 10 minutes ago
  is not durable. Use mail, beads, or memory files for that — not the
  prime, which only re-runs on restart.
- **Anything that changes more than weekly.** The prime is a snapshot
  taken on restart. Volatile facts (current bead under work, today's
  todo) belong in the assignment flow, not the prime.

## When to update the stub

When a durable fact about this host changes. Concretely:

- A new peer is added, removed, or its gateway URL changes.
- A new rig is created on this host or shut down.
- A cross-city decision lands that future mayor restarts should know
  about (e.g. "we dropped the per-city Dolt backups", "refinery
  routing now uses `<rig>/gastown.refinery`").
- The host's Tailscale IP changes (rare, but possible after reinstall).

The stub is a per-host "if you forget everything else, this gets you
oriented." Maintain it like a `CLAUDE.md` — small, accurate, dated
when needed.

## Verification

After writing or updating the stub, render the mayor prompt and grep
for the section header:

```bash
gc agent prompt mayor 2>&1 | grep -A 5 "This Host:"
```

If you don't see it, the override template isn't invoking
`{{ template "local-prime" . }}` — check
`docs/mayor-prompt-prime-recipe.md` for the wiring.

## See also

- `packs/gascity-comms/template-fragments/cross-city-prime.template.md`
  — the city-agnostic prime this stub completes.
- `docs/mayor-prompt-prime-recipe.md` — how to wire the host's
  override mayor prompt template to invoke both fragments.
- `docs/cross-city-comms.md` — full architecture; the
  cross-city-prime is a summary, this is the long form.
