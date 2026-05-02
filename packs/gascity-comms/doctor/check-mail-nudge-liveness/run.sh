#!/usr/bin/env bash
# Pack doctor check: mail-nudge dispatch is actually ticking.
#
# Symptom this catches: mail-nudge order is registered AND visible in
# 'gc order list' AND 'gc order check' shows it as 'due', but the
# controller's auto-dispatch loop isn't actually firing it. Side-effect
# is total cross-city autonomy failure — peer mail lands but no
# recipient session ever notices, because the wake-on-arrival never
# fires.
#
# Concrete trace from midgard, 2026-05-02: gastown.mayor.last_unread
# state file went from Apr 28 to May 2 (4+ days) without updating.
# 300+ unread mails accumulated. mail-nudge order was registered but
# not auto-dispatching (caused by a separate reload-rejection cascade —
# see check-reload-state). No detection that mail-nudge wasn't ticking
# until openclaw asked why no autonomous response to peer mail.
#
# Detection rule: each session that has ever been nudged has a state
# file at \$GC_CITY_RUNTIME_DIR/mail-nudge/<alias>.last_unread. The
# file's mtime is the last time mail-nudge ticked against that alias.
# If mtime is older than 2× the order's cooldown interval, the
# dispatch loop is failing for that session.
#
# Exit codes: 0=OK, 1=Warning (stale state files found), 2=Error
# stdout: first line=summary, rest=details

set -euo pipefail

CITY_ROOT="${GC_CITY:-$(pwd)}"
RUNTIME_DIR="${GC_CITY_RUNTIME_DIR:-$CITY_ROOT/.gc/runtime}"
STATE_DIR="$RUNTIME_DIR/mail-nudge"

# Default mail-nudge cooldown is 20s (per the order's interval). Fail
# if any state file is older than 2× that. Tunable via env for hosts
# running custom intervals.
INTERVAL_SEC="${MAIL_NUDGE_INTERVAL_SEC:-20}"
STALE_THRESHOLD_SEC=$((INTERVAL_SEC * 2))

if [ ! -d "$STATE_DIR" ]; then
    echo "no mail-nudge state dir at $STATE_DIR — order has never run on this city"
    echo "(this is expected if mail-nudge isn't installed; see check-orders-discovery)"
    exit 0
fi

# Find state files with mtime older than the threshold.
now_epoch=$(date +%s)
stale_entries=()
total_checked=0

for state_file in "$STATE_DIR"/*.last_unread; do
    [ -e "$state_file" ] || continue
    total_checked=$((total_checked + 1))

    # Get mtime (macOS uses stat -f %m; Linux uses stat -c %Y).
    if mtime=$(stat -f %m "$state_file" 2>/dev/null); then
        : # macOS path
    elif mtime=$(stat -c %Y "$state_file" 2>/dev/null); then
        : # Linux path
    else
        continue
    fi

    age_sec=$((now_epoch - mtime))
    if [ "$age_sec" -gt "$STALE_THRESHOLD_SEC" ]; then
        alias=$(basename "$state_file" .last_unread)
        # Format age for human reading.
        if [ "$age_sec" -gt 86400 ]; then
            age_human="$((age_sec / 86400))d"
        elif [ "$age_sec" -gt 3600 ]; then
            age_human="$((age_sec / 3600))h"
        elif [ "$age_sec" -gt 60 ]; then
            age_human="$((age_sec / 60))m"
        else
            age_human="${age_sec}s"
        fi
        stale_entries+=("$alias (age: $age_human)")
    fi
done

if [ "$total_checked" -eq 0 ]; then
    echo "mail-nudge state dir exists but contains no .last_unread files"
    exit 0
fi

if [ "${#stale_entries[@]}" -eq 0 ]; then
    echo "mail-nudge dispatch is healthy (all $total_checked state file(s) within ${STALE_THRESHOLD_SEC}s threshold)"
    exit 0
fi

echo "mail-nudge dispatch is STALE for ${#stale_entries[@]} of $total_checked session(s) (threshold: ${STALE_THRESHOLD_SEC}s)"
echo
echo "Stale sessions (last_unread mtime older than 2× cooldown):"
for entry in "${stale_entries[@]}"; do
    echo "  $entry"
done

cat <<EOF

What this means: the mail-nudge order is registered but its dispatch
loop hasn't ticked against these sessions in over ${STALE_THRESHOLD_SEC}s. Cross-city
mail to these sessions WILL NOT trigger an autonomous wake — the peer
will appear to be ignoring inbound until the next human prompt fires
the UserPromptSubmit hook.

Common causes:

  1. The supervisor reload was silently rejected (see check-reload-state).
     Symptom: order is in 'gc order list' but the controller's dispatch
     loop is on a stale snapshot from supervisor startup.
  2. The order definition was added but supervisor not restarted (see
     issue #31). Workaround: gc-reload-orders.
  3. The mail-nudge order itself is failing on every tick. Test manually:
       gc order run mail-nudge
     If that succeeds and updates the state file, the order works; the
     issue is the dispatch loop. If it fails, the order needs investigation.

Fix path:

  1. Run 'gc order check' and verify mail-nudge shows 'no cooldown'
     plus a recent 'last run' entry in 'gc order history mail-nudge'.
  2. If history shows last run >> 2× interval, restart the supervisor
     (or gc-reload-orders) and re-check.
  3. Re-run this doctor check after restart.

EOF
exit 1
