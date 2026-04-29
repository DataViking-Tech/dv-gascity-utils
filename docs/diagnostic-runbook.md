# Diagnostic runbook

Recovery recipes and operational guidance for Gas City deployments. This
document is a stub: dgu-3lsfj is producing the full runbook in parallel.
Anything dgu-3lsfj adds layers on top of the sections below.

## PR autonomy

Closes the merge loop on PR-protected rigs. Without this, a polecat's branch
sits unmerged forever once GitHub branch protection forces a PR — CI runs,
fails or passes, and nothing autonomous reacts.

### What ships

`packs/gascity-comms/orders/pr-ci-watch.toml` — cooldown order, 5 min
interval. Calls `assets/scripts/pr-ci-watch.sh`. No agent, no LLM, no wisp.

### When the watcher engages

Two bead populations:

1. **Refinery mr-mode handoff.** When a polecat sets `merge_strategy=mr` (or
   provides `existing_pr`), the refinery rebases, pushes, validates the PR,
   then closes the bead with `metadata.merge_result=pull_request` and
   `metadata.pr_url=<url>`. The watcher tracks closed beads in this state.

2. **Blocked direct-merge.** When a polecat used the default `direct`
   strategy and the refinery's push hits branch protection (GH013), the
   refinery sets `metadata.merge_result=blocked`, sets `gc.routed_to=human`,
   and bails to mayor. A human (mayor or operator) opens the PR manually.
   The watcher finds these via `merge_result=blocked` + `metadata.branch`,
   discovers the PR with `gh pr list --head <branch>`, and writes
   `metadata.pr_url` for next cycle.

### Per-cycle behaviour

For each tracked bead:

| PR state                  | Action                                                                                                        |
|---------------------------|---------------------------------------------------------------------------------------------------------------|
| `MERGED`                  | `merge_result=merged_external`, record `merged_sha`. Stop tracking.                                          |
| `CLOSED` (not merged)     | `merge_result=closed_without_merge`. Stop tracking.                                                           |
| `OPEN` + checks pass      | `ci_status=passed`. Leave alone — humans merge.                                                               |
| `OPEN` + checks fail/cancel| Resling: reopen bead, set `rejection_reason=CI failed: <names>`, set `existing_pr=<url>`, route to `<rig>/gastown.polecat`, increment `resling_count`. |
| `OPEN` + checks pending   | No-op this cycle.                                                                                             |
| `OPEN` + no checks defined| `ci_status=no_checks`. Leave alone.                                                                           |

The polecat that picks up the reslung bead sees `metadata.branch` and
`metadata.rejection_reason`, resumes the existing branch via the
`mol-polecat-work` workspace-setup step (rebases on main, fixes the failing
checks, pushes). The bead retains `existing_pr`, so on resubmission the
refinery's mr-mode reuses the same PR — push the rebased branch back with
`--force-with-lease`, validate, close the bead again. CI re-runs on the new
commits and the watcher resumes monitoring.

### Resling cap

`metadata.resling_count >= MAX_RESLINGS` (default 3, env override
`PR_CI_WATCH_MAX_RESLINGS`) means the watcher stops reslinging and mails
mayor with `ESCALATION: PR-CI resling cap reached for <bead> [HIGH]`. The
bead's `ci_status=failed_max_reslings` records the terminal state. A human
either fixes the bead manually, raises the cap, or closes the PR.

### What the watcher will NOT do

- **Auto-merge on green CI.** Branch protection is intentional for
  human-facing repos; humans (or downstream tooling) decide when to merge.
- **Bypass branch protection.** No `--admin` flag, no force-merges.
- **Ship gh credentials.** Per-host `gh auth login` is the contract.

### Required preconditions

- `gh` CLI installed and authenticated on the host running the city
  (`gh auth status` exits 0).
- `jq` available.
- The rig's repo has a GitHub remote at `origin` (parsed via
  `git -C <rig-path> remote get-url origin`).

When any precondition is missing the watcher exits silently with status 0
so the cooldown order doesn't generate noise.

### Recovery recipes

- **Stuck at the cap.** Inspect with
  `bd show <bead> --json | jq '.[0].metadata'`; either fix the failing
  checks manually on the branch, then run
  `bd update <bead> --unset-metadata resling_count` to let the watcher
  retry, or close the PR and let the watcher mark
  `merge_result=closed_without_merge`.
- **Watcher tracking the wrong PR.** This happens if a stale `pr_url` was
  cached. Run `bd update <bead> --unset-metadata pr_url` and let the next
  cycle re-discover via the branch.
- **Watcher not running.** Check the order is loaded:
  `gc config show | grep -A 2 pr-ci-watch`. The pack root must contain
  `agents/` and `formulas/` directories (even empty) for the supervisor to
  scan `orders/`. Check
  `ls /path/to/packs/gascity-comms/{agents,formulas} 2>/dev/null`.
- **Resling forwards to the wrong rig.** The watcher derives the rig from
  the bead-id prefix via each rig's `.beads/metadata.json#dolt_database`.
  If a rig is missing that file, the watcher silently skips its beads.
  Rerun `bd init` in the rig if needed.

## Agent spawn watchdog

Backstop for the supervisor's `poolDesired → scaleCheck → session.create`
path when it silently skips a spawn despite queued work. Pairs with
`min_active_sessions = 1` warm slots applied via
`packs/gascity-comms/assets/scripts/gc-warm-rig-pool`. Full architecture
notes: [`agent-watchdog.md`](agent-watchdog.md).

### Verifying the watchdog is loaded

```bash
gc config show | grep -A 3 'name = "agent-watchdog"'
# expected: trigger = "cooldown", interval = "30s"
```

### Manual one-shot run

The watchdog script is safe to invoke directly. It exits silently if
nothing is queued.

```bash
bash packs/gascity-comms/assets/scripts/agent-watchdog.sh
# Output (empty if all rigs have live sessions for queued work)
```

To see what it considers per template, set the recent-cutoff low so the
race guard never fires, then watch the queued/live decision:

```bash
AGENT_WATCHDOG_RECENT_CUTOFF=0 \
  bash -x packs/gascity-comms/assets/scripts/agent-watchdog.sh 2>&1 \
  | grep -E '(queued|live|spawn|recent)'
```

### Test sequence: confirm spawn-on-empty-queue+0-live

This proves the watchdog respawns a stalled rig within one cooldown tick
(~30s). It is disruptive — it kills live sessions in the target rig.
Run when the rig is otherwise idle and you can tolerate a brief gap.

1. **Pick a target rig.** Use a low-traffic rig (not the one running
   this session). Example: `synth-panel`.

   ```bash
   RIG=synth-panel
   ```

2. **Snapshot baseline.**

   ```bash
   gc session list --state=active --template "$RIG/gastown.polecat" --json | jq 'length'
   gc session list --state=active --template "$RIG/gastown.refinery" --json | jq 'length'
   ```

3. **Queue a no-op bead for the polecat pool** (so the watchdog has a
   reason to spawn after the kill — without queued work, the warm slot
   itself is what gets re-spawned by the reconciler, not the watchdog):

   ```bash
   BEAD=$(bd create --title "watchdog test no-op" --type chore --priority 3 \
     --json | jq -r '.id')
   bd update "$BEAD" --set-metadata "gc.routed_to=$RIG/gastown.polecat" --status=open
   ```

4. **Kill all live polecat + refinery sessions in the rig.**

   ```bash
   for tpl in polecat refinery; do
       gc session list --state=active --template "$RIG/gastown.$tpl" --json \
         | jq -r '.[].Alias' \
         | xargs -I{} gc session kill {} --force
   done
   ```

5. **Wait one cooldown tick (35s) and observe the watchdog log.**

   ```bash
   sleep 35
   gc orders log agent-watchdog --tail 20
   # expect: "agent-watchdog: spawn $RIG/gastown.polecat (queued=1, live=0)"
   ```

6. **Confirm the session came back.**

   ```bash
   gc session list --state=active --template "$RIG/gastown.polecat" --json | jq 'length'
   # expect: 1
   ```

7. **Clean up the no-op bead.**

   ```bash
   bd update "$BEAD" --status=closed --notes "watchdog test complete"
   ```

If step 5 shows no spawn line, common causes:

| Symptom                                   | Likely cause / fix                                                    |
|-------------------------------------------|-----------------------------------------------------------------------|
| `recently_created>0` skip                 | Reconciler beat the watchdog. Lower `AGENT_WATCHDOG_RECENT_CUTOFF=0` and re-run. |
| `live>0` skip                             | A reaper missed; check `gc session list --state=all` for stale beads. |
| Order didn't fire                         | Confirm with `gc orders status agent-watchdog` and check `gc reload`. |
| `spawn failed for $RIG/gastown.polecat`   | Run `gc session new $RIG/gastown.polecat --no-attach` manually to surface the underlying error. |

### Verifying warm-pool overrides

```bash
gc config explain --agent polecat --rig <rig> | grep min_active_sessions
# Expected after gc-warm-rig-pool: min_active_sessions = 1  # city.toml
```

If the line says `# pack` instead of `# city.toml`, the override didn't
land — re-run `gc-warm-rig-pool --dry-run <city.toml>` to see what would
have changed.
