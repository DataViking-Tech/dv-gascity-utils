#!/usr/bin/env bash
# pr-ci-watch.sh — watch open PRs linked to tracked beads, auto-merge on
# green CI, and resling on failure paths. Runs from a cooldown order
# every ~5 min.
#
# Two bead populations are tracked:
#
#   1. Closed beads with metadata.merge_result=pull_request (refinery
#      mr-mode handoff). PR URL is in metadata.pr_url.
#
#   2. Open beads with metadata.merge_result=blocked and metadata.branch
#      set (refinery hit branch protection, mayor opened PR manually).
#      PR URL is discovered via `gh pr list --head <branch>` and written
#      back to metadata.pr_url for next cycle.
#
# Per bead, the script:
#   - Resolves PR URL (from metadata or by branch lookup)
#   - Reads PR state, mergeable status, and check rollup
#   - Acts:
#       PR merged       -> set merge_result=merged_external + merged_sha
#       PR closed       -> set merge_result=closed_without_merge
#       CI any-fail     -> resling
#       CI pending      -> no-op this cycle
#       MERGEABLE=CONFLICTING -> resling (merge conflict on target)
#       CI all-pass + mergeable -> attempt `gh pr merge --squash --delete-branch`
#         success      -> set merge_result=merged_external on next cycle
#                          via the MERGED state branch
#         failure      -> resling (treated as a merge conflict surfaced
#                          at merge time)
#
# Resling shape (single path, called from any of the failure branches
# above):
#   - reopen bead (status=open)
#   - clear assignee so the polecat pool reconciler picks it up
#   - set gc.routed_to=<rig>/gastown.polecat
#   - set rejection_reason describing what failed
#   - set existing_pr=<pr_url> so the polecat reuses the same PR
#   - set last_ci_failure timestamp
#   - increment resling_count
#   - clear terminal markers (merge_result, blocked_reason)
#
# Resling cap: when metadata.resling_count >= MAX_RESLINGS, escalate to
# mayor via mail and stop reslinging. Default 3. Override via env var
# PR_CI_WATCH_MAX_RESLINGS.
#
# Auto-merge: enabled by default. To opt out (preserve the older
# "humans merge" policy on a host-by-host basis), set
# PR_CI_WATCH_AUTO_MERGE=false in the order's environment. With
# auto-merge disabled, CI green still records ci_status=passed and the
# script returns without acting (existing pre-2026-05-01 behavior).
#
# Idempotent. Terminal merge_result values are skipped. Each cycle is a
# self-contained pass.
#
# Runs as an exec order — no agent, no LLM, no wisp.

set -euo pipefail

MAX_RESLINGS="${PR_CI_WATCH_MAX_RESLINGS:-3}"
AUTO_MERGE="${PR_CI_WATCH_AUTO_MERGE:-true}"

if ! command -v gh >/dev/null 2>&1; then
    exit 0
fi
if ! command -v jq >/dev/null 2>&1; then
    exit 0
fi
if ! gh auth status >/dev/null 2>&1; then
    exit 0
fi

# -----------------------------------------------------------------------
# Build rig table from gc config show as a single tab-separated blob:
#   <rig_name>\t<path>\t<bead_prefix>\n
# Each rig's bead prefix (e.g. "dgu") is in <rig-path>/.beads/metadata.json
# under .dolt_database. Stored as plain text rather than an associative
# array so the script runs on macOS bash 3.2.
# -----------------------------------------------------------------------

RIG_TABLE=""

config_output=$(gc config show 2>/dev/null) || exit 0

current_rig=""
in_rigs=0
while IFS= read -r line; do
    if [[ "$line" == "[[rigs]]" ]]; then
        in_rigs=1
        current_rig=""
        continue
    fi
    if [[ "$line" =~ ^\[ && "$line" != "[[rigs]]" && ! "$line" =~ ^\[rigs\. ]]; then
        in_rigs=0
        current_rig=""
        continue
    fi
    [[ "$in_rigs" -eq 1 ]] || continue
    if [[ "$line" =~ ^name[[:space:]]*=[[:space:]]*\"(.+)\"$ && -z "$current_rig" ]]; then
        current_rig="${BASH_REMATCH[1]}"
    elif [[ "$line" =~ ^path[[:space:]]*=[[:space:]]*\"(.+)\"$ && -n "$current_rig" ]]; then
        rig_path="${BASH_REMATCH[1]}"
        meta="$rig_path/.beads/metadata.json"
        pfx=""
        if [[ -f "$meta" ]]; then
            pfx=$(jq -r '.dolt_database // empty' "$meta" 2>/dev/null || true)
        fi
        # Tab-delimited record terminated by newline.
        RIG_TABLE="${RIG_TABLE}${current_rig}	${rig_path}	${pfx}
"
        current_rig=""
    fi
done <<< "$config_output"

# Lookup helpers (linear scan; rig list is small).

# rig_name_for_prefix <prefix> -> stdout: rig name (or empty)
rig_name_for_prefix() {
    local p="$1"
    [[ -z "$p" ]] && return 0
    printf '%s' "$RIG_TABLE" | awk -F'\t' -v p="$p" '$3 == p { print $1; exit }'
}

# rig_path_for_name <rig_name> -> stdout: filesystem path (or empty)
rig_path_for_name() {
    local n="$1"
    [[ -z "$n" ]] && return 0
    printf '%s' "$RIG_TABLE" | awk -F'\t' -v n="$n" '$1 == n { print $2; exit }'
}

# -----------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------

# rig_for_bead <bead_id> <gc.routed_to> -> stdout: rig name (or empty)
rig_for_bead() {
    local bead_id="$1" routed_to="$2"
    local prefix="${bead_id%%-*}"
    local rig
    rig=$(rig_name_for_prefix "$prefix")
    if [[ -z "$rig" && -n "$routed_to" && "$routed_to" != "human" && "$routed_to" == */* ]]; then
        rig="${routed_to%%/*}"
    fi
    printf '%s' "$rig"
}

# Parse "owner/repo" from a github.com remote URL (https or ssh).
# Returns empty for non-github URLs so the caller short-circuits cleanly.
parse_repo_slug() {
    local url="$1"
    case "$url" in
        https://github.com/*|git@github.com:*) ;;
        *) return 0 ;;
    esac
    printf '%s' "$url" | sed -E '
        s#^https://github\.com/([^/]+/[^/.]+)(\.git)?/?$#\1#
        s#^git@github\.com:([^/]+/[^/.]+)(\.git)?$#\1#
    '
}

# discover_pr_url <rig_path> <branch> -> stdout: PR URL (or empty)
discover_pr_url() {
    local rig_path="$1" branch="$2"
    [[ -z "$rig_path" || -z "$branch" ]] && return 0
    local url slug res
    url=$(git -C "$rig_path" remote get-url origin 2>/dev/null || true)
    [[ -z "$url" ]] && return 0
    slug=$(parse_repo_slug "$url")
    [[ -z "$slug" ]] && return 0
    res=$(gh pr list --repo "$slug" --head "$branch" --state open \
        --json url --limit 1 2>/dev/null || echo "[]")
    [[ -z "$res" || "$res" == "[]" ]] && return 0
    printf '%s' "$res" | jq -r '.[0].url // empty'
}

# pr_info <pr_url> -> stdout: JSON {state, mergedAt, mergeCommit, closed, mergeable}
# mergeable values returned by gh: MERGEABLE | CONFLICTING | UNKNOWN
pr_info() {
    local pr_url="$1"
    gh pr view "$pr_url" --json state,mergedAt,mergeCommit,closed,mergeable 2>/dev/null || echo "{}"
}

# checks_summary <pr_url> -> stdout: pass | fail | pending | none | error
checks_summary() {
    local pr_url="$1"
    local out
    # gh pr checks exits 8 when checks are pending; JSON still emitted.
    out=$(gh pr checks "$pr_url" --json bucket 2>/dev/null || true)
    [[ -z "$out" ]] && { printf 'error'; return; }

    local n_total n_fail n_pending
    n_total=$(printf '%s' "$out" | jq 'length' 2>/dev/null || echo 0)
    [[ "$n_total" -eq 0 ]] && { printf 'none'; return; }

    n_fail=$(printf '%s' "$out" \
        | jq '[.[] | select(.bucket == "fail" or .bucket == "cancel")] | length' \
        2>/dev/null || echo 0)
    n_pending=$(printf '%s' "$out" \
        | jq '[.[] | select(.bucket == "pending")] | length' \
        2>/dev/null || echo 0)

    if [[ "$n_fail" -gt 0 ]]; then
        printf 'fail'
    elif [[ "$n_pending" -gt 0 ]]; then
        printf 'pending'
    else
        printf 'pass'
    fi
}

# failing_checks_brief <pr_url> -> stdout: comma-separated failing names.
failing_checks_brief() {
    local pr_url="$1"
    gh pr checks "$pr_url" --json bucket,name 2>/dev/null \
        | jq -r '[.[] | select(.bucket == "fail" or .bucket == "cancel") | .name] | unique | join(", ")' \
        2>/dev/null || true
}

# resling_bead <bead_id> <rig> <pr_url> <reason> <resling_count>
# Reopens the bead, routes to the polecat pool with rejection metadata,
# preserves existing_pr so the polecat resumes against the same PR.
# Caller is responsible for the MAX_RESLINGS cap check; this function
# performs the resling unconditionally.
resling_bead() {
    local bead_id="$1" rig="$2" pr_url="$3" reason="$4" resling_count="$5"
    local new_count=$((resling_count + 1))
    local now
    now=$(date -u +%Y-%m-%dT%H:%M:%SZ)

    bd update "$bead_id" \
        --status=open \
        --assignee="" \
        --set-metadata "gc.routed_to=$rig/gastown.polecat" \
        --set-metadata "rejection_reason=$reason" \
        --set-metadata "existing_pr=$pr_url" \
        --set-metadata "last_ci_failure=$now" \
        --set-metadata "resling_count=$new_count" \
        --unset-metadata merge_result \
        --unset-metadata blocked_reason \
        --append-notes "pr-ci-watch: $reason; reslinging to $rig/gastown.polecat pool (attempt $new_count/$MAX_RESLINGS)." \
        >/dev/null 2>&1 || true
}

# escalate_cap_reached <bead_id> <pr_url> <resling_count>
# Mails mayor and marks bead with ci_status=failed_max_reslings.
escalate_cap_reached() {
    local bead_id="$1" pr_url="$2" resling_count="$3"
    bd update "$bead_id" \
        --set-metadata ci_status=failed_max_reslings \
        --append-notes "pr-ci-watch: failed after $resling_count resling(s); cap reached, escalating." \
        >/dev/null 2>&1 || true
    gc mail send mayor/ \
        -s "ESCALATION: PR-CI resling cap reached for $bead_id [HIGH]" \
        -m "Bead: $bead_id
PR: $pr_url
Resling count: $resling_count (cap: $MAX_RESLINGS)
Action: human review needed; watcher has stopped reslinging this bead." \
        >/dev/null 2>&1 || true
}

# attempt_auto_merge <pr_url> -> stdout: "ok" | "conflict" | "skipped"
# Tries `gh pr merge --squash --delete-branch`. Returns "skipped" if
# auto-merge is disabled. Returns "conflict" on any failure (most
# commonly the source-branch merge conflict surfaced at merge time, but
# the script treats any merge failure as a resling trigger so the
# polecat re-investigates).
attempt_auto_merge() {
    local pr_url="$1"
    if [[ "$AUTO_MERGE" != "true" ]]; then
        printf 'skipped'
        return
    fi
    if gh pr merge "$pr_url" --squash --delete-branch >/dev/null 2>&1; then
        printf 'ok'
    else
        printf 'conflict'
    fi
}

# process_bead <bead_json>
process_bead() {
    local bead_json="$1"
    local bead_id pr_url branch routed_to resling_count rig rig_path

    bead_id=$(printf '%s' "$bead_json" | jq -r '.id')
    pr_url=$(printf '%s' "$bead_json" | jq -r '.metadata.pr_url // empty')
    branch=$(printf '%s' "$bead_json" | jq -r '.metadata.branch // empty')
    routed_to=$(printf '%s' "$bead_json" | jq -r '.metadata."gc.routed_to" // empty')
    resling_count=$(printf '%s' "$bead_json" | jq -r '.metadata.resling_count // "0"')

    rig=$(rig_for_bead "$bead_id" "$routed_to")
    [[ -z "$rig" ]] && return 0
    rig_path=$(rig_path_for_name "$rig")
    [[ -z "$rig_path" ]] && return 0

    if [[ -z "$pr_url" ]]; then
        if [[ -n "$branch" ]]; then
            pr_url=$(discover_pr_url "$rig_path" "$branch")
        fi
        if [[ -z "$pr_url" ]]; then
            return 0
        fi
        bd update "$bead_id" --set-metadata pr_url="$pr_url" >/dev/null 2>&1 || true
    fi

    local info state merged_at merge_sha mergeable
    info=$(pr_info "$pr_url")
    [[ -z "$info" || "$info" == "{}" ]] && return 0
    state=$(printf '%s' "$info" | jq -r '.state // empty')
    merged_at=$(printf '%s' "$info" | jq -r '.mergedAt // empty')
    merge_sha=$(printf '%s' "$info" | jq -r '.mergeCommit.oid // empty')
    mergeable=$(printf '%s' "$info" | jq -r '.mergeable // empty')

    case "$state" in
        MERGED)
            bd update "$bead_id" \
                --set-metadata merge_result=merged_external \
                --set-metadata merged_sha="${merge_sha:-unknown}" \
                --set-metadata ci_status=passed \
                --append-notes "pr-ci-watch: PR merged at ${merged_at:-unknown}; tracking complete." \
                >/dev/null 2>&1 || true
            return 0
            ;;
        CLOSED)
            bd update "$bead_id" \
                --set-metadata merge_result=closed_without_merge \
                --append-notes "pr-ci-watch: PR closed without merge; tracking stopped." \
                >/dev/null 2>&1 || true
            return 0
            ;;
        OPEN)
            ;;
        *)
            return 0
            ;;
    esac

    # Merge-conflict short-circuit: if GitHub already reports the PR as
    # CONFLICTING against its base, no point in waiting for CI to finish
    # — resling so the polecat rebases and resolves. This catches the
    # common case where main moved under a long-lived PR.
    if [[ "$mergeable" == "CONFLICTING" ]]; then
        if [[ "$resling_count" -ge "$MAX_RESLINGS" ]]; then
            escalate_cap_reached "$bead_id" "$pr_url" "$resling_count"
            return 0
        fi
        resling_bead "$bead_id" "$rig" "$pr_url" \
            "Merge conflict on target (mergeable=CONFLICTING)" \
            "$resling_count"
        return 0
    fi

    local ci
    ci=$(checks_summary "$pr_url")
    case "$ci" in
        pass)
            bd update "$bead_id" --set-metadata ci_status=passed >/dev/null 2>&1 || true
            # Auto-merge attempt. With AUTO_MERGE=false this is a no-op
            # and the script returns leaving the PR for human merge —
            # preserving the pre-2026-05-01 default behavior.
            local merge_result
            merge_result=$(attempt_auto_merge "$pr_url")
            case "$merge_result" in
                ok)
                    # Next cycle's MERGED-state branch records merge_result/merged_sha.
                    bd update "$bead_id" \
                        --append-notes "pr-ci-watch: CI green; auto-merged via gh pr merge --squash --delete-branch." \
                        >/dev/null 2>&1 || true
                    return 0
                    ;;
                conflict)
                    # Auto-merge failed despite mergeable!=CONFLICTING — most
                    # likely a transient race (target moved between pr_info
                    # and the merge call) or a branch-protection rule the
                    # script can't satisfy (required reviewers, signed
                    # commits, etc.). Treat as a merge-conflict resling so
                    # the polecat re-investigates rather than spinning.
                    if [[ "$resling_count" -ge "$MAX_RESLINGS" ]]; then
                        escalate_cap_reached "$bead_id" "$pr_url" "$resling_count"
                        return 0
                    fi
                    resling_bead "$bead_id" "$rig" "$pr_url" \
                        "Merge conflict at auto-merge time (gh pr merge --squash failed despite green CI)" \
                        "$resling_count"
                    return 0
                    ;;
                skipped)
                    return 0
                    ;;
            esac
            ;;
        none)
            bd update "$bead_id" --set-metadata ci_status=no_checks >/dev/null 2>&1 || true
            return 0
            ;;
        pending|error)
            return 0
            ;;
        fail)
            ;;
        *)
            return 0
            ;;
    esac

    # CI fail path.
    if [[ "$resling_count" -ge "$MAX_RESLINGS" ]]; then
        escalate_cap_reached "$bead_id" "$pr_url" "$resling_count"
        return 0
    fi

    local fails
    fails=$(failing_checks_brief "$pr_url")
    [[ -z "$fails" ]] && fails="unknown"
    resling_bead "$bead_id" "$rig" "$pr_url" "CI failed: $fails" "$resling_count"
    return 0
}

# -----------------------------------------------------------------------
# Main: collect tracked beads, process each.
# -----------------------------------------------------------------------

# Closed beads still in pull-request handoff.
mr_beads=$(bd list --status=closed \
    --metadata-field merge_result=pull_request \
    --json --limit=0 2>/dev/null || echo "[]")

# Open beads from refinery's blocked path (mayor manual PR).
blocked_beads=$(bd list --status=open \
    --metadata-field merge_result=blocked \
    --json --limit=0 2>/dev/null || echo "[]")

# Combine, dedupe.
combined=$(printf '%s\n%s\n' "$mr_beads" "$blocked_beads" \
    | jq -s '(.[0] // []) + (.[1] // []) | unique_by(.id)' 2>/dev/null || echo "[]")

n=$(printf '%s' "$combined" | jq 'length' 2>/dev/null || echo 0)
[[ "$n" -eq 0 ]] && exit 0

processed=0
while IFS= read -r bead; do
    [[ -z "$bead" || "$bead" == "null" ]] && continue
    process_bead "$bead"
    processed=$((processed + 1))
done < <(printf '%s' "$combined" | jq -c '.[]')

[[ "$processed" -gt 0 ]] && echo "pr-ci-watch: processed $processed tracked PR(s)"
