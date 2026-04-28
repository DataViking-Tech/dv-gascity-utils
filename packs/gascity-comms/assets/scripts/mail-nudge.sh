#!/usr/bin/env bash
# mail-nudge.sh — wake named always-on sessions when their inbox grows.
#
# Runs from a cooldown-triggered order (mail-nudge.toml). For each active
# named session in this city, checks unread count and nudges when it has
# increased since the previous tick. The per-session "last unread" count
# is tracked in $GC_CITY_RUNTIME_DIR/mail-nudge/<session>.last_unread, so
# steady-state inbox volume doesn't trigger repeated nudges — only mail
# arrival does.
#
# The nudge uses --delivery wait-idle so it queues until the recipient is
# at a safe interactive boundary; sessions in the middle of a turn aren't
# interrupted.

set -euo pipefail

state_dir="${GC_CITY_RUNTIME_DIR:-/tmp}/mail-nudge"
mkdir -p "$state_dir"

# Active sessions with an alias. Closed/suspended sessions get skipped
# automatically because gc session list defaults to active+suspended only.
sessions_json=$(gc session list --state active --json 2>/dev/null || echo "[]")

aliases=$(printf '%s' "$sessions_json" | jq -r '.[] | select(.Alias != null and .Alias != "") | .Alias' | sort -u)

for alias in $aliases; do
    [ -z "$alias" ] && continue

    # gc mail count prints e.g. "3 total, 1 unread for gastown.mayor".
    # Parse the unread number; default to 0 on any failure.
    count_line=$(gc mail count "$alias" 2>/dev/null || echo "0 total, 0 unread for $alias")
    unread=$(printf '%s' "$count_line" | awk '{for (i=1;i<=NF;i++) if ($i=="unread") {print $(i-1); exit}}')
    [ -z "$unread" ] && unread=0

    state_file="$state_dir/$alias.last_unread"
    prev=0
    [ -f "$state_file" ] && prev=$(cat "$state_file")

    if [ "$unread" -gt "$prev" ]; then
        delta=$((unread - prev))
        # Don't fail the whole order on a single nudge failure — the session
        # may have just exited or be unreachable.
        gc session nudge "$alias" \
            "📬 inbox grew by $delta (now $unread unread). run 'gc mail inbox' to see them." \
            --delivery wait-idle >/dev/null 2>&1 || true
    fi

    printf '%s\n' "$unread" > "$state_file"
done
