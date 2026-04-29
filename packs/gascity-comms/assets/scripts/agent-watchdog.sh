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
#       1. present = count of any sessions for this template (active,
#                    asleep, creating). Updates the per-template
#                    heartbeat when present>0 so the next empty tick
#                    can detect "slot just emptied."
#       2. live    = count of active sessions (asleep doesn't claim work
#                    without a wake, so this gates the spawn decision).
#       3. queued  = count of open beads waiting for this template
#                    (pool: gc.routed_to=<full> + no assignee, plus any
#                    open beads explicitly assigned to the template name)
#       4. settle  = whether the slot was observed present within the last
#                    RECENT_CUTOFF_SECONDS (heartbeat file). If so, the
#                    slot was just emptied — let min_active backfill it
#                    instead of racing the reconciler.
#       5. recent  = count of sessions whose CreatedAt is within the last
#                    RECENT_CUTOFF_SECONDS (the reconciler may already be
#                    materializing one — don't race it)
#       6. spawn iff queued > 0 AND live == 0 AND settle == 0 AND recent == 0
#
# The heartbeat (step 4) addresses the over-spawn race when min_active is
# set: a long-lived polecat's CreatedAt is far older than RECENT_CUTOFF,
# so step 5 alone doesn't detect "the slot was just full." Tracking
# last-observed-present time per template gives min_active time to settle
# before the watchdog backstops.
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
# Default 90s covers the common case where min_active=1 backfills the slot
# within ~30-60s after a polecat drains; the watchdog defers during that
# window and only spawns if the reconciler has clearly failed.
RECENT_CUTOFF_SECONDS="${AGENT_WATCHDOG_RECENT_CUTOFF:-90}"

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
# Per-template heartbeat directory. We record the epoch of the last tick
# that observed any session (active, asleep, or creating) for each
# template, so we can detect "slot just emptied" even when the prior
# session's CreatedAt is far outside the recent cutoff. Without this, a
# polecat that ran for 30 minutes and just drained looks identical to
# "no polecat for hours" — both have no recent session creation, and the
# watchdog would race min_active to refill.
# -----------------------------------------------------------------------
state_dir="${GC_CITY_RUNTIME_DIR:-/tmp}/agent-watchdog"
mkdir -p "$state_dir" 2>/dev/null || true

# -----------------------------------------------------------------------
# Per-rig, per-template scan.
# -----------------------------------------------------------------------
spawned=0

while IFS=$'\t' read -r rig rig_path; do
    [[ -z "$rig" ]] && continue
    for template in $TEMPLATES; do
        full_template="$rig/gastown.$template"

        # Per-template heartbeat file. Slashes in the template name would
        # be treated as path separators, so flatten them with "__".
        safe_template="${full_template//\//__}"
        heartbeat_file="$state_dir/$safe_template.last_seen_live"

        # All sessions for this template (any state — active, asleep,
        # creating). The slot is "filled" if any session exists, even
        # asleep ones; the heartbeat tracks this so a session that goes
        # active→asleep→reaped still counts as "recently filled."
        all_sessions_json=$(gc session list --state all --template "$full_template" --json 2>/dev/null || echo '[]')
        present=$(printf '%s' "$all_sessions_json" | jq 'length' 2>/dev/null || echo 0)

        # Active count is the spawn gate — same as before. An asleep
        # session won't claim queued work without a wake, so the watchdog
        # still wants to know if anything is actively working.
        live=$(printf '%s' "$all_sessions_json" | jq '[.[] | select(.State == "active")] | length' 2>/dev/null || echo 0)

        # Update heartbeat when the slot has any session. Subsequent
        # ticks that observe an empty slot can compare against this to
        # detect "the slot was just emptied" and defer to the reconciler's
        # min_active path.
        if [[ "$present" -gt 0 ]]; then
            printf '%s\n' "$now_epoch" > "$heartbeat_file" 2>/dev/null || true
        fi

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
        [[ "$live" -gt 0 ]] && continue

        # Settling guard: if the slot was observed full within the recent
        # cutoff, the reconciler's min_active path is almost certainly
        # already materializing a backfill. Defer this tick — if the
        # reconciler is genuinely broken, the heartbeat will age past the
        # cutoff and we'll spawn on a later tick.
        if [[ -f "$heartbeat_file" ]]; then
            last_seen=$(cat "$heartbeat_file" 2>/dev/null)
            if [[ "$last_seen" =~ ^[0-9]+$ ]]; then
                elapsed=$((now_epoch - last_seen))
                if [[ "$elapsed" -ge 0 && "$elapsed" -lt "$RECENT_CUTOFF_SECONDS" ]]; then
                    continue
                fi
            fi
        fi

        # Don't race the reconciler if it's already starting one for this
        # template. The session may be visible briefly with State=creating
        # before it goes active; this guard catches the seam.
        # Reuses all_sessions_json from the live/present query above.
        if [[ -n "$recent_cutoff" ]]; then
            recently_created=$(printf '%s' "$all_sessions_json" \
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
