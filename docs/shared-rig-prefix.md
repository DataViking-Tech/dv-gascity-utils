# Shared Rig Prefix Across Cities (Open Problem)

> **Status:** investigation needed. Polecat: turn this into a design doc + propose an implementation, then file a follow-up bead for the implementation work.

## The problem we hit

Both yggdrasil (on `mani-mac-mini`) and midgard (on `sol-mac-mini`) need to work on the same project — `SynthPanel` — at the same time. The user's training-session goal is *multiple cities, one shared work pool*: polecats from any city pull from the same beads database, push to the same git repo, refinery-merge to the same base branch.

What actually happened:
- Yggdrasil: `gc rig add /Users/mani/SynthPanel --name synth-panel` → prefix `sp`, created database `sp` on the shared dolt server.
- Midgard: `gc rig add /Users/openclaw/midgard/rigs/synthpanel --include gastown` → prefix `sy`, created a SEPARATE database `sy` on the shared dolt server.
- Now there are two unrelated bead pools (`sp.issues`, `sy.issues`) for the same logical project. Polecats on each side work in isolation. Cross-city coordination is impossible because the `sp` ↔ `sy` namespaces don't connect.

## What the user wants

- **One logical bd database per project** (e.g. `sp`).
- **Each city has its own rig directory** (each polecat needs a local worktree on its host).
- All cities' rigs **point at the same `sp` database** — work pool is shared.
- `gc rig add` on a "second" city should JOIN the existing rig, not create a duplicate.

## Design constraints (verified)

- `bd init --prefix sp` — works to create a new project's DB
- `bd bootstrap` — exists for cloning an existing remote (mentioned in error messages)
- `gc rig add --adopt` — exists to register a directory that already has a populated `.beads/` config (skips beads init)
- `gc rig add --prefix <p>` — explicit prefix override
- `gc beads city use-external` — points a city at the shared dolt server (we use this for cities; should also work for rigs)

## Likely shape of the fix

(Polecat: validate and refine.)
1. **First city** sets up the rig as today: `gc rig add <path>` → prefix derived, `<prefix>` database created on shared server, populated with bd schema + `issue_prefix` config row.
2. **Second city** runs something like:
   ```
   gc rig join <local-path> --prefix sp --shared-dolt
   ```
   Which:
   - Creates `<local-path>/.beads/` config pointing at the existing `sp` database on the shared server (no `bd init`)
   - Registers the rig in city.toml + site.toml with `--prefix sp`
   - Skips schema creation (already there)
   - Hooks up cross-rig routing
3. Or, if there's no `gc rig join`, document the manual recipe:
   - `mkdir -p <local-path>/.beads`
   - Write metadata.json + config.yaml manually pointing at shared dolt + prefix sp
   - `gc rig add <local-path> --name synth-panel --prefix sp --adopt`

## What to investigate

- Does `gc rig add --adopt --prefix sp <path>` work if `<path>/.beads/` is hand-crafted to point at the shared DB?
- Is there an undocumented `gc rig join` or `gc beads rig adopt` command?
- How does the cross-rig guard handle this? (The dispatch skill mentioned a sling-time check based on bead-prefix.)
- What does the second city's site.toml [[rig]] entry need to look like?
- For polecats from different hosts working the same rig: do they conflict on the worktree? (Each city has its OWN worktree dir under `.gc/worktrees/synth-panel/<polecat>/` — should be fine.)

## Cleanup needed before testing

- Drop midgard's `sy` rig: `gc rig remove synth-panel` from midgard's side, then `gc dolt cleanup` to drop the orphan `sy` database from the shared server.
- Then re-run the join sequence with whatever pattern this doc lands on.

## Output

Polecat should produce:
- This doc, fleshed out with the working recipe.
- A `gc rig join`-equivalent shell helper if no upstream command exists.
- A test sequence: stand up sp on yg, join from mg, sling a bead from each, verify both polecat pools see it.
