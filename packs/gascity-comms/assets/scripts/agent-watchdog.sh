#!/usr/bin/env bash
# agent-watchdog.sh — backstop-spawn rig-scoped polecats/refineries when
# the reconciler's auto-scale path doesn't materialize a session despite
# queued work.
#
# See ../../orders/agent-watchdog.toml and ../../../../docs/agent-watchdog.md
# for the failure modes this addresses (poolDesired flap, stale-session
# inflation of active count) and how this script gates against double-spawn.
#
# Per cooldown tick:
#   For each rig:
#     For each scaled template (refinery, polecat):
#       1. queued  = count of open beads waiting for this template
#                    (pool: gc.routed_to=<full> + no assignee, plus any
#                    open beads explicitly assigned to the template name)
#       2. live    = count of active sessions filtered by template
#       3. recent  = count of sessions whose CreatedAt is within the last
#                    RECENT_CUTOFF_SECONDS (the reconciler may already be
#                    materializing one — don't race it)
#       4. spawn iff queued > 0 AND live == 0 AND recent == 0
#
# Spawning uses `gc session new <full> --no-attach` with no --alias so the
# supervisor picks an unused name from the namepool. The script never
# exceeds the agent's max_active_sessions because the live==0 gate means
# we only ever add one watchdog session per tick per template; subsequent
# ticks observe live>0 and exit early.
#
# Failures (gc session new exits non-zero, gc command unavailable, etc.)
# are logged to stdout but never abort the run — the next tick retries.
#
# Runs as an exec order — no agent, no LLM, no wisp. macOS bash 3.2 safe.

set -uo pipefail

# Optional override for callers that want a different "very recent" window.
RECENT_CUTOFF_SECONDS="${AGENT_WATCHDOG_RECENT_CUTOFF:-60}"

# Templates this watchdog manages. Order is intentional: refinery first
# because a stalled refinery blocks merge throughput across all polecats,
# and we want to spend the spawn budget on it before scaling polecats.
TEMPLATES="refinery polecat"

if ! command -v gc >/dev/null 2>&1; then
    exit 0
fi
if ! command -v jq >/dev/null 2>&1; then
    exit 0
fi
if ! command -v bd >/dev/null 2>&1; then
    exit 0
fi

# -----------------------------------------------------------------------
# Build rig table from `gc config show`. Stored as a tab-separated blob
# (one row per rig: <name>\t<path>\n) rather than an associative array
# so the script runs on macOS bash 3.2.
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
    # Any new top-level [..] header that isn't [[rigs]] or a [rigs.*]
    # subtable closes the current rig.
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
        RIG_TABLE="${RIG_TABLE}${current_rig}	${rig_path}
"
        current_rig=""
    fi
done <<< "$config_output"

[[ -z "$RIG_TABLE" ]] && exit 0

# -----------------------------------------------------------------------
# Compute the "recent enough to be the reconciler's in-flight spawn" cutoff
# in RFC3339 UTC. Try BSD date first (macOS), fall back to GNU date (Linux).
# -----------------------------------------------------------------------
now_epoch=$(date -u +%s)
recent_cutoff_epoch=$((now_epoch - RECENT_CUTOFF_SECONDS))
recent_cutoff=$(date -u -r "$recent_cutoff_epoch" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || date -u -d "@$recent_cutoff_epoch" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || echo "")

# -----------------------------------------------------------------------
# Per-rig, per-template scan.
# -----------------------------------------------------------------------
spawned=0

while IFS=$'\t' read -r rig rig_path; do
    [[ -z "$rig" ]] && continue
    for template in $TEMPLATES; do
        full_template="$rig/gastown.$template"

        # Pool-routed open work, no assignee. The polecat/refinery hooks
        # consume from this set when they wake.
        unassigned_count=$(bd list --status=open \
            --metadata-field "gc.routed_to=$full_template" \
            --no-assignee --json --limit=0 2>/dev/null \
            | jq 'length' 2>/dev/null || echo 0)

        # Open beads literally assigned to the template name. Rare in
        # practice (callers prefer routed_to + unassigned for pool work),
        # but cover both shapes since the reconciler counts both.
        templated_count=$(bd list --status=open \
            --assignee "$full_template" --json --limit=0 2>/dev/null \
            | jq 'length' 2>/dev/null || echo 0)

        queued=$((unassigned_count + templated_count))
        [[ "$queued" -le 0 ]] && continue

        # Live sessions for this exact template.
        live=$(gc session list --state active --template "$full_template" --json 2>/dev/null \
            | jq 'length' 2>/dev/null || echo 0)
        [[ "$live" -gt 0 ]] && continue

        # Don't race the reconciler if it's already starting one for this
        # template. The session may be visible briefly with State=active
        # before the work is observable; this guard catches the seam.
        if [[ -n "$recent_cutoff" ]]; then
            recently_created=$(gc session list --state all --template "$full_template" --json 2>/dev/null \
                | jq --arg cutoff "$recent_cutoff" '[.[] | select(.CreatedAt > $cutoff)] | length' 2>/dev/null \
                || echo 0)
            [[ "$recently_created" -gt 0 ]] && continue
        fi

        echo "agent-watchdog: spawn $full_template (queued=$queued, live=0)"
        if gc session new "$full_template" --no-attach >/dev/null 2>&1; then
            spawned=$((spawned + 1))
        else
            echo "agent-watchdog: spawn failed for $full_template"
        fi
    done
done <<< "$RIG_TABLE"

[[ "$spawned" -gt 0 ]] && echo "agent-watchdog: spawned $spawned session(s)"
exit 0
