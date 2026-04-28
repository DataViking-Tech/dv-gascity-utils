# Shared Rig Prefix Across Cities

> **Status:** designed and validated against `gc 1.0.0` / `bd 1.0.3`. Recipe below stands up a "second city" against an existing rig database without re-initializing it. The single-host primitives (steps 1–2) are re-verified live; the cross-host yggdrasil ↔ midgard run is still pending coordination — see "Verified working" below and follow-up bead `dgu-2ro`.

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

`gc rig add` (and `gc rig set-endpoint --external` without `--adopt-unverified`) verifies project identity by comparing `<path>/.beads/metadata.json#project_id` against the database's `metadata#_project_id` row (the table is named `metadata`, not `bd_metadata` — earlier drafts of this doc used the wrong name). Mismatch → fatal: `database _project_id %q does not match desired %q`.

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

It also runs four pre-flight checks before touching any state, so failures surface as actionable messages rather than partway-through corruption:

| Check | Failure surfaces as |
|---|---|
| Prefix has no hyphen | `prefix '<p>' must not contain hyphens (conflicts with bead ID format)` |
| Prefix not already registered in this city | `prefix '<p>' already registered in this city by rig <name>` |
| Dolt server reachable | `cannot reach dolt server at <host>:<port>` |
| Database `<p>` exists on the server | `database '<p>' does not exist on <host>:<port> (city A must run 'gc rig add' first; available: …)` |
| Database is bd-shaped (has `metadata`, `issues`, `schema_migrations`) | `database '<p>' is missing the '<table>' table — not a bd-initialized database` |

The bd-shape and reachability checks need `dolt` on PATH; the script falls back to a warning + skip if `dolt` isn't installed, but the `gc rig add --adopt` call inside step 3 will then raise the underlying error itself.

## Variant: hand-pinned 4-file recipe (when you already know the project_id)

Midgard mayor produced a more direct variant when joining `sp` on `sol-mac-mini` — they had the `project_id` from prior work, so they skipped `ensure-project-id` and pinned all four config files by hand. The result is identical on-disk + on-server state; it just elides one command.

The four files that **must** agree (drift in any one → orders fail with `prefix mismatch`):

1. `<city>/city.toml` — declare the rig **with the prefix explicit**:

   ```toml
   [[rigs]]
   name = "synthpanel"
   prefix = "sp"
   includes = ["<absolute-path-to-shared-gastown-pack>"]
   ```

2. `<city>/.gc/site.toml` — path mapping:

   ```toml
   [[rig]]
   name = "synthpanel"
   path = "<absolute-path-to-local-rig>"
   ```

3. `<rig>/.beads/config.yaml` — pin **both** `issue_prefix` and `issue-prefix` (bd reads either, but supervisor reload can auto-detect from cwd basename and clobber one of them):

   ```yaml
   issue_prefix: sp
   issue-prefix: sp
   dolt.host: <shared dolt host>
   dolt.port: 16022
   dolt.auto-start: false
   gc.endpoint_origin: inherited_city
   gc.endpoint_status: unverified
   ```

4. `<rig>/.beads/metadata.json` — paste the canonical project_id:

   ```json
   {
     "backend": "dolt",
     "database": "dolt",
     "dolt_database": "sp",
     "dolt_mode": "server",
     "project_id": "<copy from city A's metadata.json>"
   }
   ```

`<city>/.beads/routes.jsonl` auto-registers `{"prefix":"sp","path":"rigs/synthpanel"}` once the prefix is declared.

**Hardening note from midgard's experience:** the supervisor's auto-detector can clobber `issue_prefix` when `config.yaml`'s mtime jumps (e.g. on dog-session spawn). If you see `prefix` drift mid-run, re-pin manually OR run:

```bash
gc dolt-config normalize-scope --dir <rig> --city <city> --prefix sp --dolt-database sp
```

This writes a canonical normalized config that the auto-detector won't fight.

**When to use which variant:**

- *Pinned-paste* (this section): you already have city A's `project_id` in hand and copy-paste-tolerant operators. Fewer commands, more discipline.
- *`ensure-project-id` flow* (recipe above): you want the join to work even when you don't know the `project_id` — the helper pulls it from the live DB. Better for automation / scripted onboarding.

Both produce identical state on disk and on the shared server.

The pinned-paste variant's mtime-clobber footgun (the "Hardening note" above) means the helper's pre-flight isn't enough on its own to keep a long-lived joined rig healthy — the auto-detector running on the live runtime can still mangle `issue_prefix`. `gc-rig-join` covers the join *moment*; `gc dolt-config normalize-scope` is the equivalent for steady-state.

## bd `metadata` table audit

`bd` stores per-database metadata in two tables:

- `metadata` — intended to be **shared** across all cities joined to the database. Wins all writes from any city.
- `local_metadata` — intended to be **per-host**. (Currently this table is also dolt-replicated, so writes from one city *do* land in the others — see "Open questions" below.)

A live audit against the shared dolt running on `mani-mac-mini.tail032ed9.ts.net:16022` (2026-04-28) found these rows:

| Database | `metadata` keys | `local_metadata` keys |
|---|---|---|
| `sp` (shared synth-panel) | `_project_id`, `clone_id`, `last_import_time`, `repo_id` | `bd_version` |
| `yg` | `_project_id`, `clone_id`, `last_import_time`, `repo_id` | `bd_version`, `tip_claude_setup_last_shown` |
| `mg` | `_project_id`, `clone_id`, `last_import_time`, `repo_id` | `bd_version`, `tip_claude_setup_last_shown` |
| `dgu` | `_project_id`, `repo_id` | `tip_claude_setup_last_shown` |
| `as` (asgard) | `_project_id` | (empty) |

Verdict per key:

| Key | Today | Should be | Notes |
|---|---|---|---|
| `_project_id` | `metadata` (shared) | shared ✓ | Project identity. Matches the design. |
| `repo_id` | `metadata` (shared) | shared ✓ | Project-level git-repo identity. Matches. |
| `clone_id` | `metadata` (shared) | per-host ✗ | Each clone of `bd` should have its own. Currently a city writing this clobbers what the other city wrote. (`yg` and `mg` show identical values today — likely just because one came up first and the other inherited from the dolt fetch — but conceptually wrong.) |
| `last_import_time` | `metadata` (shared) | per-host ✗ | Each city's `bd import` writes its own timestamp; the row from `yg` and `mg` clobber each other on every import. |
| `bd_version` | `local_metadata` | per-host ✓ | Correct. (But: even `local_metadata` is currently dolt-replicated, so per-host stripping needs schema-side support — the *intent* is right, the isolation isn't enforced.) |
| `tip_claude_setup_last_shown` | `local_metadata` | per-host ✓ | Correct intent; same caveat. |

The two misplaced keys (`clone_id`, `last_import_time`) are upstream `bd` schema bugs, not gc bugs. Filed as follow-up — see "Open questions" below.

## Verified working — single-host primitives (2026-04-28)

Re-verified against the live `sp` database on `127.0.0.1:16022`:

```
$ TMPDIR=$(mktemp -d /tmp/joinscan.XXXXX)
$ mkdir -p "$TMPDIR/.beads"
$ cat > "$TMPDIR/.beads/metadata.json" <<'EOF'
{ "backend":"dolt", "database":"dolt", "dolt_database":"sp", "dolt_mode":"server" }
EOF

$ gc dolt-state ensure-project-id \
    --metadata "$TMPDIR/.beads/metadata.json" \
    --host 127.0.0.1 --port 16022 --user root --database sp
project_id       gc-local-771a7e949f311dca91f9ebc4225e2de0
metadata_updated true
database_updated false
source           database

$ cat "$TMPDIR/.beads/metadata.json"
{
  "backend": "dolt",
  "database": "dolt",
  "dolt_database": "sp",
  "dolt_mode": "server",
  "project_id": "gc-local-771a7e949f311dca91f9ebc4225e2de0"
}
```

Confirms: the join primitive (`source: database`) still pulls the canonical `_project_id` from the shared dolt into a fresh stub `metadata.json`. This is the load-bearing piece that makes joining without forking identity possible.

The `gc-rig-join` helper's hardened pre-flight checks were also exercised live:

| Scenario | Result |
|---|---|
| `--prefix sp` (collides with already-registered `synth-panel`) | `prefix 'sp' already registered in this city by rig synth-panel` ✓ |
| `--prefix xx` (no such DB on server) | `database 'xx' does not exist on 127.0.0.1:16022 (… available: as dgu mg sp yg)` ✓ |
| `--port 9999` (unreachable) | `cannot reach dolt server at 127.0.0.1:9999 (user=root): … connection refused` ✓ |
| `--prefix bad-prefix` (hyphen) | `prefix 'bad-prefix' must not contain hyphens (conflicts with bead ID format)` ✓ |

What is **not** yet verified end-to-end:

- A second city standing up its own `.gc/site.toml` and registering `--adopt`, then having `bd list` from inside the joined path show beads created by city A. Requires either a sandbox city on this same host (`gc init /tmp/test-city-b`) or the live yg ↔ mg run.
- Cross-rig sling routing across cities once both have a local rig with the same prefix — predicted to "just work" since the cross-rig guard finds a local rig with the matching prefix on each side, but unverified.
- Identity-mismatch recovery (a second city accidentally ran `gc rig add` without `--adopt` and minted a fresh `project_id`). The proposed recovery is `rm -rf .beads/` + re-run `gc-rig-join`. The "no orphan rows" claim in particular is unverified — there's nothing left in `metadata.json` after the rm, but the misregistered `[[rig]]` entry in `.gc/site.toml` from the bad `gc rig add` may need a `gc rig remove` to clean up before re-joining can register without a name collision.

These are the deliverables of `dgu-2ro` that need a coordinated yg ↔ mg run to validate. The bd-schema audit row above can be acted on without that coordination.

## Cleaning up the midgard `sy` orphan

**Status: resolved 2026-04-28.** Yggdrasil mayor verified the `sy` database on the shared dolt server was empty (0 issues, 0 wisps) and dropped it via direct SQL. Midgard had already pivoted its rig declaration to `prefix = "sp"`, so no rig referenced `sy` from either side.

The general cleanup pattern (when an orphan does have content you want to keep, OR when you'd rather use the supported tooling):

```bash
# 1. Drop the bad rig registration in the city that created the orphan
gc rig remove <name>            # whatever name the orphan rig used; check with `gc rig list`

# 2. Garbage-collect the now-orphaned database
gc dolt cleanup                 # finds the orphan, prompts to drop it
```

`gc dolt cleanup` only removes databases that are not referenced by *any* `[[rig]]` in the city's site.toml.

For the empty-orphan shortcut taken here:

```bash
# Verify empty first
DOLT_CLI_PASSWORD="" dolt --host 127.0.0.1 --port 16022 --user root --no-tls --use-db <orphan> sql -q \
  "SELECT 'issues', COUNT(*) FROM issues UNION ALL SELECT 'wisps', COUNT(*) FROM wisps"

# If both 0, drop directly (use backticks if the prefix is a SQL reserved word)
DOLT_CLI_PASSWORD="" dolt --host 127.0.0.1 --port 16022 --user root --no-tls sql -q "DROP DATABASE \`<orphan>\`"
```

## Test plan

What's validated, what's not:

| Step | Status |
|---|---|
| Each command tested live against the running shared dolt | ✓ (initial doc + re-verified 2026-04-28) |
| `ensure-project-id --source database` pulls canonical id into stub `metadata.json` | ✓ (re-verified, see "Verified working" above) |
| `gc-rig-join` pre-flight: collision / unreachable / missing-DB / bad-prefix all surface clean errors | ✓ (re-verified) |
| Stand up a sandbox `.gc/site.toml` for "city B" and run the recipe through `gc rig add --adopt` | pending (needs `gc init /tmp/test-city-b`) |
| `bd list` from city B shows beads created by city A | pending (gated on previous row) |
| Sling a bead from each side; cross-rig guard does not fire | pending |
| Identity-mismatch recovery (`rm -rf .beads/` + re-join after a bad `gc rig add`) | pending |
| Live yg ↔ mg pair after cleaning up `sy` orphan on mg | pending (gated on mg-side cleanup) |

## Open questions / future work

- **`gc rig join` proper.** The shell helper is a stopgap. Upstream-worthy: a real subcommand that wraps the steps, runs the same pre-flight checks (now in the shell helper) at the gc level, and ideally lets the city's site.toml host/port defaults bubble up so callers don't have to repeat them. Tracked under `dgu-2ro` deliverable 4 (out of scope for this rig — needs upstream `gc` source changes).
- **Identity mismatch recovery.** If a second city accidentally ran `gc rig add` (no `--adopt`) and minted its own `project_id`, the resulting metadata is now divergent from the shared DB. The proposed fix — `rm -rf .beads/` + re-run the join recipe — leaves the misregistered `[[rig]]` entry in `.gc/site.toml` behind, which may need a `gc rig remove` first to avoid a name conflict on re-add. Needs a live exercise to confirm exact recovery sequence.
- **`bd` schema split between `metadata` and `local_metadata`.** The "bd `metadata` table audit" section above identifies `clone_id` and `last_import_time` as misplaced — they're in the shared `metadata` table but conceptually per-host. A `bd import` on one city writes its timestamp; the next `bd import` on another city overwrites it. Worth a bead on the upstream `bd` repo to move these to `local_metadata` (and to make `local_metadata` actually local — see next bullet).
- **`local_metadata` is not actually local.** Despite the name, dolt replicates `local_metadata` along with everything else. So `bd_version` from one city overwrites the other on push/pull. The fix probably needs either a per-host filter at the `bd push`/`bd pull` boundary, or a `localonly_metadata` / `__hostname__` partition key inside the table. Filed-worthy.
- **Refinery coordination across cities.** Two refineries draining the same queue should be fine (they atomic-claim too) but we haven't stress-tested it. Worth filing once the basic join works.
- **Worktree path collisions.** Each city manages its own `.gc/worktrees/<rig>/<polecat>/` so this should be safe by construction, but worth confirming that the work-bead `metadata.work_dir` is interpreted per-host (it's an absolute path, so the witness on city B wouldn't try to clean a path written by city A).

## References

- `gc rig add --help`, `gc rig set-endpoint --help`, `gc dolt-state ensure-project-id --help`
- Live yg city: `/Users/mani/yggdrasil/.gc/site.toml`, `/Users/mani/SynthPanel/.beads/{config.yaml,metadata.json}`
- Shared dolt config: `/Users/mani/yggdrasil/.gc/runtime/packs/dolt/dolt-config.yaml` (port 16022, listens on `0.0.0.0`)
- `gc dolt list` shows the per-prefix databases on the shared server
- Related docs: `docs/multi-city-shared-dolt.md` (city-level shared dolt), `docs/cross-city-comms.md` (mail/nudge plumbing)
