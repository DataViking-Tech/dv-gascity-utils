#!/usr/bin/env bash
# Pack doctor check: ~/.gc/bin symlink targets are current.
#
# gc-city-bootstrap symlinks gcx and the gc-fix-* helpers into
# ~/.gc/bin/, pointed at ~/dv-gascity-utils/packs/gascity-comms/
# assets/scripts/. The script is idempotent, but only runs when an
# operator invokes it. Two failure modes have been observed:
#
#   1. Symlink target moved or deleted. Concrete case: mg's gcx was
#      symlinked at initial bootstrap pointed at the city's vendored
#      copy of gascity-comms. When mg later moved the vendored copy
#      aside (after switching its pack.toml import to point at the
#      shared repo), the symlink dangled. Result: cross-city sends
#      failed with "no such file or directory" until the symlink
#      was re-pointed by hand.
#
#   2. Symlink target outside the canonical ~/dv-gascity-utils tree.
#      Less critical — a developer testing a fork is a legitimate
#      reason — but worth surfacing as a warning so operators
#      notice when a symlink drifts off the standard layout.
#
# This check walks each candidate symlink in ~/.gc/bin/ and reports:
#   - missing target (broken symlink) → exit 1 (Warning)
#   - target outside $DV_REPO_PATH → reported, but does NOT change
#     exit status (informational)
#   - everything current → exit 0
#
# Exit codes: 0=OK, 1=Warning (broken symlink found), 2=Error
# stdout: first line=summary, rest=details

set -euo pipefail

BIN_DIR="${BIN_DIR:-$HOME/.gc/bin}"
DV_REPO_PATH="${DV_REPO_PATH:-$HOME/dv-gascity-utils}"

# Normalize DV_REPO_PATH so the realpath comparison below works on
# macOS (where /tmp and /private/tmp resolve identically but the
# string forms differ). Falls back to the un-normalized value if the
# path doesn't resolve.
if [ -d "$DV_REPO_PATH" ]; then
    DV_REPO_PATH=$(cd "$DV_REPO_PATH" && pwd -P)
fi

# Helpers the bootstrap script links. Keep this in sync with the
# HELPERS array in packs/gascity-comms/assets/scripts/gc-city-bootstrap.
# Order is bootstrap-script-relative; missing helpers in BIN_DIR are
# silently skipped (operator may have opted out of some).
HELPERS=(
    "gcx"
    "gc-fix-merge-strategy"
    "gc-fix-alias-mismatch"
    "gc-audit-alias-mismatch"
    "gc-fix-runtime-restart"
    "gc-fix-watch"
    "gc-events-rotate"
    "gc-fix-refinery-pr-body"
    "gc-rig-init"
    "gc-rig-join"
    "gc-warm-rig-pool"
    "gc-tune-refinery-loop"
    "gc-fix-refinery-routing"
    "gc-city-bootstrap"
)

if [ ! -d "$BIN_DIR" ]; then
    echo "$BIN_DIR does not exist — bootstrap not run on this host"
    exit 0
fi

broken=()
out_of_tree=()
checked=0

for h in "${HELPERS[@]}"; do
    link="$BIN_DIR/$h"
    [ -L "$link" ] || continue
    checked=$((checked + 1))

    target=$(readlink "$link")
    resolved=$(readlink -f "$link" 2>/dev/null || true)

    # Broken: resolved target doesn't exist on disk.
    if [ -z "$resolved" ] || [ ! -e "$resolved" ]; then
        broken+=("$h → $target")
        continue
    fi

    # Out-of-tree: resolved target lives outside the canonical
    # dv-gascity-utils path. Informational only.
    case "$resolved" in
        "$DV_REPO_PATH"/*) ;;
        *) out_of_tree+=("$h → $resolved") ;;
    esac
done

if [ "${#broken[@]}" -gt 0 ]; then
    echo "broken symlinks in $BIN_DIR (${#broken[@]} of $checked checked)"
    echo
    echo "Broken (target missing):"
    for entry in "${broken[@]}"; do
        echo "  $BIN_DIR/$entry"
    done

    if [ "${#out_of_tree[@]}" -gt 0 ]; then
        echo
        echo "Also out-of-tree (target outside $DV_REPO_PATH, informational):"
        for entry in "${out_of_tree[@]}"; do
            echo "  $BIN_DIR/$entry"
        done
    fi

    cat <<EOF

Fix:
  Re-run gc-city-bootstrap. It re-symlinks all known helpers
  idempotently and will repair broken pointers in one pass:

      $DV_REPO_PATH/packs/gascity-comms/assets/scripts/gc-city-bootstrap

  If you intentionally point a helper at a non-standard location
  (e.g. a dev fork), this check will flag it as out-of-tree but
  not fail. Broken pointers always fail.
EOF
    exit 1
fi

if [ "${#out_of_tree[@]}" -gt 0 ]; then
    echo "all $checked symlinks in $BIN_DIR resolve, ${#out_of_tree[@]} target(s) outside $DV_REPO_PATH (informational)"
    echo
    for entry in "${out_of_tree[@]}"; do
        echo "  $BIN_DIR/$entry"
    done
    echo
    echo "Out-of-tree targets are not failures — a developer testing a fork"
    echo "is a legitimate reason. Re-run gc-city-bootstrap to restore the"
    echo "canonical layout if these were unintentional."
    exit 0
fi

echo "all $checked symlinks in $BIN_DIR resolve under $DV_REPO_PATH"
exit 0
