# Per-Host Prime: content guide

> **Status:** convention only — no code change required. Each host
> that imports `packs/gascity-comms` and opts into the cross-city
> prime adds a host-specific block of facts inlined into its
> override mayor template. The cross-city-prime fragment is generic;
> the inlined block carries everything the new mayor needs to know
> about THIS host that it cannot derive from reading code.

> **Note:** earlier revisions of this doc described placing a
> separate `prime.local.md` file at
> `<rig-root>/<city>/agents/mayor/prime.local.md` and defining a
> `local-prime` template. That mechanism doesn't work — see
> `cross-city-prime-wiring-gap.md` for why. Inlining is the
> documented path.

## What goes in the inlined block

The block answers four questions a freshly-restarted mayor would
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

## Where the block goes

Inlined directly into the host's override mayor template, right after
the `{{ template "cross-city-prime" . }}` call. See
`mayor-prompt-prime-recipe.md` for the full override structure. The
block is plain markdown, not a `{{ define ... }}` template:

```markdown
{{/* … upstream mayor prompt header … */}}

{{ template "propulsion-mayor" . }}

{{ template "cross-city-prime" . }}

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

{{ template "capability-ledger-work" . }}
```

The override file lives at the host's chosen path and is loaded by gc
without any `[[patches.agent]]` patch. Hosts running multiple cities
(like `mani-mac-mini` running yggdrasil and asgard) write one
override per city.

Keep the inlined block under ~40 rendered lines. Anything longer
means it should be a doc the prime points at, not a fact list
inlined into every mayor turn.

## What NOT to put in the block

- **Tokens or secrets.** `~/.gc/tokens/` paths are fine; the contents
  are not. The block gets rendered into every mayor's prompt.
- **Generic comms facts.** `gcx`, the gateway shape, the `mail-nudge`
  cadence — those live in `cross-city-prime.template.md`. If you
  catch yourself describing how `gcx` works, move it back upstream.
- **Per-session state.** Whatever the mayor was doing 10 minutes ago
  is not durable. Use mail, beads, or memory files for that — not the
  prime, which only re-runs on restart.
- **Anything that changes more than weekly.** The prime is a snapshot
  taken on restart. Volatile facts (current bead under work, today's
  todo) belong in the assignment flow, not the prime.

## When to update the block

When a durable fact about this host changes. Concretely:

- A new peer is added, removed, or its gateway URL changes.
- A new rig is created on this host or shut down.
- A cross-city decision lands that future mayor restarts should know
  about (e.g. "we dropped the per-city Dolt backups", "refinery
  routing now uses `<rig>/gastown.refinery`").
- The host's Tailscale IP changes (rare, but possible after reinstall).

The block is a per-host "if you forget everything else, this gets you
oriented." Maintain it like a `CLAUDE.md` — small, accurate, dated
when needed.

## Verification

After writing or updating the override, render the mayor prompt and
grep for the section header:

```bash
gc prime mayor 2>&1 | grep -A 5 "This Host:"
```

If you don't see it, the override template isn't in place — re-check
the path under `<rig-root>/agents/mayor/prompt.template.md` and
re-run `gc reload`. The doctor check from `dv-gascity-utils#16`
formalizes this into an exit-code check.

## See also

- `packs/gascity-comms/template-fragments/cross-city-prime.template.md`
  — the city-agnostic prime this block completes.
- `docs/mayor-prompt-prime-recipe.md` — how to wire the host's
  override mayor prompt template (no `[[patches.agent]]` block).
- `docs/cross-city-prime-wiring-gap.md` — why the inline pattern is
  the supported path and why the obvious-looking
  `{{ template "local-prime" }}` indirection doesn't work.
- `docs/cross-city-comms.md` — full architecture; the
  cross-city-prime is a summary, this is the long form.
