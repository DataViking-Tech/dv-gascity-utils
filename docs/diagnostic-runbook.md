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
