# Mayor Prompt Prime Recipe

> **Status:** opt-in, per host. The upstream gastown mayor prompt
> template is shared across cities and is NOT modified. Hosts that
> want freshly-restarted mayors to come up oriented to the cross-city
> setup override the mayor prompt locally and pull in two fragments:
> the city-agnostic `cross-city-prime` from `packs/gascity-comms`,
> and a per-host `local-prime` written by the host (see
> `docs/host-prime-stub.md`).

## What this recipe does

Out of the box, a freshly-spawned mayor session knows nothing about
the cross-city setup beyond what's hard-coded in the upstream gastown
mayor template. After this recipe is applied, every mayor turn on
this host expands a prime block that covers:

- The cross-city comms stack (gateway, `peers.toml`, `gcx`,
  `X-Gascity-Origin`, `mail-nudge`).
- The structural autonomy gap (UserPromptSubmit race) so the mayor
  doesn't waste cycles trying to "fix" it.
- Where to read more (`docs/`, memory files, bead history).
- Host-specific facts: Tailscale IP, current peers, active rigs,
  recent local decisions.

Cost: ~80–120 lines of mayor prompt context per turn.

## Architecture: who owns what

```
upstream gastown pack       (shared, never modified)
  └── agents/mayor/prompt.template.md          ← do not patch
      ├── {{ template "propulsion-mayor" . }}
      └── {{ template "capability-ledger-work" . }}

dv-gascity-utils            (shared, this repo)
  └── packs/gascity-comms/
      └── template-fragments/
          └── cross-city-prime.template.md     ← city-agnostic prime

<host-local pack>           (per host, NOT shared)
  ├── agents/mayor/prompt.template.md          ← override that
  │                                              invokes both
  │                                              cross-city-prime
  │                                              AND local-prime
  └── template-fragments/
      └── local-prime.template.md              ← host-specific stub
```

The override template is a copy of the upstream mayor prompt with two
extra `{{ template ... }}` calls inserted. It lives in the host's
local pack — anything in this repo or the upstream gastown pack
remains unmodified.

## Step 1: import the gascity-comms pack

In the host's local `pack.toml`:

```toml
[imports.gascity-comms]
  source = "/absolute/path/to/dv-gascity-utils/packs/gascity-comms"
```

Then `gc reload`. This makes the `cross-city-prime` define visible.

## Step 2: write the local-prime fragment

Create the host-specific stub at the path agreed in
`docs/host-prime-stub.md`. For a host with one city `<city>` running
out of `<rig-root>`, place it at:

```
<rig-root>/<city>/agents/mayor/prime.local.md
```

Contents (filled with concrete host facts):

```gotemplate
{{ define "local-prime" }}
### This Host: <city> on <hostname>

- **Tailscale IP**: <ip>:8472.
- **Peers in `~/.gc/peers.toml`**:
  - `<peer-city>` — `http://<peer-ip>:8472`
    (token: `~/.gc/tokens/<peer>-gateway.token`)
- **Active rigs**:
  - `<rig-name>` (prefix `<p>`) — <one-line purpose>.

### Recent local decisions

- <date> — <one-line note>.
{{ end }}
```

See `docs/host-prime-stub.md` for the full content guide and what NOT
to put here.

## Step 3: copy the upstream mayor prompt and add the prime calls

The override template is a verbatim copy of the upstream gastown
mayor prompt with two `{{ template ... }}` lines inserted. A sensible
spot is right after `{{ template "propulsion-mayor" . }}` and before
`{{ template "capability-ledger-work" . }}`, but anywhere is fine
provided it runs once per turn.

```gotemplate
{{/* … upstream mayor prompt header … */}}

{{ template "propulsion-mayor" . }}

{{ template "cross-city-prime" . }}
{{ template "local-prime" . }}

{{ template "capability-ledger-work" . }}

{{/* … rest of upstream mayor prompt … */}}
```

Save this at a path inside the host's local pack, e.g.:

```
<host-pack-root>/agents/mayor/prompt.template.md
```

## Step 4: patch the agent definition to use the override

In the host's local `pack.toml`, add a single `[[patches.agent]]`
block that points the mayor's `prompt_template` at the override and
also injects the two fragment files via
`inject_fragments_append` so they're loaded into the template
namespace:

```toml
[[patches.agent]]
  name = "mayor"
  prompt_template = "agents/mayor/prompt.template.md"
  inject_fragments_append = [
    "/absolute/path/to/dv-gascity-utils/packs/gascity-comms/template-fragments/cross-city-prime.template.md",
    "/absolute/path/to/<host-rig-root>/<city>/agents/mayor/prime.local.md",
  ]
```

`prompt_template` is resolved relative to the patching pack's root.
`inject_fragments_append` takes absolute paths today — see the
discussion in `docs/collaborative-loops.md` (Opting in) for the
caveats around relative-path resolution on different gc versions.

## Step 5: reload and verify

```bash
gc reload
gc agent prompt mayor 2>&1 | grep -A 2 "Cross-City Operational Prime"
gc agent prompt mayor 2>&1 | grep -A 2 "This Host:"
```

If both blocks appear, the override is wired. If you see
`gc: inject_fragment %q: template not found`, one of the fragment
paths didn't resolve — re-check the absolute paths.

## Trade-offs

### What you gain

- Every mayor restart on this host comes up oriented. No more "wait,
  what's our Tailscale IP again?" or "do we have a refinery
  convention this week?" cold-start questions.
- Cross-city threads pick up faster because both mayors share the
  same operational mental model from the same fragment.
- The structural autonomy gap is named explicitly, so new mayors
  don't burn cycles trying to autonomously poll their inbox.

### What you give up

- ~80–120 lines of mayor prompt context per turn. On long sessions
  this is a few percent of context budget.
- The override template is a fork of the upstream gastown mayor
  prompt. When upstream changes, you re-merge. Keep the override
  minimal (just the two `{{ template ... }}` calls inserted into a
  vanilla copy) so re-merges are mechanical.
- Per-host opt-in means each host has to do this once. There is no
  "ship the prime everywhere automatically" path — that's a feature,
  because the host-specific facts genuinely differ per host.

### What this does NOT change

- The upstream gastown pack stays unmodified. Other hosts on other
  versions of gastown are unaffected.
- The cross-city-prime fragment in this repo is shared — every host
  that opts in renders the same generic content. Updates land here
  centrally.
- `dv-gascity-utils/docs/cross-city-comms.md` remains the canonical
  long-form reference. The fragment is a summary, not a replacement.

## See also

- `packs/gascity-comms/template-fragments/cross-city-prime.template.md`
  — the fragment.
- `docs/host-prime-stub.md` — what goes in `local-prime`.
- `docs/cross-city-comms.md` — full architecture (the fragment is a
  summary of this).
- `docs/collaborative-loops.md` — sibling fragment with the same
  opt-in pattern; its "Opting in" section discusses the
  `inject_fragments_append` caveats in more depth.
