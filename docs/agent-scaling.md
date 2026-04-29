# Agent Scaling: Per-Rig Overrides

How to override per-agent scaling fields (`min_active_sessions`,
`max_active_sessions`, `idle_timeout`, etc.) for an agent that is **rig-
scoped** — including the gastown trio (`witness`, `refinery`, `polecat`).

This started as the question "how do I keep one polecat warm in each rig
so brand-new beads don't sit through 10–20 min of reconciler latency
before a worker spawns?" The polecat agent's default is
`min_active_sessions = 0` (cold pool, on-demand spawn). Bumping it to
`1` at the rig level eliminates the cold-start.

## TL;DR — keep one polecat warm in a rig

Add an `[[rigs.overrides]]` block under the rig in `<city>/city.toml`:

```toml
[[rigs]]
name = "dv-gascity-utils"
[rigs.imports.gastown]
  source = ".gc/system/packs/gastown"

# NEW: keep one polecat session warm in this rig.
[[rigs.overrides]]
agent = "polecat"
min_active_sessions = 1
```

Reload the city to pick it up:

```bash
gc reload
```

Verify the patch landed:

```bash
gc config explain --agent polecat --rig dv-gascity-utils \
  | grep min_active_sessions
# min_active_sessions            = 1                               # city.toml
```

The reconciler will spin up one warm polecat for the rig within its next
cycle. Subsequent beads routed to the rig pool dispatch within seconds
instead of waiting on the cold-spawn path.

## Why this is the right knob

Three other forms were tried first and rejected:

| Attempt                                  | Where         | Result                                                  |
|------------------------------------------|---------------|---------------------------------------------------------|
| `[[patches.agent]] name = "polecat"`     | `pack.toml`   | `agent polecat not found in merged config`              |
| `[[defaults.rig.patches.agent]]`         | `pack.toml`   | `unknown field defaults.rig.patches.agent`              |
| `[rigs.agent_defaults]` / `[rigs.agents.polecat]` | `city.toml`   | silently ignored (schema is lenient — no error, no effect) |
| `[[rigs.overrides]] agent = "polecat"`   | `city.toml`   | ✅ applies — value shows up in `gc config explain`       |

The reason `[[patches.agent]]` at the workspace scope can't reach
`polecat` is that workspace patches resolve against the **merged
workspace config**, which only contains city-scoped agents (mayor,
deacon, boot, dog). Rig-scoped agents (witness, refinery, polecat) are
expanded per-rig from the rig's own pack imports — they aren't visible
at the workspace layer.

`[[rigs.overrides]]` lives **inside** a rig's `[[rigs]]` block in
`city.toml`, so it applies during the rig's pack expansion when the
rig-scoped agents are materializing. That's the layer where polecat
actually exists.

`[[rigs.patches]]` is the higher-precedence sibling of
`[[rigs.overrides]]` and accepts the same fields. Stick with
`overrides` for routine scaling tweaks; reserve `patches` for the rare
case where you need to win against a more specific override.

## Pattern: warm one polecat in every rig

`[[rigs.overrides]]` is per-rig — there is **no working
`[defaults.rig.…]` form** that broadcasts agent overrides to every
rig. So repeat the block under each rig you want to keep warm:

```toml
[[rigs]]
name = "synth-panel"
[rigs.imports.gastown]
  source = ".gc/system/packs/gastown"
[[rigs.overrides]]
agent = "polecat"
min_active_sessions = 1

[[rigs]]
name = "dv-gascity-utils"
[rigs.imports.gastown]
  source = ".gc/system/packs/gastown"
[[rigs.overrides]]
agent = "polecat"
min_active_sessions = 1

[[rigs]]
name = "traitprint"
[rigs.imports.gastown]
  source = ".gc/system/packs/gastown"
[[rigs.overrides]]
agent = "polecat"
min_active_sessions = 1

[[rigs]]
name = "traitprint-cloud"
[rigs.imports.gastown]
  source = ".gc/system/packs/gastown"
[[rigs.overrides]]
agent = "polecat"
min_active_sessions = 1
```

If you only want certain rigs warm (e.g. demo rigs, but not background
ones), include the override on those rigs only.

## Other fields that work in `[[rigs.overrides]]`

The override block accepts any field defined on the agent's
`agent.toml` schema. Verified working:

```toml
[[rigs.overrides]]
agent = "polecat"
min_active_sessions = 1     # keep one warm
max_active_sessions = 8     # raise the ceiling for a busy rig
idle_timeout = "30m"        # shorter idle for a low-traffic rig
nudge = "custom nudge…"     # override the polecat's nudge string
suspended = true            # park the agent without uninstalling
```

The same form works for `witness` and `refinery`:

```toml
[[rigs.overrides]]
agent = "refinery"
idle_timeout = "1h"         # let the refinery sit longer between merges
```

## Pitfalls

### Schema is lenient — typos are silent

The TOML schema for `[[rigs]]` accepts unknown nested fields without
error. Forms like `[rigs.agents.polecat]`, `[rigs.agent_defaults]`,
and `[[rigs.patches.agent]]` all parse cleanly but apply nothing.
`gc config explain --agent <name> --rig <rig>` is the only reliable
verification — eyeball that the field you intended actually shows up
with `# city.toml` provenance.

### `[[rigs.overrides]]` vs `[[rigs.patches]]`

Both apply, both accept the same fields, and both target
`agent = "<name>"`. When both target the same field, **`patches`
wins**. For day-to-day scaling tweaks, use `overrides`. The
`patches` slot is for rare cases where you need to override an
override (e.g. a higher-priority overlay file).

### Reload, don't restart

After editing `city.toml`, `gc reload` is enough — the controller
re-reads the resolved config and the reconciler pulls the new
`min_active_sessions` on its next cycle. A full `gc restart` is
overkill and disruptive.

### Reconciler latency for the *first* warm session

Bumping `min_active_sessions` from 0 to 1 doesn't conjure a session
instantly — the reconciler still has to plan and start it on its next
cycle (typically tens of seconds, sometimes longer if the city is
under load). The benefit kicks in for the *next* bead, not the one
you're about to dispatch.

If you need a polecat *right now* for a demo or one-off, the manual
escape hatch is:

```bash
gc session new <rig>/gastown.polecat --alias furiosa --no-attach
```

That triggers an immediate spawn without changing config.

## Reference

- Per-rig schema discovered: `[[rigs.overrides]]` array of override
  blocks inside a `[[rigs]]` declaration; each block requires
  `agent = "<name>"` and accepts the agent's standard scaling fields.
- Per-rig schema also accepted (higher precedence): `[[rigs.patches]]`.
- Verification command: `gc config explain --agent <name> --rig <rig>`.
- Live polecat default (gastown pack):
  `<city>/.gc/system/packs/gastown/agents/polecat/agent.toml` —
  `min_active_sessions = 0`, `max_active_sessions = 5`, `idle_timeout = "2h"`.
