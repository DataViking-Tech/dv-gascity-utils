#!/usr/bin/env bash
# Pack doctor check: pool ramp-up health.
#
# When a bead is routed to a pool agent (e.g. metadata.gc.routed_to =
# "<rig>/gastown.polecat" or ".../gastown.dog"), the supervisor is
# supposed to ramp the pool from min=0 toward max within seconds via
# the gate-sweep order. Empirically observed on yg this session,
# multiple times:
#
#   1. Polecat pool ramp delays of 10+ min on synth-panel after
#      slinging dgu-nku6b/dgu-hmbou — beads with gc.routed_to set
#      but no specific assignee, no pool spawn observable until
#      well past the 30s gate-sweep cooldown should fire.
#   2. Dog pool stuck — mol-dog-compactor 3-for-3 wisp-failed since
#      Apr 27. Order dispatches, dog pool doesn't ramp before the
#      wisp gets marked failed in 1-35s. yg now sitting at 75k+
#      commits (over the 50k threshold) because the compactor never
#      runs.
#
# Same root cause shape: order/sling fires, pool reconcile lags, work
# sits unclaimed.
#
# This check walks every rig in the city, lists open beads with
# `metadata.gc.routed_to` set to a pool agent name, computes age, and
# warns on any older than $POOL_RAMP_THRESHOLD_MIN. Default 5min —
# the gate-sweep order has a 30s cooldown, so 5min is well past the
# point a healthy pool should have ramped.
#
# Exit codes: 0=OK, 1=Warning (stuck-routing beads found), 2=Error
# stdout: first line=summary, rest=details (one line per stuck bead)

set -euo pipefail

POOL_RAMP_THRESHOLD_MIN="${POOL_RAMP_THRESHOLD_MIN:-5}"

GC_BIN="${GC_BIN:-gc}"
if ! command -v "$GC_BIN" >/dev/null 2>&1; then
    echo "gc binary not found on PATH (looked for: $GC_BIN)"
    exit 2
fi
if ! command -v jq >/dev/null 2>&1; then
    echo "jq not on PATH; cannot parse bead JSON"
    exit 2
fi
if ! command -v python3 >/dev/null 2>&1; then
    echo "python3 not on PATH; cannot compute bead ages"
    exit 2
fi

# Build rig table from `gc config show` (same parser shape as
# pr-ci-watch.sh and gc-rig-init's backfill mode). Tab-delimited:
#   <rig_name>\t<rig_path>\n
config_args=(config show)
if [ -n "${GC_CITY:-}" ]; then
    config_args=(--city "$GC_CITY" "${config_args[@]}")
fi
config_output=$("$GC_BIN" "${config_args[@]}" 2>/dev/null) || {
    echo "could not read 'gc config show'"
    exit 2
}

RIG_TABLE=""
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
        rp="${BASH_REMATCH[1]}"
        RIG_TABLE="${RIG_TABLE}${current_rig}	${rp}
"
        current_rig=""
    fi
done <<< "$config_output"

if [ -z "$RIG_TABLE" ]; then
    echo "no rigs found in city config — nothing to check"
    exit 0
fi

# Compute "now" in epoch seconds for age math.
NOW_EPOCH=$(date +%s)
THRESHOLD_SEC=$((POOL_RAMP_THRESHOLD_MIN * 60))

stuck_count=0
stuck_lines=()

while IFS=$'\t' read -r rig_name rig_path; do
    [ -z "$rig_name" ] && continue
    [ -d "$rig_path" ] || continue

    # bd list returns JSON for the rig's open beads. The metadata
    # field is the routing source we filter on. --limit 0 disables
    # the default 50-row cap (rigs can easily exceed 50 open beads
    # once polecat-work formula expands children inline).
    beads=$(cd "$rig_path" && bd list --status=open --limit 0 --json 2>/dev/null || echo "[]")
    [ -z "$beads" ] && continue
    [ "$beads" = "[]" ] && continue

    # Filter for beads with metadata.gc.routed_to matching a pool
    # agent (polecat / dog) AND no assignee (or assignee = the pool
    # name itself, before a specific slot claims it). Output
    # tab-separated id/routed_to/created_at for the age check below.
    candidates=$(printf '%s' "$beads" | jq -r '
        .[]
        | select(.metadata."gc.routed_to" != null)
        | select(
            (.metadata."gc.routed_to" | tostring | contains("/gastown.polecat"))
            or (.metadata."gc.routed_to" | tostring | contains("/gastown.dog"))
            or (.metadata."gc.routed_to" | tostring | contains("/gastown.refinery"))
          )
        | select((.assignee // "") == "" or (.assignee // "") == .metadata."gc.routed_to")
        | [.id, .metadata."gc.routed_to", .created_at] | @tsv
    ' 2>/dev/null || true)

    [ -z "$candidates" ] && continue

    while IFS=$'\t' read -r bead_id routed_to created_at; do
        [ -z "$bead_id" ] && continue
        # Compute age via python (portable ISO-8601 parser).
        age_sec=$(python3 -c "
from datetime import datetime, timezone
import sys
try:
    s = '$created_at'.strip()
    if s.endswith('Z'): s = s[:-1] + '+00:00'
    ca = datetime.fromisoformat(s)
    if ca.tzinfo is None:
        ca = ca.replace(tzinfo=timezone.utc)
    print(int((datetime.now(timezone.utc) - ca).total_seconds()))
except Exception:
    print(-1)
" 2>/dev/null)
        [ -z "$age_sec" ] && age_sec=-1
        if [ "$age_sec" -lt 0 ]; then
            continue
        fi
        if [ "$age_sec" -gt "$THRESHOLD_SEC" ]; then
            stuck_count=$((stuck_count + 1))
            age_min=$((age_sec / 60))
            stuck_lines+=("  $rig_name $bead_id (routed $routed_to, age ${age_min}min)")
        fi
    done <<< "$candidates"
done <<< "$RIG_TABLE"

if [ "$stuck_count" -eq 0 ]; then
    echo "all routed beads claimed within threshold (${POOL_RAMP_THRESHOLD_MIN}min)"
    exit 0
fi

echo "${stuck_count} routed bead(s) stuck >${POOL_RAMP_THRESHOLD_MIN}min — pool ramp may be wedged"
printf '%s\n' "${stuck_lines[@]}"
cat <<EOF

A pool agent (polecat / dog / refinery) appears not to be ramping
in response to routed work. Common causes (in order of frequency
observed):

  1. Deacon drain — the deacon orchestrates pool ramp; if it's idle
     at an empty Claude prompt no dispatch happens. Run the
     check-deacon-drain-recovery doctor check first.
  2. Supervisor bead-cache wedge — 'gc supervisor logs' shows
     'beads cache: reconcile cache: bd list: timed out'. SIGKILL
     supervisor + launchd respawn.
  3. Reload silent-failure cascade — recent city.toml edits silently
     dropped because a prior reload was rejected. Run the
     check-reload-state doctor check (when shipped).
  4. Pool config cap reached — 'gc gastown status' shows max active
     pool members. Less likely if max is the gastown default of 5.

If none of the above, file an investigation bead (the routing path
from sling → pool → spawn has more than one binary actor in it).

Threshold tuning: override via POOL_RAMP_THRESHOLD_MIN env var if
your gate-sweep cooldown is longer than the default 30s.
EOF
exit 1
