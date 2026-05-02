#!/usr/bin/env bash
# Pack doctor check: supervisor reload acceptance state.
#
# Symptom this catches: when supervisor reload fails validation
# (e.g. duplicate-agent, beads-init killed, invalid endpoint state),
# it logs 'keeping old config' once and goes quiet. ALL subsequent
# city.toml edits are silently dropped against the controller — the
# operator believes their changes are live but they aren't.
#
# Concrete trace from midgard, 2026-05-02: 4 hours of [[orders.overrides]]
# edits dropped because an unrelated dgu .beads/config.yaml validation
# was rejecting reload. mol-dog-jsonl spam continued, mail-nudge order
# I'd registered didn't dispatch. The 'keeping old config' log line was
# the only signal — invisible from any gc CLI surface.
#
# Detection rule: scan the supervisor log for the most recent reload
# outcome. If 'keeping old config' is the most recent reload event
# (with no successful 'config reload accepted' or equivalent after it),
# the controller is on a stale snapshot.
#
# Exit codes: 0=OK, 1=Warning (rejected reload is the most recent), 2=Error
# stdout: first line=summary, rest=details

set -euo pipefail

LOG_PATH="${SUPERVISOR_LOG:-$HOME/.gc/supervisor.log}"

if [ ! -e "$LOG_PATH" ]; then
    echo "supervisor log not found at $LOG_PATH"
    echo "(set SUPERVISOR_LOG to override; default is \$HOME/.gc/supervisor.log)"
    exit 2
fi

# Scan the tail for reload outcomes. We want the MOST RECENT reload
# event. 'keeping old config' is the rejection signal; an absence of
# rejection lines after the previous reload-accept-equivalent (which
# the binary doesn't always log explicitly) is the OK signal.
#
# Tunable: how many lines to scan back. 5000 lines is a few hours on
# a busy controller. Override via RELOAD_SCAN_LINES.
SCAN_LINES="${RELOAD_SCAN_LINES:-5000}"

# Find the most recent reload-related line (either keeping-old-config
# or a successful reload signal). The binary logs 'config reload:
# validating ...' at the start of every reload attempt, so use that
# as the anchor.
last_reload=$(tail -n "$SCAN_LINES" "$LOG_PATH" 2>/dev/null \
    | grep -nE "config reload:|Reconciliation triggered" \
    | tail -n 5 || true)

if [ -z "$last_reload" ]; then
    # No reload activity in scan window — either controller hasn't
    # reloaded recently (fine) or scan window is too short.
    echo "no reload activity in last $SCAN_LINES log lines (nothing to validate)"
    exit 0
fi

# Extract the most recent rejection if any.
last_rejection=$(echo "$last_reload" | grep "keeping old config" | tail -1 || true)

if [ -z "$last_rejection" ]; then
    echo "supervisor reload state OK (no recent 'keeping old config' rejections)"
    exit 0
fi

# Found a rejection. Surface the rejection text + the operator
# guidance.
echo "supervisor reload REJECTED — controller is on a stale config snapshot"
echo
echo "Most recent rejection (from $LOG_PATH):"
echo "  $last_rejection"
echo

# Try to extract the validation error reason for the operator. The
# rejection line typically contains 'validating agents: ...' or
# 'beads lifecycle: ...' or 'invalid ... state' before the
# '(keeping old config)' suffix.
reason=$(echo "$last_rejection" \
    | sed -E 's/.*config reload: ?//; s/ ?\(keeping old config\)$//' \
    || true)
if [ -n "$reason" ]; then
    echo "Reason:"
    echo "  $reason"
    echo
fi

cat <<EOF
Fix:
  1. Resolve the underlying validation error in the rejection reason.
     Common causes:
       - Duplicate agent name (workspace pack auto-discovers agents/<role>/
         and collides with an imported pack — see PR #17 wiring-gap doc)
       - 'inherited_city' endpoint without dolt.host/port (see issue #30)
       - Adopted rig with .beads/config.yaml gc.endpoint_status=unverified
         triggering bd init that hits the auth bug (see issue #29)
       - bd init for a rig timing out / SIGKILL'd by the supervisor
  2. After the file change, run 'gc supervisor reload' (or gc-reload-orders)
  3. Re-run this doctor check to confirm clean

Side-effect of this rejection: ALL city.toml [[orders.overrides]] edits,
new [[rigs]] additions, and other config changes since the rejection are
silently dropped against the running controller. Verify your edits are
actually live via 'gc config show' AND via behavioral check (e.g. is the
order you expected to disable still firing).

EOF
exit 1
