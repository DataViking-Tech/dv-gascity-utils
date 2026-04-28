# Shared Rig Prefix Across Cities

> **Status:** designed and validated against `gc 1.0.0` / `bd 1.0.3`. Recipe below stands up a "second city" against an existing rig database without re-initializing it. End-to-end test (yggdrasil ↔ midgard on `sp`) still pending in this rig — see follow-up bead.

## The problem

Two cities want to work on one logical project — same git repo, same bead pool, polecats from any host. The naive flow breaks it:

- Yggdrasil (`mani-mac-mini`): `gc rig add /Users/mani/SynthPanel --name synth-panel`
  → derives prefix `sp`, creates database `sp` on the shared dolt server, registers `[[rig]]` in yg's `.gc/site.toml`.
- Midgard (`sol-mac-mini`): `gc rig add /Users/openclaw/midgard/rigs/synthpanel --include gastown`
  → derives prefix `sy` (from "synthpanel"), creates a *separate* database `sy` on the same shared server, registers `[[rig]]` in mg's `.gc/site.toml`.

Now `sp.issues` and `sy.issues` are unrelated bead pools. Polecats on each side scan their own pool. Cross-city sling routing keys on prefix (`internal/sling.FindRigByPrefix`), so even if you produced a bead with prefix `sp` it would never match midgard's local rigs and either bounce or get blocked by the cross-rig guard.

The fix is straightforward but undocumented: **the second city must adopt the existing database with the same prefix**, not let `bd init` re-derive a new one.

## What's actually available

What the gc/bd surface exposes today (validated by `--help`, `gc 1.0.0`/`bd 1.0.3` binary strings, and live runs against the shared dolt server):

| Command | Role |
|---|---|
| `gc rig add <path>` | Default: runs `bd init`, derives prefix from name, creates DB. The "first city" path. |
| `gc rig add <path> --adopt --prefix <p>` | Skips `bd init`. Requires `<path>/.beads/metadata.json` *and* `<path>/.beads/config.yaml` with a valid `issue_prefix` already in place. The "second city" path. |
| `gc rig set-endpoint <name> --external --host … --port … [--adopt-unverified]` | Per-rig external endpoint pin. Writes `gc.endpoint_origin: explicit` into the rig's `config.yaml`. Useful when the second city's *city* dolt is local but the *rig*'s dolt should be the shared one. |
| `gc rig set-endpoint <name> --inherit` | Reverts a rig back to inheriting the city endpoint. |
| `gc beads city use-external --host … --port … [--adopt-unverified]` | Flips the *whole city* to a shared dolt. Cascades to rigs whose origin is `inherited_city`. |
| `gc dolt-state ensure-project-id --metadata <file> --host … --port … --database <db>` | **Reconciles `metadata.json#project_id` with the database's `_project_id` row.** If local is empty, it pulls from the database (`source: database`). This is the missing piece for "join". |
| `gc dolt cleanup` | Drops orphaned databases (no rig in any city references them). The cleanup half. |

What does **not** exist in `gc 1.0.0`:

- ❌ `gc rig join` — no such command. (`gc rig --help` shows: `add`, `list`, `remove`, `restart`, `resume`, `set-endpoint`, `status`, `suspend`.)
- ❌ `gc beads rig adopt` — `gc beads` only has `city` and `health`; there is no `rig` subcommand here.
- ❌ Auto-detect-and-join behavior in `gc rig add`. If `.beads/` exists, you must pass `--adopt` explicitly (the error tells you so: `gc rig add: %s/.beads already exists; use --adopt …`).

So `--adopt` plus `gc dolt-state ensure-project-id` *is* the join primitive — we just have to wire up the per-host stub `.beads/` ourselves.

## How the identity check works

`gc rig add` (and `gc rig set-endpoint --external` without `--adopt-unverified`) verifies project identity by comparing `<path>/.beads/metadata.json#project_id` against `<database>.bd_metadata#_project_id`. Mismatch → fatal: `database _project_id %q does not match desired %q`.

Three scenarios, all covered by `gc dolt-state ensure-project-id`:

| Local has `project_id`? | DB has `_project_id`? | What `ensure-project-id` does |
|---|---|---|
| yes | yes (matching) | no-op verify (`metadata_updated: false`, `database_updated: false`, `source: existing`) |
| yes | no | writes local id into the DB (`database_updated: true`, `source: metadata`) |
| **no** | **yes** | **pulls DB id into local metadata.json** (`metadata_updated: true`, `source: database`) — this is what makes "join" work |
| no | no | generates a new id, writes both (`source: generated`) |

The third row is the one that matters here. Pre-staging an empty stub `metadata.json` (no `project_id`) and pointing `ensure-project-id` at the existing remote DB is what bootstraps the second city without forking identity.

Verified live against `sp` on the shared dolt:

```
$ cat /tmp/joinscan/.beads/metadata.json
{ "backend":"dolt", "database":"dolt", "dolt_database":"sp",
  "dolt_mode":"server" }

$ gc dolt-state ensure-project-id \
    --metadata /tmp/joinscan/.beads/metadata.json \
    --host 127.0.0.1 --port 16022 --user root --database sp
project_id      gc-local-771a7e949f311dca91f9ebc4225e2de0
metadata_updated true
database_updated false
source           database

$ cat /tmp/joinscan/.beads/metadata.json
{ "backend":"dolt", "database":"dolt", "dolt_database":"sp",
  "dolt_mode":"server",
  "project_id":"gc-local-771a7e949f311dca91f9ebc4225e2de0" }
```

## The recipe

Run on each *additional* city (city A is the one that originally ran `gc rig add` and created the database; city B+ are joiners).

**Prerequisites on city B:**

- Shared dolt is reachable (TCP from the host). For yg ↔ mg the shared server lives at `mani-mac-mini.tail032ed9.ts.net:16022`; mg points its city at it via `gc beads city use-external --host … --port 16022 --user root --adopt-unverified` (already done as part of multi-city setup).
- The git repo is cloned locally. Polecats need a working tree on each host; the repo URL must be the same `origin` everywhere so refinery merges land in one place.
- The prefix is known (e.g. `sp`).

**Step 1 — pre-stage `.beads/`:**

```bash
LOCAL=/path/to/local/synthpanel        # this city's clone of the project
PREFIX=sp                              # the existing rig prefix on the shared dolt
DOLT_HOST=127.0.0.1                    # or the Tailscale name of the shared dolt host
DOLT_PORT=16022
DOLT_USER=root

mkdir -p "$LOCAL/.beads"

cat > "$LOCAL/.beads/config.yaml" <<EOF
issue_prefix: $PREFIX
issue-prefix: $PREFIX
dolt.auto-start: false
EOF

cat > "$LOCAL/.beads/metadata.json" <<EOF
{
  "backend": "dolt",
  "database": "dolt",
  "dolt_database": "$PREFIX",
  "dolt_mode": "server"
}
EOF
```

Notes:
- Both `issue_prefix` and `issue-prefix` keys are written — `bd` reads either, but `gc rig add --adopt` errors if the underscore form is missing (`gc rig add: --adopt requires a valid issue_prefix in .beads/config.yaml`).
- We deliberately *omit* `gc.endpoint_origin` and `gc.endpoint_status` here. `gc rig add` will fill those in based on whether the rig inherits the city endpoint or pins explicitly.
- We deliberately *omit* `project_id` from `metadata.json` so the next step pulls the canonical one out of the database.

**Step 2 — pull the canonical project_id:**

```bash
gc dolt-state ensure-project-id \
    --metadata "$LOCAL/.beads/metadata.json" \
    --host "$DOLT_HOST" --port "$DOLT_PORT" --user "$DOLT_USER" \
    --database "$PREFIX"
```

Expected output: `source: database`, `metadata_updated: true`. After this, `metadata.json` has the same `project_id` as city A.

**Step 3 — register the rig:**

```bash
gc rig add "$LOCAL" --name synth-panel --prefix "$PREFIX" --adopt
```

Notes:
- `--prefix` *must* match what's in `config.yaml`; otherwise `gc rig add: rig %q already has bead prefix %q (requested %q)` fires.
- `--name` can differ between cities; only the prefix has to match. Cities each maintain their own `.gc/site.toml` `[[rig]]` list — same prefix in two different `[[rig]]` entries on two different hosts is exactly what we want.
- If the second city's *city*-level dolt is the shared one (the `gc beads city use-external` setup), the rig will inherit it (`gc.endpoint_origin: inherited_city`). If the city is on its own dolt and only this rig should reach across, follow with:
  ```bash
  gc rig set-endpoint synth-panel --external \
      --host "$DOLT_HOST" --port "$DOLT_PORT" --user "$DOLT_USER"
  ```
  which writes `gc.endpoint_origin: explicit`.

**Step 4 — verify:**

```bash
# From inside $LOCAL:
bd list --limit 5             # should see beads city A created
gc rig list                   # synth-panel appears with the right prefix
gc rig status synth-panel     # endpoint resolves, agents can spawn
```

**Step 5 — wire cross-rig routing:**

The cross-rig guard (`internal/sling.FindRigByPrefix`) blocks routing when no local rig has the bead's prefix. After step 3 each city has a local rig with prefix `sp`, so:

- City B agent slings a bead with prefix `sp` → finds local rig → routes locally. ✓
- City A creates a bead `sp-123` → both cities' polecat hooks see it in the shared pool → first one to atomic-claim wins (`bd update --claim` is dolt-transaction-safe). ✓
- Refineries on each side merge into the same git origin. The PR/branch namespace is shared by virtue of `git push origin HEAD`. (The polecats' worktrees live in each city's `.gc/worktrees/synth-panel/<polecat>/`, so they don't collide.)

No `--force` flag, no cross-rig guard suppression — the topology is now *intra-prefix*, not cross-rig.

## A `gc rig join` shell helper

Until/unless this gets a proper subcommand, the recipe above lives in `packs/gascity-comms/assets/scripts/gc-rig-join`. Per-host install:

```bash
ln -sf ~/dv-gascity-utils/packs/gascity-comms/assets/scripts/gc-rig-join \
       ~/.gc/bin/gc-rig-join

# Then, on the second city:
gc-rig-join /local/path --prefix sp --name synth-panel \
            --host mani-mac-mini.tail032ed9.ts.net --port 16022
```

The script does steps 1–3 (and optionally step 5's `set-endpoint` call) idempotently, with a `--dry-run` mode. See its `--help` for details.

## Cleaning up the midgard `sy` orphan

The misregistered rig on midgard's side leaves `sy` on the shared dolt with no users once removed. Sequence (run on `sol-mac-mini`):

```bash
# 1. Drop midgard's bad rig registration
gc rig remove synth-panel       # ← whatever name midgard used; check with `gc rig list`

# 2. Garbage-collect the now-orphaned database
gc dolt cleanup                 # finds sy, prompts to drop it
```

`gc dolt cleanup` only removes databases that are not referenced by *any* `[[rig]]` in the city's site.toml. Since yg references `sp` (not `sy`) and mg has just removed its `sy` reference, `sy` is now an orphan and safe to drop. Then run the recipe above to join `sp`.

## Test plan

This recipe is validated piecewise (each command tested live against the running shared dolt server) but has not yet been exercised end-to-end across two cities. The follow-up bead should:

1. Stand up a brand-new test rig on yg (`gc rig add /tmp/test-rig --name test-shared --prefix tsh`) and confirm a bead is created in the `tsh` DB.
2. From a second sandbox path that simulates "city B" — easiest way: a separate shell with `BEADS_DIR` and `GC_BEADS_SCOPE_ROOT` unset, against an alternate `.gc/` site dir — pre-stage `.beads/`, run `ensure-project-id`, run `gc rig add --adopt`. Verify `bd list` from both sides shows the same beads.
3. Sling a bead from each side, confirm both cities' polecat pools see it, and confirm the cross-rig guard does not fire.
4. Once the local end-to-end works, repeat on the actual yg ↔ mg pair after cleaning up `sy`.

## Open questions / future work

- **`gc rig join` proper.** The shell helper is a stopgap. Upstream-worthy: a real subcommand that wraps these steps, validates the prefix, and bails with a useful error if the database doesn't exist on the target server (instead of letting `ensure-project-id` fail with a generic connection error).
- **Identity mismatch recovery.** If a second city accidentally ran `gc rig add` (no `--adopt`) and minted its own `project_id`, the resulting metadata is now divergent from the shared DB. The fix would be: delete the local `.beads/`, re-run the join recipe. We should sanity-check this works without leaving stale rows somewhere.
- **`bd_metadata` schema.** The `_project_id` row lives in a `bd_metadata` table inside each rig database. There may be other rows there (auto-export config, local versions, etc.) that *should* be per-host rather than shared. Worth a follow-up audit.
- **Refinery coordination across cities.** Two refineries draining the same queue should be fine (they atomic-claim too) but we haven't stress-tested it. Worth filing once the basic join works.
- **Worktree path collisions.** Each city manages its own `.gc/worktrees/<rig>/<polecat>/` so this should be safe by construction, but worth confirming that the work-bead `metadata.work_dir` is interpreted per-host (it's an absolute path, so the witness on city B wouldn't try to clean a path written by city A).

## References

- `gc rig add --help`, `gc rig set-endpoint --help`, `gc dolt-state ensure-project-id --help`
- Live yg city: `/Users/mani/yggdrasil/.gc/site.toml`, `/Users/mani/SynthPanel/.beads/{config.yaml,metadata.json}`
- Shared dolt config: `/Users/mani/yggdrasil/.gc/runtime/packs/dolt/dolt-config.yaml` (port 16022, listens on `0.0.0.0`)
- `gc dolt list` shows the per-prefix databases on the shared server
- Related docs: `docs/multi-city-shared-dolt.md` (city-level shared dolt), `docs/cross-city-comms.md` (mail/nudge plumbing)
