#!/usr/bin/env bash
# Pack doctor check: short-form-vs-full-form agent alias mismatches.
#
# Walks every installed system pack and flags places where templates emit
# short-form aliases (<rig>/<role>) instead of canonical <rig>/gastown.<role>.
# These mismatches cause silent routing failures: the reconciler matches
# assignees against the FULL pack-prefixed agent name, so short-form
# assignments never wake the on-demand agent slot.
#
# Implementation: forwards to gc-audit-alias-mismatch. Pair with
# gc-fix-alias-mismatch to repair findings.
#
# Exit codes: 0=OK, 1=Warning (findings present), 2=Error
# stdout: first line=summary message, rest=details

set -euo pipefail

dir="${GC_PACK_DIR:-.}"
audit="$dir/assets/scripts/gc-audit-alias-mismatch"

if [ ! -x "$audit" ]; then
    echo "audit script missing or not executable: $audit"
    exit 2
fi

# Scope: audit only the current town's installed system packs. GC_CITY is
# the town root path (e.g. /Users/mani/yggdrasil); other towns on the same
# host run their own doctor and should not cross-contaminate this report.
audit_args=(--quiet)
if [ -n "${GC_CITY:-}" ] && [ -d "$GC_CITY/.gc/system/packs" ]; then
    audit_args+=("$GC_CITY")
fi

ec=0
"$audit" "${audit_args[@]}" >/dev/null 2>&1 || ec=$?

case "$ec" in
    0)
        echo "no short-form agent alias mismatches in installed system packs"
        exit 0 ;;
    1)
        echo "short-form agent alias mismatches found in installed system packs"
        echo
        echo "Run gc-fix-alias-mismatch to apply canonical replacements."
        echo
        # Re-run without --quiet to print findings for the operator.
        "$audit" "${audit_args[@]:1}" || true
        exit 1 ;;
    *)
        echo "audit script failed (exit $ec)"
        exit 2 ;;
esac
