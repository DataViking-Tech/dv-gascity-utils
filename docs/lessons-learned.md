# Lessons learned — multi-city Gas City build

> Distilled from the live yggdrasil/asgard/midgard scaffold (2026-04-27 → 2026-04-28). Read this when something feels off and you suspect it's a known shape.

The `docs/SETUP-GUIDE.md` shows what works. This doc explains *why* the working shape is what it is — what we tried that failed, what surprised us, and where the seams are.

## A. Pack discovery

**Empty `agents/` and `formulas/` dirs are required for `orders/` to load.**

Symptom: a pack ships only `orders/` (e.g. `gascity-comms` originally just had `mail-nudge.toml`), and `gc reload` reports the pack imported but no orders ever tick. No error. The supervisor silently skips `orders/` if `agents/` or `formulas/` aren't present in the pack root.

Fix:

```bash
mkdir -p <CITY>/.gc/system/packs/<pack>/agents
mkdir -p <CITY>/.gc/system/packs/<pack>/formulas
gc reload
```

This is upstream supervisor behavior — touch the directories and the discover walk completes.

## B. bd init gotchas

**`issue_prefix` config row not seeded against shared dolt.**

`bd init` reliably seeds `issue_prefix` in embedded mode. Against an external (shared) dolt server, the row sometimes comes up missing. Without it, `bd` cannot mint new bead IDs and every operation fails with `issue_prefix config is missing`.

Fix (manual, after creating the database):

```bash
gc --city <canonical> dolt sql -q "USE \`<prefix>\`; \
  INSERT INTO config VALUES('issue_prefix','<prefix>'); \
  CALL DOLT_COMMIT('-Am','seed issue_prefix');"
```

Treat this as a required step when adopting any new prefix on a shared server. Spot-check after with `SELECT * FROM config`.

**Reserved-word prefixes need backticks in raw SQL.**

These prefixes collide with SQL reserved words: `as`, `is`, `or`, `to`, `in`, `on`. `gc` and `bd` quote them correctly internally, but any ad-hoc SQL — `USE`, `CREATE DATABASE`, `DROP DATABASE`, manual seeds — must use backticks:

```sql
USE `as`;
CREATE DATABASE `as`;
```

`sp`, `tc`, `tr`, `dgu` and most other prefixes are fine without quoting. Easy to forget when you're typing fast against a wedged system.

## C. Agent name resolution: short form vs. full form

**The reconciler matches `<rig>/gastown.<role>`. Several call-sites used `<rig>/<role>`.**

Where it surfaces: `internal/.../namedWorkReady` checks bead `assignee` against the **full template name** (e.g. `dv-gascity-utils/gastown.refinery`). The polecat done-sequence and several prompt-template fragments wrote the **short form** (`<rig>/refinery`, `<rig>/polecat`, etc.). Result: `work_requested` stays false, the on-demand session never wakes, polecat branches sit unmerged.

How to detect at runtime:

- `gc status` shows the slot stuck at `reserved-unmaterialized (on_demand)`.
- `<CITY>/.gc/runtime/supervisor.log` shows `poolDesired` lines that don't match the bead stream.
- `gc bd list --status=open --assignee="<rig>/<role>"` returns work, but `gc bd list --status=open --assignee="<rig>/gastown.<role>"` returns nothing — the bead is filed under the short form, the reconciler is querying the full form.

Manual workaround (verified live): `gc session wake <rig>/gastown.<role>` materializes the slot correctly. Long-term fix: align every call-site to the full form. Tracked: `dgu-3u9` (root-cause writeup, in `docs/refinery-materialization.md`), `dgu-fze` (the `gc-fix-refinery-routing` helper, polecat→refinery direction), `dgu-wrdjs` (sister fix: refinery rejection bounce also wrote the short form, masked rejected branches).

The helper rewrites the four offending files in `<CITY>/.gc/system/packs/gastown/`:

- `formulas/mol-polecat-work.toml` (polecat done-sequence)
- `agents/polecat/prompt.template.md` (one-line FINAL REMINDER)
- `template-fragments/approval-fallacy.template.md` (matching note in shared fragment)
- `formulas/mol-refinery-patrol.toml` (rebase-conflict bounce, added by `dgu-wrdjs`)

It's idempotent. Re-running on a fixed pack reports already-fixed for each.

## D. Reconciler latency on first claim

**On-demand polecat/refinery materialization can take 10–20 minutes between sling and first claim.**

We watched `gc bd ready` return work, the slot stay at `reserved-unmaterialized`, and the polecat eventually wake on the next reconciler tick. The latency is fine for steady-state agent flows but ugly for demos and new-rig setup.

Workaround today (manual): `gc session new <rig>/gastown.polecat --alias <slot> --no-attach`, which kicks the reconciler.

Proper fix: bump `min_active_sessions=1` for the rig-scoped polecat agent so one slot stays warm. Schema location for that patch on rig-scoped agents is currently unknown (workspace `[[patches.agent]]` rejects with "agent polecat not found in merged config"; `[[defaults.rig.patches.agent]]` rejects with `unknown field`). Tracked: `dgu-m72nk`.

**`stopped` in `gc status` is misleading for ephemeral pools.** It means "no live session right now," not "broken." Polecats are designed to come up only when there's work.

## E. Interactive-mayor autonomy gap

**Claude Code interactive sessions do not translate queued nudges into new turns.**

The structural problem (covered in `docs/cross-city-comms.md` Limitations):

- The `mail-nudge` order ticks every 20 s and nudges the local recipient session if `unread > prev_seen`.
- The `UserPromptSubmit` hook on each user turn surfaces unread mail in `<system-reminder>` and **marks read**.

If the user types a prompt before the next 20 s tick, `unread` is back to 0 — the order sees no growth, no nudge fires. Net effect: an idle interactive mayor isn't autonomously woken. They *will* see mail on their next turn, but only if a turn happens.

This works fine for agent sessions (deacons, witnesses, polecats) that run in a work-loop and consume nudge text directly into the next iteration.

Mitigation: when a cross-city thread heats up, the human kicks off `/loop` once with adaptive `ScheduleWakeup` (e.g. 60 s tight while active, 15 min relaxed when quiet, exit on close). One gesture per thread, then autonomous until the thread closes. Tracked: `dgu-yxb8`.

The proper fix is supervisor-level: a "wake into a new turn" primitive that mounts the recipient agent for a turn instead of just queuing nudge text against an existing one. Out of scope for this pack.

## F. Branch protection + merge strategy

**Polecat default is direct-merge to base branch. PR-protected rigs reject with GH013.**

What happens: polecat finishes work, pushes branch, refinery rebases onto main, attempts `git push origin main` — GitHub returns `GH013 Push declined due to repository rule violations` because the rig's `main` branch requires PR review.

Refinery escalates as `blocked` and the mayor opens the PR by hand. We hit this on `traitprint-cloud` (`tc-6s0`, `tc-0s6`) before the fix landed.

Fix landed as `gc-fix-merge-strategy` (`dgu-26ptn`). The helper patches the per-host gastown system pack so the polecat's submit-and-exit step resolves `merge_strategy` in order: existing metadata > per-rig `.gc-merge-strategy` override > `gh api branches/<target> --jq '.protected'` > fallback `direct`. Once `mr`, the refinery opens a PR via `gh pr create` instead of direct-pushing. Full writeup in `docs/rig-merge-strategy.md`.

Companion fix `dgu-yrnmv` ships the `pr-ci-watch` order, which closes the loop on the PR side: tracks `merge_result=pull_request` and `merge_result=blocked` beads, auto-reslings the polecat on CI failure (preserving `existing_pr` so the same PR is reused, not a new one), bails to mayor at `resling_count >= 3`.

## G. Supervisor wedge / bd wedge

**`bd` CLI broad-list queries can hang for hours holding the dolt connection pool.**

We watched `bd list --status=open --json --limit=0` (no limit) hang for 1h42m on midgard. Symptom on the calling side: any further `bd` or `gc bd` invocation also hangs. Symptom on the recipient side (when this is invoked from cross-city mail): `gcx mail send … -s … -m …` returns HTTP 500 `bd create timed out`.

Diagnostic (mg mayor's primitive — works on any host):

```bash
ps -A -o pid,etime,command | grep '/bin/bd'
```

Look for a `bd` PID with a long `etime`. That's the holder. Recovery:

```bash
kill <pid>
```

The supervisor recovers without restart. The dolt connection pool releases.

**Don't run `bd list` against a remote endpoint without `--limit`.** Always cap at a reasonable number (e.g. `--limit 50`) and add `--timeout` if the subcommand supports it. For broader queries that legitimately need everything, run on the canonical host directly and pipe through `head` or `jq`.

## H. Gateway endpoints don't cover nudge

**`gc nudge` is over the controller's local Unix socket, not the supervisor's HTTP API.**

This is by design (it's a local-only primitive), but it has a real consequence: cross-host nudge from the sender side is impossible. You can `POST /v0/city/<peer>/mail` to deliver a wisp, but you can't `POST /v0/city/<peer>/nudge` to wake the recipient.

The fix is the per-city `mail-nudge` order, which runs on the recipient's controller and watches its own city's wisp counts. Every host that wants its agents to wake on incoming mail must have the order running locally. There is no centralized "wake host B from host A" path.

## I. Sling routes / wisp assignees / don't meddle

**Direct SQL `UPDATE` on a bead's assignee while a polecat is mid-claim races and may overwrite the polecat's claim.**

We learned this the hard way 2026-04-28: a mayor SQL session ran `UPDATE issues SET assignee = 'x' WHERE id = …` on a bead the `tc-6s0` polecat was actively claiming. The polecat's claim got clobbered mid-merge; the bead ended up assigned to nobody and the merge stalled.

Rule: do not edit live bead state via raw SQL without first confirming no session is mid-flight. The `bd update --claim` path is dolt-transaction-safe and atomic — use it. If you must run raw SQL, check `gc status` for any session whose alias matches the bead's current assignee, and prefer waiting for the session to drain.

## J. Pack distribution

**Manual rsync requires SSHd running (often disabled).** macOS's Remote Login is off by default. Enabling it for every host adds attack surface. Base64-encoded over mail works ad-hoc but doesn't scale.

The right answer is `gc pack add <git-url>`, which is now the supported path for `dv-gascity-utils` (it's on github main). Per-host:

```bash
gc pack add https://github.com/DataViking-Tech/dv-gascity-utils
```

Tokens still have to be ferried out-of-band — those are per-host secrets and can't live in a pack. Treat token distribution as a separate manual step every time you onboard a new host.

## Cross-references

- `docs/SETUP-GUIDE.md` — the working scaffold these lessons came from
- `docs/diagnostic-runbook.md` — symptom-first recovery recipes for the failures above
- `docs/cross-city-comms.md` — Caddy gateway + peers.toml + gcx detail
- `docs/multi-city-shared-dolt.md` — shared-dolt pattern, asgard migration recipe
- `docs/shared-rig-prefix.md` — joining a shared rig from a second city

## Beads filed during the build

These captured findings during the live scaffold and are useful as historical context:

| Bead | What it covers | Status |
|---|---|---|
| `dgu-3u9` | Refinery on-demand spawn root cause — short-form vs. full-form name mismatch | docs landed (`refinery-materialization.md`) |
| `dgu-fze` | `gc-fix-refinery-routing` helper (polecat→refinery direction) | landed |
| `dgu-wrdjs` | `gc-fix-refinery-routing` extension — also patches refinery rejection bounce | landed |
| `dgu-yxb8` | Default collaborative-loop suggestion in mayor prompt + `/loop-suggest` protocol | branch open (`polecat/dgu-yxb8`), awaiting merge |
| `dgu-rxrzq` | Durable city-prime template fragment for new mayor sessions | branch open (`polecat/dgu-rxrzq`), awaiting merge |
| `dgu-m72nk` | Find schema-valid path for rig-scoped agent `min_active_sessions` | open |
| `dgu-26ptn` | Default `merge_strategy=mr` for PR-protected rigs (`gc-fix-merge-strategy` helper) | landed |
| `dgu-yrnmv` | `pr-ci-watch` order — autonomous resling on CI failure for PR-protected rigs | landed |

Check `gc bd show <id>` for the latest status before quoting conclusions; this table is a snapshot.
