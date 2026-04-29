# Gas City diagnostic runbook

> **When something is broken and you need to know what.** Symptom → diagnostic command → recovery. No theory, just recipes.

For *why* the failure modes look the way they do, see `docs/lessons-learned.md`. For the working scaffold, see `docs/SETUP-GUIDE.md`.

## Table of contents

1. [`controller is busy` on `gc reload`](#1-controller-is-busy-on-gc-reload)
2. [`mail send` returns HTTP 500 "bd create timed out"](#2-mail-send-returns-http-500-bd-create-timed-out)
3. [`agent X not found in city.toml` (alias mismatch)](#3-agent-x-not-found-in-citytoml)
4. [`mol-polecat-work` step `.6` never closes (refinery never confirmed merge)](#4-mol-polecat-work-step-6-never-closes)
5. [New rig polecats never wake (reconciler latency)](#5-new-rig-polecats-never-wake)
6. [`gcx mail reply` hangs at zero bytes](#6-gcx-mail-reply-hangs-at-zero-bytes)
7. [`events.jsonl` > 100 MB](#7-eventsjsonl--100-mb)
8. [`bd init` succeeded but `bd` commands fail with "issue_prefix config is missing"](#8-bd-init-succeeded-but-bd-commands-fail-with-issue_prefix-config-is-missing)
9. [PR autonomy stuck states (`pr-ci-watch`)](#9-pr-autonomy-stuck-states)

## 1. `controller is busy` on `gc reload`

**Symptom**

```
$ gc reload
controller is busy
```

Repeats for minutes. Every gc subcommand on this host (mail, status, bd) feels slow or hangs.

**Diagnostic**

```bash
ps -A -o pid,etime,command | grep '/bin/bd'
```

Look for any `bd` process with a long `etime` (anything more than a few minutes is suspect).

**Recovery**

If a stuck `bd` PID is visible:

```bash
kill <pid>
```

The controller releases. `gc reload` succeeds within a few seconds.

If no stuck `bd` PID and the controller is still busy:

```bash
tail -n 50 <CITY>/.gc/runtime/controller.log
tail -n 50 <CITY>/.gc/runtime/supervisor.log
```

Look for repeated lines or stack traces. If the controller itself is wedged (rare):

```bash
gc stop --force
gc start
```

## 2. `mail send` returns HTTP 500 "bd create timed out"

**Symptom**

```
$ gcx mail send midgard:mayor -s "ping" -m "..."
HTTP 500: bd create timed out
```

Cross-city mail to a specific peer is timing out at the recipient's supervisor.

**Diagnostic**

This is almost always the recipient host's supervisor wedged on a stuck `bd` (same root cause as §1, observed from the sender side). Check the recipient host:

```bash
# on the recipient host
ps -A -o pid,etime,command | grep '/bin/bd'
tail -n 50 <CITY>/.gc/runtime/supervisor.log
```

Also confirm the gateway is reachable:

```bash
# on the sender host
curl -m 5 -H "Authorization: Bearer $(cat ~/.gc/tokens/<peer-host>-gateway.token)" \
     <peer-url>/v0/city/<peer>/status
```

Should return 200 with status JSON in well under 5 s.

**Recovery**

On the recipient host: kill the stuck `bd` PID (§1). The supervisor recovers without restart and the next `gcx mail send` succeeds.

If the gateway itself isn't reachable:

```bash
# on recipient host
launchctl print gui/$(id -u)/dev.gascity.gateway | grep state
launchctl kickstart -k gui/$(id -u)/dev.gascity.gateway
```

## 3. `agent X not found in city.toml`

**Symptom**

```
$ gc session new <rig>/<role>
agent <rig>/<role> not found in city.toml; did you mean <rig>/<role>?
```

The error suggests the same name it's complaining about. This is a registry/spawn alias mismatch — usually an open session bead in `drained` state blocking re-spawn.

**Diagnostic**

```bash
gc bd list --type=session --assignee="<rig>/<role>" --status=open
```

OR, against the dolt directly (replace `<prefix>` with the rig's prefix; backtick reserved-word prefixes):

```bash
gc --city <CITY> dolt sql -q "USE \`<prefix>\`; \
  SELECT id, status, metadata FROM issues \
  WHERE issue_type='session' AND assignee='<rig>/<role>' AND status='open';"
```

Look for sessions in `drained` state — those are stale and blocking the registry from re-spawning.

**Recovery**

Close the stale bead:

```bash
gc bd update <session-bead-id> --status=closed --close-reason "stale drained session"
```

Then retry the spawn. If multiple stale beads exist, close all of them.

If the issue persists after closing stale sessions, the supervisor's session map may need a reload:

```bash
gc reload
```

## 4. `mol-polecat-work` step `.6` never closes

**Symptom**

A polecat finishes implementation, runs the done sequence (`gc bd update --status=open --assignee=<rig>/refinery`, `gc runtime drain-ack`, exits), but the work bead sits at `status=open` assigned to the refinery indefinitely. Nothing merges.

**Diagnostic**

Three things to check, in order:

```bash
# 1. Does the polecat's branch actually exist on origin?
git ls-remote origin "refs/heads/polecat/<bead-id>"

# 2. Is the refinery actually awake?
gc status | grep refinery

# 3. Is branch protection blocking the merge?
gh api "repos/<owner>/<repo>/branches/main" --jq '.protected'
```

**Recovery — by case**

1. **Branch missing on origin:** the polecat exited before pushing. Check `<CITY>/.gc/runtime/supervisor.log` for the polecat's session — was there an error in the push step? Re-claim the bead manually and resume.

2. **Refinery stuck at `reserved-unmaterialized`:** name mismatch (see `docs/lessons-learned.md` §C). Manual wake:

   ```bash
   gc session wake <rig>/gastown.refinery
   ```

   Long-term fix: run `gc-fix-refinery-routing` against the gastown system pack (it's idempotent, patches both polecat→refinery and refinery rejection-bounce paths):

   ```bash
   <CITY>/.gc/system/packs/gascity-comms/assets/scripts/gc-fix-refinery-routing
   ```

3. **Branch protection rejecting direct merge:** GH013. The rig wants `merge_strategy=mr`. Run `gc-fix-merge-strategy` once per host so future polecat work auto-detects (see `docs/rig-merge-strategy.md`); for the bead in flight, the mayor opens the PR by hand and `pr-ci-watch` discovers it on the next 5 min cycle (see §9).

## 5. New rig polecats never wake

**Symptom**

Just ran `gc rig add` for a new rig, sling routes a bead to `<rig>/gastown.polecat`, the bead sits at `status=open` with no claimant for 10+ minutes. `gc status` shows the polecat slot at `reserved-unmaterialized (on_demand)`.

**Diagnostic**

```bash
gc bd list --status=open --metadata-field gc.routed_to=<rig>/gastown.polecat
gc status | grep -E "<rig>/gastown\.(polecat|refinery|witness)"
```

The polecat is genuinely on-demand and the reconciler hasn't spun it up yet. Expected latency: 10–20 min.

**Recovery — quick**

Manual kick:

```bash
gc session new <rig>/gastown.polecat --alias furiosa --no-attach
```

The reconciler still takes a few minutes to actually start the session; this just nudges it.

Or wake by template name (verified working):

```bash
gc session wake <rig>/gastown.polecat
```

**Recovery — durable**

Set `min_active_sessions=1` on the rig-scoped polecat agent so one slot stays warm. Schema location for this patch is currently unknown — workspace `[[patches.agent]]` rejects with `agent polecat not found in merged config`. Tracked: `dgu-m72nk`. Until that lands, the manual kick above is the supported workaround for new-rig setup.

## 6. `gcx mail reply` hangs at zero bytes

**Symptom**

```
$ gcx mail reply <id> -m "..."
# hangs forever, no output
```

`Ctrl-C` returns. `gc mail reply <id>` (plain, no gcx) errors out cleanly with `no sender to reply to`.

**Diagnostic**

This is the old gcx urlopen-without-timeout bug. Confirm gcx version:

```bash
which gcx
md5 $(readlink -f $(which gcx))
```

If the wrapper does not call `urlopen(req, timeout=30)` it's the buggy version. Inspect:

```bash
grep -n "urlopen" $(readlink -f $(which gcx))
```

**Recovery**

Pull `dv-gascity-utils` main and re-link:

```bash
cd /path/to/dv-gascity-utils
git pull
ln -sf $(pwd)/packs/gascity-comms/assets/scripts/gcx ~/.gc/bin/gcx
```

The fix landed at commit `6da4d88` (`fix(gcx): add 30s urlopen timeout (mg-492d)`). Any version after that has the timeout.

## 7. `events.jsonl` > 100 MB

**Symptom**

```bash
du -sh <CITY>/.gc/runtime/events.jsonl
# 142M
```

The runtime events log has grown unbounded.

**Diagnostic**

```bash
wc -l <CITY>/.gc/runtime/events.jsonl
ls -la <CITY>/.gc/runtime/events.jsonl
```

There is no log-rotation order today. The file grows monotonically.

**Recovery**

Low risk to the running system. Two options:

- **Leave it.** Disk pressure isn't immediate; events.jsonl is mostly used for after-the-fact debugging.
- **Truncate (with the controller running):**

  ```bash
  cp <CITY>/.gc/runtime/events.jsonl <CITY>/.gc/runtime/events.jsonl.bak
  : > <CITY>/.gc/runtime/events.jsonl
  ```

  Don't `rm` the file — the supervisor holds it open for append. Truncate in place.

A proper rotation order is filed-worthy if this becomes regular. Defer to user judgment.

## 8. `bd init` succeeded but `bd` commands fail with "issue_prefix config is missing"

**Symptom**

```bash
$ bd list
issue_prefix config is missing
```

Despite `bd init` having reported success.

**Diagnostic**

```bash
gc --city <canonical> dolt sql -q "USE \`<prefix>\`; SELECT * FROM config;"
```

If the result is empty (or missing the `issue_prefix` row), `bd init` did not seed it. This is the known external-mode bug.

**Recovery**

Manual SQL insert:

```bash
gc --city <canonical> dolt sql -q "USE \`<prefix>\`; \
  INSERT INTO config VALUES('issue_prefix','<prefix>'); \
  CALL DOLT_COMMIT('-Am','seed issue_prefix');"
```

Re-test:

```bash
bd list
# now succeeds
```

If the prefix is a SQL reserved word (`as`, `is`, `or`, `to`, `in`, `on`), the backticks are required.

## 9. PR autonomy stuck states

Closes the merge loop on PR-protected rigs. Without the watcher, a polecat's branch sits unmerged forever once GitHub branch protection forces a PR — CI runs, fails or passes, and nothing autonomous reacts.

### What ships

`packs/gascity-comms/orders/pr-ci-watch.toml` — cooldown order, 5 min interval. Calls `assets/scripts/pr-ci-watch.sh`. No agent, no LLM, no wisp.

### When the watcher engages

Two bead populations:

1. **Refinery mr-mode handoff.** When a polecat sets `merge_strategy=mr` (or provides `existing_pr`), the refinery rebases, pushes, validates the PR, then closes the bead with `metadata.merge_result=pull_request` and `metadata.pr_url=<url>`. The watcher tracks closed beads in this state.

2. **Blocked direct-merge.** When a polecat used the default `direct` strategy and the refinery's push hits branch protection (GH013), the refinery sets `metadata.merge_result=blocked`, sets `gc.routed_to=human`, and bails to mayor. A human (mayor or operator) opens the PR manually. The watcher finds these via `merge_result=blocked` + `metadata.branch`, discovers the PR with `gh pr list --head <branch>`, and writes `metadata.pr_url` for next cycle.

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

The polecat that picks up the reslung bead sees `metadata.branch` and `metadata.rejection_reason`, resumes the existing branch via the `mol-polecat-work` workspace-setup step (rebases on main, fixes the failing checks, pushes). The bead retains `existing_pr`, so on resubmission the refinery's mr-mode reuses the same PR — push the rebased branch back with `--force-with-lease`, validate, close the bead again. CI re-runs on the new commits and the watcher resumes monitoring.

### Resling cap

`metadata.resling_count >= MAX_RESLINGS` (default 3, env override `PR_CI_WATCH_MAX_RESLINGS`) means the watcher stops reslinging and mails mayor with `ESCALATION: PR-CI resling cap reached for <bead> [HIGH]`. The bead's `ci_status=failed_max_reslings` records the terminal state. A human either fixes the bead manually, raises the cap, or closes the PR.

### What the watcher will NOT do

- **Auto-merge on green CI.** Branch protection is intentional for human-facing repos; humans (or downstream tooling) decide when to merge.
- **Bypass branch protection.** No `--admin` flag, no force-merges.
- **Ship gh credentials.** Per-host `gh auth login` is the contract.

### Required preconditions

- `gh` CLI installed and authenticated on the host running the city (`gh auth status` exits 0).
- `jq` available.
- The rig's repo has a GitHub remote at `origin` (parsed via `git -C <rig-path> remote get-url origin`).

When any precondition is missing the watcher exits silently with status 0 so the cooldown order doesn't generate noise.

### Recovery recipes

- **Stuck at the cap.** Inspect with `bd show <bead> --json | jq '.[0].metadata'`; either fix the failing checks manually on the branch, then run `bd update <bead> --unset-metadata resling_count` to let the watcher retry, or close the PR and let the watcher mark `merge_result=closed_without_merge`.
- **Watcher tracking the wrong PR.** This happens if a stale `pr_url` was cached. Run `bd update <bead> --unset-metadata pr_url` and let the next cycle re-discover via the branch.
- **Watcher not running.** Check the order is loaded: `gc config show | grep -A 2 pr-ci-watch`. The pack root must contain `agents/` and `formulas/` directories (even empty) for the supervisor to scan `orders/`. Check `ls /path/to/packs/gascity-comms/{agents,formulas} 2>/dev/null`.
- **Resling forwards to the wrong rig.** The watcher derives the rig from the bead-id prefix via each rig's `.beads/metadata.json#dolt_database`. If a rig is missing that file, the watcher silently skips its beads. Rerun `bd init` in the rig if needed.

## How to add to this runbook

When you hit a failure mode that's not listed here, capture:

1. **Symptom:** the exact error message or behavior
2. **Diagnostic:** the single command that confirms the cause
3. **Recovery:** the steps that worked

File a bead with `[RUNBOOK]` in the title and append it here once verified twice.
