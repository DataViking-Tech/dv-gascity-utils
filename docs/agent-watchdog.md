# Agent watchdog: backstop spawning for rig-scoped agents

Per-city cooldown order that forces a spawn when the supervisor's auto-scale
path silently skips one despite queued work. Pairs with the warm-pool
override (`min_active_sessions = 1` per `[[rigs.overrides]]`) so the
watchdog is a backstop, not the primary scaling engine.

## The bug it works around

The supervisor decides scaling per template (`<rig>/gastown.polecat`,
`<rig>/gastown.refinery`) on each tick of its reconciler loop. The decision
log line reads:

```
poolDesired: <rig>/<template> = N
scaleCheck:  <rig>/<template> = N
Woke session '<alias>'
session lifecycle: op=start outcome=success
```

When everything works, all four lines fire in order. Two failure modes
silently break the chain after `poolDesired` — the queue then sits forever
until a human runs `gc session new <rig>/<template>` manually.

### 1. `poolDesired` flap between consecutive ticks

`poolDesired` is computed by counting beads that match the template. The
match window changes between consecutive reads (a routed bead briefly has
`assignee=null` in one read but is claimed by the time the next tick
samples), so `N` flaps:

```
poolDesired: traitprint-cloud/gastown.polecat = 2
poolDesired: traitprint-cloud/gastown.polecat = 1
scaleCheck:  traitprint-cloud/gastown.polecat = 1
```

The 2-want is never reflected in a `scaleCheck`, so the second polecat
never spawns. The queue is implicitly underserved.

### 2. Stale session beads inflate active count

When a session exits without clean reaping, its session bead persists.
`scaleCheck` counts the stale bead as live and skips a spawn even though
the tmux session is gone. The reaper logs the cleanup *afterwards*:

```
WARN reconciler: reaped stale session bead yg-a7n3t — tmux session not found
```

By the time the bead is reaped, several scaleCheck cycles may have
declined to spawn.

Both modes are silent: `poolDesired` logs correctly, but no
`scaleCheck`-then-create follows. Manual `gc session new` works because
it bypasses `scaleCheck` entirely.

## What this order does

`packs/gascity-comms/orders/agent-watchdog.toml` runs every 30s. For each
rig listed in `gc config show`, for each scaled template
(`refinery`, `polecat`):

1. Count queued work — beads routed to `<rig>/gastown.<template>` with
   no assignee, plus open beads explicitly assigned to that template
   name.
2. Count live sessions — `gc session list --state=active --template=...`.
3. Count *recent* sessions — created within the last 60s (configurable
   via `AGENT_WATCHDOG_RECENT_CUTOFF`). This guards against racing the
   reconciler if it's actively materializing one.
4. Spawn iff `queued > 0 AND live == 0 AND recent == 0`.

Spawning calls `gc session new <full-template> --no-attach` with no
`--alias`, so the supervisor picks a free name from the namepool.
Because the script only spawns when `live == 0`, it cannot exceed
`max_active_sessions` — the live==0 gate means at most one watchdog
session per template per tick. Subsequent ticks observe `live > 0` and
skip.

The order processes templates in this order: **refinery first**, then
polecat. A stalled refinery blocks merge throughput across all polecats
in the rig, so the spawn budget goes to the refinery first when both
need help.

## Why this is a backstop, not the primary path

The companion script `packs/gascity-comms/assets/scripts/gc-warm-rig-pool`
applies `min_active_sessions = 1` to each rig's polecat and refinery via
`[[rigs.overrides]]` in `city.toml` (schema documented in
[`agent-scaling.md`](agent-scaling.md)). The warm slot eliminates the
cold-start path: the reconciler keeps one of each template alive at all
times, so most queued beads dispatch within seconds rather than minutes.

The watchdog handles the seam where the warm slot has been killed (idle
timeout, manual `gc session kill`, controller crash) and the reconciler
fails to replace it. Without the warm slot, the watchdog would be the
primary spawn engine — fine, but a 30s tick is much slower than a
healthy reconciler.

## Configuration knobs

- `AGENT_WATCHDOG_RECENT_CUTOFF` (default `60`, seconds): how far back to
  look for "the reconciler may already be spawning one." Raise it if
  spawns routinely take longer than 60s on this host.

- The template list is hard-coded to `refinery polecat`. Adding witness
  is intentionally not done — witness has `min_active_sessions = 1` by
  default in the gastown pack, so a missing witness already implies a
  bigger problem the watchdog can't solve in 30s.

## Operational notes

- macOS bash 3.2 safe (uses tab-separated string instead of associative
  arrays for the rig table).
- Skips silently if `gc`, `bd`, or `jq` is missing — the cooldown order
  doesn't need to fail loudly when its preconditions aren't met.
- All spawn attempts log a single line to stdout:
  `agent-watchdog: spawn <full> (queued=N, live=0)` followed by a
  per-tick summary `agent-watchdog: spawned N session(s)` when any
  spawn happened.
- Failures from `gc session new` log `agent-watchdog: spawn failed for
  <full>` but never abort the run — the next tick retries.

## Disabling

If the upstream supervisor bug gets fixed and the watchdog is no longer
needed:

```toml
# city.toml
[[orders.overrides]]
name = "agent-watchdog"
enabled = false
```

Or delete `packs/gascity-comms/orders/agent-watchdog.toml` and reload.

## When this won't help

- **Cross-host spawn.** The watchdog runs per-city; each host runs its
  own. A queued bead in city A won't trigger a spawn on city B.
- **Reconciler unable to spawn at all** (e.g. credential failure, host
  out of disk). The watchdog uses the same `gc session new` path; if
  that path is broken, the watchdog's spawn attempts also fail. Watch
  the `agent-watchdog: spawn failed` line in the order log.
- **Queue larger than `max_active_sessions`.** The watchdog can only
  spawn one session per template per tick (because it gates on
  `live == 0`). If you need more capacity, raise the agent's
  `max_active_sessions` instead.

## Related

- `docs/agent-scaling.md` — schema for `[[rigs.overrides]]`, including
  `min_active_sessions`.
- `packs/gascity-comms/orders/agent-watchdog.toml` — the order
  definition.
- `packs/gascity-comms/assets/scripts/agent-watchdog.sh` — the spawn
  loop.
- `packs/gascity-comms/assets/scripts/gc-warm-rig-pool` — patches
  `city.toml` to add the warm-pool overrides.
