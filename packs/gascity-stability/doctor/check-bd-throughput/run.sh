#!/usr/bin/env bash
# Pack doctor check: bd write throughput.
#
# Symptom this catches: every `bd create` / `bd update` / `bd close`
# hangs 30s+ on a failing post-write hook chain. Stderr shows
#
#   Warning: auto-backup failed: register backup remote: add backup
#     backup_export: Error 1105 (HY000): failed to create directory
#     '/Users/<user>/<rig>/.beads/backup': mkdir /Users/<user>:
#     permission denied
#   Warning: auto-export: git add failed: exit status 1
#
# The actual dolt write completes in ~50ms; the rest is the hook chain
# timing out. Throughput killer for any operator working in cross-rig
# beads — slinging 3 beads can eat ~6 minutes wall-clock.
#
# Concrete trace: midgard 2026-05-02, `gc bd update dgu-emwy6 --rig
# dv-gascity-utils ...` ran 2m13s for a write the dolt server processed
# in ~50ms. See dv-gascity-utils issue #32 and
# docs/known-binary-bugs.md 'bd auto-backup hook tries to mkdir the
# user's home dir'.
#
# Detection rule: walk every rig in the city. For each, create a
# canary bead via `bd q`, time the create, then close the bead. Fail
# if any create exceeds $BD_THROUGHPUT_THRESHOLD_SEC (default 5s).
# Hard-cap each operation at $BD_THROUGHPUT_HARD_CAP_SEC (default 30s)
# so the doctor doesn't itself hang on a wedged rig.
#
# Class: C — bd binary bug, requires upstream fix. This check is the
# detector; mitigation is sequential bd writes + direct dolt-query
# verification (see known-binary-bugs.md).
#
# Exit codes: 0=OK, 1=Warning (slow rig found), 2=Error
# stdout: first line=summary, rest=details (one line per rig)

set -euo pipefail

THRESHOLD_SEC="${BD_THROUGHPUT_THRESHOLD_SEC:-5}"
HARD_CAP_SEC="${BD_THROUGHPUT_HARD_CAP_SEC:-30}"
CANARY_LABEL="doctor-canary"
CANARY_TITLE="doctor: bd-throughput canary (auto-cleanup)"

GC_BIN="${GC_BIN:-gc}"
BD_BIN="${BD_BIN:-bd}"
if ! command -v "$GC_BIN" >/dev/null 2>&1; then
    echo "gc binary not found on PATH (looked for: $GC_BIN)"
    exit 2
fi
if ! command -v "$BD_BIN" >/dev/null 2>&1; then
    echo "bd binary not found on PATH (looked for: $BD_BIN)"
    exit 2
fi
if ! command -v python3 >/dev/null 2>&1; then
    echo "python3 not on PATH; cannot enforce per-operation timeout"
    exit 2
fi

# Run a command with a hard timeout and return its elapsed seconds
# (float). Writes the elapsed seconds to stdout, command stdout to
# stderr-then-discard. Exit code:
#   0 = command completed within hard cap
#   124 = timed out (matches `timeout(1)`)
#   other = command failed (forwarded)
timed_run() {
    local cap=$1; shift
    python3 - "$cap" "$@" <<'PY'
import os, signal, subprocess, sys, time
cap = float(sys.argv[1])
cmd = sys.argv[2:]
start = time.monotonic()
try:
    proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    try:
        out, err = proc.communicate(timeout=cap)
    except subprocess.TimeoutExpired:
        # Hard kill the process group so any forked hook chain dies too.
        try:
            os.killpg(os.getpgid(proc.pid), signal.SIGKILL)
        except Exception:
            proc.kill()
        proc.wait()
        elapsed = time.monotonic() - start
        print(f"{elapsed:.3f}\t\t")
        sys.exit(124)
    elapsed = time.monotonic() - start
    print(f"{elapsed:.3f}\t{out.decode('utf-8', 'replace')}\t{err.decode('utf-8', 'replace')}")
    sys.exit(proc.returncode)
except FileNotFoundError as e:
    print(f"-1\t\t{e}")
    sys.exit(127)
PY
}

# Build rig table from `gc config show` (same parser shape as
# check-pool-ramp/run.sh). Tab-delimited: <rig_name>\t<rig_path>\n
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

slow_count=0
slow_lines=()

while IFS=$'\t' read -r rig_name rig_path; do
    [ -z "$rig_name" ] && continue
    [ -d "$rig_path" ] || {
        slow_lines+=("  $rig_name: rig path missing ($rig_path) — skipped")
        continue
    }
    [ -d "$rig_path/.beads" ] || {
        slow_lines+=("  $rig_name: no .beads/ directory — skipped")
        continue
    }

    # Create canary bead with a hard cap. timed_run prints
    # "<elapsed>\t<stdout>\t<stderr>" on success; "<elapsed>\t\t" on
    # timeout. Capture id from stdout (bd q outputs the bead id).
    create_result=$(cd "$rig_path" && timed_run "$HARD_CAP_SEC" \
        "$BD_BIN" q "$CANARY_TITLE" --labels "$CANARY_LABEL" --priority 4 --type task 2>/dev/null) || rc=$?
    rc="${rc:-0}"
    elapsed=$(printf '%s' "$create_result" | head -1 | cut -f1)
    stdout_line=$(printf '%s' "$create_result" | head -1 | cut -f2)
    bead_id=$(printf '%s' "$stdout_line" | grep -oE '[a-z]+-[a-z0-9]+' | head -1 || true)

    if [ "$rc" = "124" ]; then
        slow_count=$((slow_count + 1))
        slow_lines+=("  $rig_name: bd write WEDGED (>${HARD_CAP_SEC}s, killed) — auto-backup hook likely failing")
        # No bead to clean up; the hung bd was killed before it returned an id.
        continue
    fi
    if [ "$rc" != "0" ] || [ -z "$bead_id" ]; then
        slow_lines+=("  $rig_name: bd q failed (rc=$rc, elapsed=${elapsed}s) — investigate")
        slow_count=$((slow_count + 1))
        continue
    fi

    # Always close the canary, even if the create was slow. Use the
    # same hard cap on the close to avoid hanging on the second write.
    (cd "$rig_path" && timed_run "$HARD_CAP_SEC" "$BD_BIN" close "$bead_id" >/dev/null 2>&1) || true

    # Compare elapsed against threshold. python3 to handle float math.
    over=$(python3 -c "print(1 if float('$elapsed') > float('$THRESHOLD_SEC') else 0)")
    if [ "$over" = "1" ]; then
        slow_count=$((slow_count + 1))
        slow_lines+=("  $rig_name: bd write took ${elapsed}s (>${THRESHOLD_SEC}s threshold, bead $bead_id closed)")
    fi
done <<< "$RIG_TABLE"

if [ "$slow_count" -eq 0 ]; then
    echo "all rigs pass bd write throughput check (<${THRESHOLD_SEC}s)"
    exit 0
fi

echo "${slow_count} rig(s) failing bd write throughput check (>${THRESHOLD_SEC}s)"
printf '%s\n' "${slow_lines[@]}"
cat <<EOF

bd writes are taking longer than the throughput threshold. The most
common cause is the auto-backup hook chain failing on a path-resolution
bug (see docs/known-binary-bugs.md 'bd auto-backup hook tries to mkdir
the user's home dir', dgu issue #32).

Verify by running an isolated 'bd update' against any open bead in the
slow rig and checking stderr for:

  Warning: auto-backup failed: register backup remote: add backup
    backup_export: ... mkdir /Users/<user>: permission denied

Mitigation:
  - Sling beads sequentially, not in parallel — they all fight the
    same failing mkdir, throughput is the same and stuck-process
    cleanup gets harder.
  - Verify writes via direct dolt query rather than waiting for bd to
    return:
      echo "SELECT id, status FROM <rig>.issues WHERE id='<bead>'" | gc dolt sql
  - 'pkill -f "bd update"' to clear stuck child processes if a wedge
    has already accumulated 4+ children per command.

Threshold tuning: BD_THROUGHPUT_THRESHOLD_SEC (default 5s) and
BD_THROUGHPUT_HARD_CAP_SEC (default 30s) override per-run.
EOF
exit 1
