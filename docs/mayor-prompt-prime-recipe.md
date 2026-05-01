# Mayor Prompt Prime Recipe

> **Status:** opt-in, per host. The upstream gastown mayor prompt
> template is shared across cities and is NOT modified. Hosts that
> want freshly-restarted mayors to come up oriented to the cross-city
> setup override the mayor prompt locally, invoke the
> `cross-city-prime` fragment from `packs/gascity-comms`, and inline
> a short host-specific block of facts directly in the override.

> **Note on shape:** earlier revisions of this recipe described a
> four-step sequence with a separate `local-prime.template.md` file
> wired in via `[[patches.agent]]` + `inject_fragments_append`. That
> sequence doesn't complete on current gc binaries — see
> `cross-city-prime-wiring-gap.md` for the why. The recipe below is
> the working three-step shape (import, write override, reload).
> No `[[patches.agent]]` block is required.

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

<host-rig-root>             (per host, NOT shared)
  └── agents/mayor/prompt.template.md          ← override that
                                                 invokes
                                                 cross-city-prime
                                                 AND inlines host
                                                 facts directly
```

The override template is a copy of the upstream mayor prompt with
one extra `{{ template ... }}` call (cross-city-prime) and a short
markdown block (host facts) inserted near the top. It lives in the
host's local pack — anything in this repo or the upstream gastown
pack remains unmodified.

## Step 1: import the gascity-comms pack

In the host's local `pack.toml`:

```toml
[imports.gascity-comms]
  source = "/absolute/path/to/dv-gascity-utils/packs/gascity-comms"
```

Then `gc reload`. This makes the `cross-city-prime` define visible to
the template loader.

For development hosts, point `source` directly at the dv-gascity-utils
working tree (`source = "/Users/<you>/dv-gascity-utils/packs/gascity-comms"`)
so pack refresh is `git pull`. For production hosts, vendor a copy
and refresh on a cadence. yg and mg both use the source-pointed
pattern as of 2026-05-01.

## Step 2: write the override mayor template with host facts inlined

Save the override at:

```
<rig-root>/agents/mayor/prompt.template.md
```

Start with a verbatim copy of the upstream gastown mayor prompt. Add
two pieces:

1. A `{{ template "cross-city-prime" . }}` call right after the
   propulsion-mayor section.
2. A short "This Host: …" markdown block right after that, with the
   four-question content guide from `host-prime-stub.md` filled in
   concretely (Tailscale IP, peers, rigs, recent decisions).

```gotemplate
{{/* … upstream mayor prompt header … */}}

{{ template "propulsion-mayor" . }}

{{ template "cross-city-prime" . }}

### This Host: <city> on <hostname>

- **Tailscale IP**: <ip>:8472 (gateway plist:
  `dev.gascity.gateway`).
- **Peers in `~/.gc/peers.toml`**:
  - `<peer-city>` — `http://<peer-ip>:8472`
    (token: `~/.gc/tokens/<peer>-gateway.token`)
- **Active rigs**:
  - `<rig-name>` (prefix `<p>`) — <one-line purpose>.

### Recent local decisions

- <date> — <one-line note>.

{{ template "capability-ledger-work" . }}

{{/* … rest of upstream mayor prompt … */}}
```

There is no separate `prime.local.md` file, no `{{ define
"local-prime" }}` block, no `[[patches.agent]]` patch. The override
is a single file the loader picks up automatically from the
conventional path.

See `host-prime-stub.md` for the full content guide and what NOT to
put in the inlined block.

## Step 3: reload and verify

```bash
gc reload
gc prime mayor 2>&1 | grep -iE 'cross-city|peers|gateway|gcx|tailscale' | head -3
gc prime mayor 2>&1 | grep -A 5 'This Host:'
```

The first grep should show hits — `cross-city-prime` is rendering.
The second should show the inlined "This Host" block. If neither
matches, gascity-comms isn't on the import list (re-check
`pack.toml`). If only the first matches, the override isn't being
loaded — verify the path under `<rig-root>/agents/mayor/`.

The doctor check shipped in `dv-gascity-utils#16` formalizes this
into an exit-code check. Adopt it once merged.

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
  minimal (just the `{{ template "cross-city-prime" . }}` call and
  the inlined host block) so re-merges are mechanical.
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
- `docs/host-prime-stub.md` — content guide for the inlined "This
  Host" block.
- `docs/cross-city-prime-wiring-gap.md` — why this recipe is the
  inline pattern instead of the older four-step shape.
- `docs/cross-city-comms.md` — full architecture (the fragment is a
  summary of this).
- `docs/collaborative-loops.md` — sibling cross-city template
  fragment with the same opt-in pattern.
