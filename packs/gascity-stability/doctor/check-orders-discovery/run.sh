#!/usr/bin/env bash
# Pack doctor check: orders shipped in imported packs are actually loaded.
#
# Symptom this catches: gc only walks orders/ from packs reachable
# through the maintenance import chain (i.e. packs inside .gc/system/packs/
# transitively imported via gastown). Top-level [imports.X] in the city's
# pack.toml loads agents/fragments/templates from the imported pack but
# does NOT walk its orders/ directory. The docs/cross-city-comms.md step 8
# implies orders auto-load when the pack is imported — they don't.
#
# Concrete trace from midgard, 2026-05-02: gascity-comms imported via
# pack.toml [imports.gascity-comms]. Pack ships mail-nudge.toml,
# agent-watchdog.toml, pr-ci-watch.toml in its orders/ dir. None
# appeared in 'gc order list'. mail-nudge sat unloaded for 4+ days
# without anyone noticing — until the inbox went silent and we traced
# the mayor.last_unread state file mtime.
#
# Detection rule: for each pack imported via the workspace pack.toml,
# list the pack's orders/<name>.toml files and check whether each
# <name> appears in 'gc order list'. Warn on any missing.
#
# Exit codes: 0=OK, 1=Warning (orders shipped but not loaded), 2=Error
# stdout: first line=summary, rest=details

set -euo pipefail

GC_BIN="${GC_BIN:-gc}"
if ! command -v "$GC_BIN" >/dev/null 2>&1; then
    echo "gc binary not found on PATH (looked for: $GC_BIN)"
    exit 2
fi

CITY_ROOT="${GC_CITY:-$(pwd)}"
PACK_TOML="$CITY_ROOT/pack.toml"

if [ ! -e "$PACK_TOML" ]; then
    echo "no pack.toml at $CITY_ROOT (not a Gas City workspace, nothing to check)"
    exit 0
fi

# Render the order list once for diff checks below. Capture both
# names and source paths.
loaded_orders=$("$GC_BIN" --city "$CITY_ROOT" order list 2>/dev/null \
    | awk 'NR > 1 && $1 != "" {print $1}' \
    | sort -u || true)

if [ -z "$loaded_orders" ]; then
    echo "gc order list returned no orders — controller may not be running, or city has no imports"
    exit 2
fi

# Extract import sources from pack.toml. Match `source = "..."` lines
# inside [imports.X] blocks. Resolve relative to city root.
imports=$(awk '
    /^\[imports\./ { in_block = 1; next }
    /^\[/ { in_block = 0 }
    in_block && /^source *=/ {
        gsub(/^source *= */, "")
        gsub(/^"/, ""); gsub(/"$/, "")
        gsub(/^'\''/, ""); gsub(/'\''$/, "")
        print
    }
' "$PACK_TOML" || true)

if [ -z "$imports" ]; then
    echo "no [imports.X] blocks in $PACK_TOML — nothing to check"
    exit 0
fi

missing_orders=()
checked_packs=0

while IFS= read -r src; do
    [ -z "$src" ] && continue
    # Resolve relative to city root.
    case "$src" in
        /*) pack_dir="$src" ;;
        *) pack_dir="$CITY_ROOT/$src" ;;
    esac
    [ -d "$pack_dir/orders" ] || continue

    checked_packs=$((checked_packs + 1))
    pack_name=$(basename "$pack_dir")

    # For each orders/<name>.toml, check it appears in loaded_orders.
    for order_file in "$pack_dir"/orders/*.toml; do
        [ -e "$order_file" ] || continue
        order_name=$(basename "$order_file" .toml)
        if ! echo "$loaded_orders" | grep -qx "$order_name"; then
            missing_orders+=("$pack_name/$order_name")
        fi
    done
done <<< "$imports"

if [ "$checked_packs" -eq 0 ]; then
    echo "no imported packs ship orders/ directories (nothing to check)"
    exit 0
fi

if [ "${#missing_orders[@]}" -eq 0 ]; then
    echo "all imported-pack orders are loaded (checked $checked_packs pack(s))"
    exit 0
fi

echo "orders shipped in imported packs but NOT loaded by the controller (${#missing_orders[@]} missing across $checked_packs pack(s))"
echo
echo "Missing:"
for entry in "${missing_orders[@]}"; do
    echo "  $entry"
done

cat <<EOF

Why this happens: gc only walks orders/ from packs reachable through the
maintenance import chain (i.e. packs inside .gc/system/packs/ transitively
imported via gastown). Top-level [imports.X] in the city's pack.toml
loads agents and fragments from the imported pack, but skips its orders/
directory entirely.

Workaround until the binary fixes the discovery rule:

  1. Drop a copy of the order .toml into a discoverable path, e.g.:
       cp <pack>/orders/<name>.toml \\
          $CITY_ROOT/.gc/system/packs/maintenance/orders/<name>.toml
  2. If the order's exec references \$PACK_DIR/assets/scripts/<name>.sh,
     symlink the script into maintenance's assets/scripts/ too:
       ln -sf <pack>/assets/scripts/<name>.sh \\
              $CITY_ROOT/.gc/system/packs/maintenance/assets/scripts/<name>.sh
  3. Restart the supervisor (or run gc-reload-orders) so the dispatch
     loop picks it up.
  4. Re-run this check to confirm.

This is a docs+binary divergence — see docs/cross-city-comms.md step 8.
EOF
exit 1
