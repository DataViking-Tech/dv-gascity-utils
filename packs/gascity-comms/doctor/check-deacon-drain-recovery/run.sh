#!/usr/bin/env bash
# Pack doctor check: gastown.deacon liveness.
#
# The deacon orchestrates polecat-pool ramp-up. When the deacon's
# Claude Code session hits its context cap, it self-handoffs ("system
# healthy, heartbeat handed off to next session") and... sits at an
# empty prompt. mail-nudge cannot wake an idle Claude Code session
# into a new turn (the structural autonomy gap documented in
# docs/cross-city-comms.md). The result: silent dispatch failure.
# Polecat pools never ramp; routed beads sit unclaimed.
#
# Empirically observed on yg 2026-05-02: deacon drained at the end
# of a session-recovery cycle, dgu-nku6b/dgu-hmbou queued for >15min
# with no claim, no diagnostic surfaced. Recovery required:
#   gc handoff --target gastown.deacon
#   <supervisor restart if the bead-cache reconciler had also wedged>
#   gc session attach gastown.deacon
#
# This check inspects the deacon's session state via
# `gc session list --json` and warns on three drain signatures:
#
#   1. No deacon session registered at all → exit 1.
#   2. State == "asleep" → exit 1 (drain typical of self-handoff).
#   3. State == "active" BUT LastActive > $DEACON_DRAIN_THRESHOLD_MIN
#      ago → exit 1 (idle prompt; session alive but not patrolling).
#   4. State == "closed" → exit 1 (was killed, reconciler hasn't
#      brought it back).
#
# Threshold defaults to 15 min. The deacon's normal patrol cycle ticks
# faster than that; >15min idle in "active" state is a strong drain
# signal.
#
# Exit codes: 0=OK, 1=Warning (drain detected), 2=Error
# stdout: first line=summary, rest=details

set -euo pipefail

DRAIN_THRESHOLD_MIN="${DEACON_DRAIN_THRESHOLD_MIN:-15}"

GC_BIN="${GC_BIN:-gc}"
if ! command -v "$GC_BIN" >/dev/null 2>&1; then
    echo "gc binary not found on PATH (looked for: $GC_BIN)"
    exit 2
fi
if ! command -v jq >/dev/null 2>&1; then
    echo "jq not on PATH; cannot parse session JSON"
    exit 2
fi

list_args=(session list --json --template gastown.deacon --state all)
if [ -n "${GC_CITY:-}" ]; then
    list_args=(--city "$GC_CITY" "${list_args[@]}")
fi

if ! sessions=$("$GC_BIN" "${list_args[@]}" 2>&1); then
    echo "could not list gastown.deacon sessions"
    echo "---"
    echo "$sessions"
    exit 2
fi

count=$(printf '%s' "$sessions" | jq 'length' 2>/dev/null || echo 0)
if [ "$count" -eq 0 ]; then
    echo "no gastown.deacon session registered in this city"
    echo "(if the city was just initialized this is benign; otherwise"
    echo " run 'gc session attach gastown.deacon' to create one)"
    exit 1
fi

state=$(printf '%s' "$sessions" | jq -r '.[0].State // empty')
closed=$(printf '%s' "$sessions" | jq -r '.[0].Closed // false')
last_active=$(printf '%s' "$sessions" | jq -r '.[0].LastActive // empty')
session_id=$(printf '%s' "$sessions" | jq -r '.[0].ID // empty')

case "$state" in
    asleep)
        echo "deacon session $session_id is ASLEEP — drain detected"
        cat <<EOF

The deacon's Claude Code session is asleep, which means polecat-pool
ramp-up is silently disabled. Routed beads will sit unclaimed.

Recovery (in order):

  1. Try wake first:
       gc session attach gastown.deacon

  2. If wake doesn't take, request a controller restart:
       gc handoff --target gastown.deacon "drain-restart" "deacon idle"

  3. If the supervisor reconciler is also wedged (look for
     'beads cache: reconcile cache: bd list: timed out' in
     'gc supervisor logs'), restart the supervisor — see
     docs/diagnostic-runbook.md for the SIGKILL + launchd respawn
     sequence.

After recovery, verify dispatch resumes by re-running this check.
EOF
        exit 1
        ;;
    closed)
        echo "deacon session $session_id is CLOSED — reconciler hasn't restarted it"
        cat <<EOF

The deacon was killed (often by 'gc handoff --target gastown.deacon')
but the reconciler hasn't auto-restarted it. The deacon's wake_mode is
"fresh" — it doesn't auto-spawn after close; it needs an explicit
attach.

Recovery:

  gc session attach gastown.deacon

This creates a new session with the original alias.
EOF
        exit 1
        ;;
    active)
        if [ "$closed" = "true" ]; then
            echo "deacon session $session_id reports state=active but Closed=true (inconsistent)"
            exit 2
        fi
        if [ -z "$last_active" ]; then
            echo "deacon session $session_id is active but reports no LastActive timestamp"
            exit 1
        fi
        # Parse ISO-8601 timestamp; macOS date(1) handles fractional seconds with -j -f.
        # Portable approach via python (already required by gc-rig-init/etc.).
        age_min=$(python3 -c "
import sys
from datetime import datetime, timezone
try:
    s = '$last_active'.strip()
    # tolerate trailing Z or +HH:MM offset
    if s.endswith('Z'): s = s[:-1] + '+00:00'
    la = datetime.fromisoformat(s)
    now = datetime.now(timezone.utc)
    if la.tzinfo is None:
        la = la.replace(tzinfo=timezone.utc)
    print(int((now - la).total_seconds() // 60))
except Exception as e:
    print(-1)
" 2>/dev/null)
        if [ "$age_min" -lt 0 ]; then
            echo "deacon session $session_id active but could not parse LastActive='$last_active'"
            exit 2
        fi
        if [ "$age_min" -gt "$DRAIN_THRESHOLD_MIN" ]; then
            echo "deacon session $session_id active but idle for ${age_min}min (threshold ${DRAIN_THRESHOLD_MIN}min)"
            cat <<EOF

The deacon session is alive but hasn't emitted activity in
${age_min} minutes — well past its normal patrol cadence. Most
likely the session is sitting at an empty Claude Code prompt
after a self-handoff cycle that didn't re-pour the next patrol
wisp.

Recovery:

  gc session submit gastown.deacon "Resume heartbeat: pour the next
  mol-deacon-patrol wisp via 'gc bd mol wisp mol-deacon-patrol
  --root-only', assign it to yourself, execute the formula, and
  pour the next wisp before exiting each iteration."

If the submit doesn't kick a new turn within ~30s, fall through to
the asleep recovery path (handoff --target gastown.deacon).

Threshold tuning: override via DEACON_DRAIN_THRESHOLD_MIN env var
if your patrol cadence legitimately runs slower than 15min.
EOF
            exit 1
        fi
        echo "deacon session $session_id active, last activity ${age_min}min ago (threshold ${DRAIN_THRESHOLD_MIN}min)"
        exit 0
        ;;
    suspended)
        echo "deacon session $session_id is SUSPENDED — wake required"
        echo "Recovery: gc session wake gastown.deacon"
        exit 1
        ;;
    "")
        echo "deacon session $session_id reports empty State (gc binary may be on an older schema)"
        exit 2
        ;;
    *)
        echo "deacon session $session_id has unrecognized state: $state"
        exit 2
        ;;
esac
