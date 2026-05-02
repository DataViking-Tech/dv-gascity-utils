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
| Settling guard skip (no log line)         | The heartbeat is younger than `RECENT_CUTOFF_SECONDS`. Wait for it to age past the cutoff or remove `$GC_CITY_RUNTIME_DIR/agent-watchdog/<rig>__gastown.<tpl>.last_seen_live` and rerun. |
| `live>0` skip                             | A reaper missed; check `gc session list --state=all` for stale beads. |
| Order didn't fire                         | Confirm with `gc orders status agent-watchdog` and check `gc reload`. |
| `spawn failed for $RIG/gastown.polecat`   | Run `gc session new $RIG/gastown.polecat --no-attach` manually to surface the underlying error. |

### Test sequence: confirm only ONE spawn in the recovery window

This validates the over-spawn fix — when both `min_active=1` and the
watchdog could fire, exactly one session should come back per template.
Disruptive: kills all sessions in the target rig.

1. **Pick a low-traffic rig and confirm warm pool is on.**

   ```bash
   RIG=synth-panel
   gc config explain --agent polecat --rig "$RIG" | grep min_active_sessions
   # expected: min_active_sessions = 1  # city.toml
   ```

2. **Note the heartbeat state for both templates.** The recovery
   path relies on the heartbeat being recent at kill time.

   ```bash
   ls -la "${GC_CITY_RUNTIME_DIR}/agent-watchdog/${RIG}__gastown.polecat.last_seen_live"
   ls -la "${GC_CITY_RUNTIME_DIR}/agent-watchdog/${RIG}__gastown.refinery.last_seen_live"
   ```

3. **Queue a no-op bead so the watchdog has a reason to fire.**

   ```bash
   BEAD=$(bd create --title "watchdog over-spawn test" --type chore --priority 3 \
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
   START=$(date +%s)
   ```

5. **Wait through the recovery window (~2 min).** The reconciler's
   `min_active=1` should backfill within ~30-60s; the watchdog's
   settling guard should defer until the heartbeat ages out (90s).

   ```bash
   sleep 120
   ```

6. **Confirm exactly one session came back per template.**

   ```bash
   gc session list --state=all --template "$RIG/gastown.polecat" --json \
     | jq --argjson start "$START" '[.[] | select((.CreatedAt | fromdateiso8601) >= $start)] | length'
   # expect: 1
   gc session list --state=all --template "$RIG/gastown.refinery" --json \
     | jq --argjson start "$START" '[.[] | select((.CreatedAt | fromdateiso8601) >= $start)] | length'
   # expect: 1
   ```

7. **Confirm the watchdog deferred to the reconciler.** With
   `min_active=1` and the heartbeat fresh at kill time, the watchdog
   should not have spawned anything in the recovery window.

   ```bash
   gc orders log agent-watchdog --tail 50 \
     | grep "agent-watchdog: spawn $RIG" \
     | wc -l
   # expect: 0  (reconciler's min_active backfill ran instead)
   ```

   If this shows >0, either the heartbeat aged past the cutoff before
   the reconciler spawned, or the reconciler is genuinely broken and
   the watchdog correctly stepped in.

8. **Clean up.**

   ```bash
   bd update "$BEAD" --status=closed --notes "over-spawn test complete"
   ```

If step 6 shows >1 session, the settling guard isn't working. Check
that the heartbeat file existed at kill time (step 2) and that
`AGENT_WATCHDOG_RECENT_CUTOFF` is at least 90s.

### Verifying warm-pool overrides

```bash
gc config explain --agent polecat --rig <rig> | grep min_active_sessions
# Expected after gc-warm-rig-pool: min_active_sessions = 1  # city.toml
```

If the line says `# pack` instead of `# city.toml`, the override didn't
land — re-run `gc-warm-rig-pool --dry-run <city.toml>` to see what would
have changed.

## Supervisor restart — caveats and workaround

This section captures behavior observed on yggdrasil 2026-04-29 while
diagnosing `mg-pfh96` / `dgu-pfh96` (dolt/orders/* dog orders permanently
stuck after bd-error during dispatch).

### When you'd reach for a restart

The supervisor accumulates per-order broken-state guards when `bd create`
or `bd list` fails during order dispatch (transient dolt connection EOF
or circuit-breaker trip). Once flagged, that order never re-fires until
the supervisor process restarts. Common symptom:

- `mol-dog-doctor` (5m cadence) silent for hours/days while the dolt
  server is healthy and the pool/poolDesired routing checks out.
- `grep order.fired events.jsonl | grep mol-dog-doctor` shows no recent
  fires; `grep mol-dog-doctor supervisor.log` shows old `bd create: exit
  status 1` entries from one specific time window, then nothing.
- mol-dog-jsonl + mol-dog-reaper (different pack family) keep firing
  through the same window.

A controlled supervisor restart unsticks every flagged order for **exactly
one fire each**. They re-stick on the next bd-error. Documented as a
Class C (gc binary) bug; no config-level fix until the binary stops
persisting broken-state across cooldown ticks.

### The "stop is broken" caveat

`gc supervisor stop` may return `Supervisor stopping...` and then fail to
actually stop the daemon. Observed on yg: a supervisor running 1d 19h
with 944 min of accumulated CPU time **ignored SIGTERM entirely** — both
via `gc supervisor stop` and direct `kill <pid>`. Twenty seconds of
waiting saw no exit. Cause unknown but the workaround is reliable:
SIGKILL.

### Safe restart sequence

The sequence below is the manual recipe. `gc-reload-orders` packages it
into a single command (with `--dry-run`) for the order/override-reload
case — see `docs/known-binary-bugs.md` "supervisor reload doesn't
refresh order dispatch tables". Use the manual recipe when you need
case-by-case visibility (e.g. mol-dog-doctor unwedge runs where you want
to time each phase).

```bash
# 1. Capture pre-state.
SUPERVISOR_PID=$(pgrep -f 'gc supervisor run' | head -1)
echo "supervisor: PID=$SUPERVISOR_PID"
ps -o pid,etime,command -p $SUPERVISOR_PID

# 2. Try graceful stop first. Watch for actual exit, don't trust the
#    return message.
gc supervisor stop
for i in 1 2 3 4 5; do
    sleep 3
    if ! kill -0 $SUPERVISOR_PID 2>/dev/null; then
        echo "graceful stop completed"
        break
    fi
done

# 3. If still alive after ~15s, escalate.
if kill -0 $SUPERVISOR_PID 2>/dev/null; then
    echo "graceful stop ignored; sending SIGKILL"
    kill -9 $SUPERVISOR_PID
    sleep 3
fi

# 4. Verify launchd brought up a new supervisor.
launchctl list | grep gascity.supervisor
# expect: <new-pid>  0  com.gascity.supervisor

# 5. If launchctl shows '-' for the PID (failed) or no entry at all,
#    re-bootstrap. Observed on yg: the failed `gc supervisor stop`
#    drifted launchd's view of the service to "registered but not
#    running"; the next bootstrap call attempted to start a second
#    supervisor that couldn't bind port 8372 because the orphan was
#    still holding it.
if [ -z "$(launchctl list | awk '/com\.gascity\.supervisor/ && $1 ~ /^[0-9]+$/{print $1}')" ]; then
    launchctl bootout gui/$(id -u)/com.gascity.supervisor 2>/dev/null
    launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.gascity.supervisor.plist
fi

# 6. Confirm new supervisor is alive and serving.
gc supervisor status
lsof -i :8372 | head -2
```

### Post-restart checklist

The supervisor's startup re-renders the embedded pack tree. Any in-place
patches from `gc-fix-*` helpers get wiped. `gc-fix-watch` should detect
this within its polling interval (default 30s) and re-apply, but it's
worth confirming:

```bash
# Verify pool fields restored to canonical FQN form
grep '^pool ' ~/<town>/.gc/system/packs/dolt/orders/mol-dog-*.toml
# expect: pool = "gastown.dog" (not bare "dog")

# If still bare, run helpers manually
gc-fix-alias-mismatch ~/<town>
gc-fix-merge-strategy ~/<town>
```

The dolt/orders/* dog orders should fire once each within ~5–15 min of
pool-state stabilizing post-restart. Verify:

```bash
grep '"order.fired"' ~/<town>/.gc/events.jsonl \
    | grep -E 'mol-dog-(doctor|stale-db|compactor)' \
    | tail -5
```

If they DON'T fire after the pool is restored, either:
- Pool wasn't actually canonicalized (re-check + re-run helpers)
- Supervisor is still stuck (check supervisor.log for new `bd create:
  exit status 1` entries)
- The order's tracking-bead state in dolt is corrupt (open a fresh bug)

### When NOT to restart

`gc supervisor stop` (when it works) drops every agent across every rig
and city. Blast radius:

- Witnesses, refineries, deacons, polecats — all drained
- Active polecat work loses its session (worktree preserved on disk;
  bead state preserved in dolt)
- In-flight `gc mail` operations may fail until the new supervisor binds
- Cross-city peers will see this host's gateway return errors briefly

Restart is appropriate for:
- A specific known-stuck condition like `mg-pfh96` / `dgu-pfh96`
- A human-driven maintenance window
- After a binary upgrade

It is NOT appropriate as a routine fix for transient issues. Filing the
underlying bug (Class C) and waiting for a binary fix is the durable path.

### Verified test result (yg, 2026-04-29)

Timeline:

| Time (UTC)     | Event                                                                |
|----------------|----------------------------------------------------------------------|
| `T-0`          | `gc supervisor stop` invoked. Returns `Supervisor stopping...`       |
| `T+5s`         | Process still alive (PID held port 8372). SIGTERM ignored.           |
| `T+20s`        | Still alive. SIGKILL applied.                                        |
| `T+22s`        | Old PID reaped. launchd KeepAlive spawned new supervisor.            |
| `T+30s`        | Templater wipe detected: pool `gastown.dog` reverted to bare `dog`.  |
| `T+1m`         | `gc-fix-alias-mismatch` re-applied; pool `gastown.dog` stable.       |
| `T+6m30s`      | `mol-dog-compactor`, `mol-dog-doctor`, `mol-dog-stale-db` each fire ONCE. |
| `T+11m`        | `mol-dog-doctor`'s next 5-min cooldown elapses. NO fire. Order re-stuck. |

Confirms the diagnosis exactly: restart unsticks for one fire each;
broken-state guard re-traps after the next bd-error.
