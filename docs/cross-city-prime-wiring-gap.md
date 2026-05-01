# Host-local prime: the inline pattern (and why)

> **Status:** documented working pattern. The original recipe relied on
> a `[[patches.agent]]` block with `inject_fragments_append` to wire a
> separate `local-prime.template.md` file into the mayor template.
> That mechanism doesn't reach the mayor agent at workspace scope on
> current gc binaries — and gc binary changes are off the table.
> The supported path is to **inline** the host-local content directly
> into the override mayor template, no separate file, no `{{ template
> "local-prime" }}` indirection. This doc explains what works and why
> the obvious indirection doesn't, so future operators don't waste a
> turn rediscovering it.

## The pattern

Each host that wants its mayor sessions to come up oriented to the
cross-city setup writes **one file**: a host-local override of the
mayor prompt template. That file:

1. Starts as a verbatim copy of the upstream gastown mayor prompt.
2. Adds a single `{{ template "cross-city-prime" . }}` call near the
   top — the city-agnostic content, defined in
   `packs/gascity-comms/template-fragments/cross-city-prime.template.md`,
   which is automatically discoverable when gascity-comms is imported.
3. Inlines the host-specific facts (Tailscale IP, peers, rigs, recent
   decisions) directly inline at the next insertion point — as plain
   markdown content, **not** as a `{{ template "local-prime" }}` call
   pointing at a separate file.

The override lives at the path the host's `pack.toml` already accepts
without needing a `[[patches.agent]]` block:

```
<rig-root>/agents/mayor/prompt.template.md
```

Importing `packs/gascity-comms` is still required (Step 1 of
`mayor-prompt-prime-recipe.md`) — that's what makes the
`{{ template "cross-city-prime" . }}` call resolve. But there is no
Step 4 to point an agent patch at the override; just dropping the
override at the right path is enough.

## Why the indirection doesn't work

The recipe in earlier revisions of `mayor-prompt-prime-recipe.md`
described a four-step shape:

1. Import `packs/gascity-comms`. (Works.)
2. Write `<rig-root>/<city>/agents/mayor/prime.local.md` with a
   `{{ define "local-prime" }}…{{ end }}` block. (Doesn't work — the
   default template loader doesn't scan that path.)
3. Override the mayor prompt to invoke
   `{{ template "cross-city-prime" . }}` and
   `{{ template "local-prime" . }}`. (Half works — `cross-city-prime`
   resolves because gascity-comms is on the scan path, but
   `local-prime` never resolves because Step 2's file isn't seen.)
4. Patch the agent definition with `[[patches.agent]]` +
   `inject_fragments_append` so the loader picks up both files.
   (Doesn't work — `[[patches.agent]]` for the mayor agent at
   workspace scope is silently dropped on current gc binaries. No
   error from `gc reload`, the patch just doesn't take.)

yg's `pack.toml` carries this comment from an earlier polecat-scaling
attempt that hit the same wall:

```
# NOTE: tried [[patches.agent]] (workspace scope, agent not visible) and
# [[defaults.rig.patches.agent]] (unknown field) to set polecat
# min_active_sessions=1 — neither schema-valid in this gc version.
```

So the four-step shape can't complete. The inline pattern collapses
Steps 2-4 into a single edit on the override file.

## What you write

The override file is the upstream gastown mayor prompt with two
modifications:

1. A `{{ template "cross-city-prime" . }}` call right after the
   propulsion-mayor section.
2. A "This Host: …" markdown block right after the cross-city-prime
   call, with the four-question content guide from
   `host-prime-stub.md` filled in concretely.

```gotemplate
{{/* … upstream mayor prompt header … */}}

{{ template "propulsion-mayor" . }}

{{ template "cross-city-prime" . }}

### This Host: <city> on <hostname>

- **Tailscale IP**: <ip>:8472 (gateway plist: `dev.gascity.gateway`).
- **Peers in `~/.gc/peers.toml`**:
  - `<peer-city>` — `http://<peer-ip>:8472`
    (token: `~/.gc/tokens/<peer>-gateway.token`).
- **Active rigs**:
  - `<rig-name>` (prefix `<p>`) — <one-line purpose>.

### Recent local decisions

- <date> — <one-line note, why not derivable from git/bd>.

{{ template "capability-ledger-work" . }}

{{/* … rest of upstream mayor prompt … */}}
```

That's the entire host-local opt-in. No `prime.local.md`, no
`{{ define "local-prime" }}`, no `[[patches.agent]]` block.

## Verification

Quick check from anywhere on the host:

```bash
gc prime mayor 2>&1 | grep -iE 'cross-city|peers|gateway|gcx|tailscale' | head -3
gc prime mayor 2>&1 | grep -A 2 'This Host:'
```

The first grep should show hits — `cross-city-prime` is rendering.
The second should show your inlined "This Host" block. If only the
first matches, the override isn't taking; if neither matches,
gascity-comms isn't on the import list (re-check `pack.toml`).

The doctor check shipped in `dv-gascity-utils#16` automates this.
Adopt it once merged.

## Current state per host (snapshot, 2026-05-01)

| Host | gascity-comms imported? | Override applied? | `gc prime mayor` shows cross-city block? |
|------|-------------------------|-------------------|------------------------------------------|
| yg   | yes — `source = "/Users/mani/dv-gascity-utils/packs/gascity-comms"` | not yet | no |
| mg   | yes — repointed to repo path on 2026-05-01 | yes — inline pattern | yes |

So yg has a fresh-mayor cold-start gap until the override lands here.
Cross-city knowledge on this host currently lives only in memory
files and the last handoff letter — both fragile to context loss.
Wiring it is a 5-line edit to a single file (see "What you write"
above), no fix-watch helper needed, no pack pollution.

## Pack refresh, while we're here

mg's separate question — "should I just repoint
`[imports.gascity-comms]` at the dv-gascity-utils repo so it tracks
main?" — has a precedent on yg. yg's `pack.toml`:

```toml
[imports.gascity-comms]
  source = "/Users/mani/dv-gascity-utils/packs/gascity-comms"
```

Direct path, no vendoring. Pack refresh is `git pull ~/dv-gascity-utils`.
mg adopted the same pattern on 2026-05-01.

The trust-boundary widens (any local edit to dv-gascity-utils takes
effect on the host), but on a single-developer host that's the same
trust-boundary as every other repo on disk. For multi-tenant or
production hosts, vendor with periodic refresh.

## See also

- `docs/mayor-prompt-prime-recipe.md` — recipe in the new shape (no
  Step 4).
- `docs/host-prime-stub.md` — content guide for the inlined "This
  Host" block (the four questions every host should answer).
- `docs/cross-city-comms.md` — full architecture; the prime fragment
  summarizes this.
- `packs/gascity-comms/template-fragments/cross-city-prime.template.md`
  — the city-agnostic content the override pulls in via
  `{{ template "cross-city-prime" . }}`.
