#!/usr/bin/env bash
# Pack doctor check: cross-city-prime fragment wiring.
#
# When a host imports gascity-comms, it gets the cross-city-prime
# template fragment defined — but the fragment only takes effect if
# the host wrote a mayor-prompt override that invokes it (per
# docs/mayor-prompt-prime-recipe.md).
#
# Without the override, every fresh mayor session on this host comes
# up oriented to the upstream gastown mayor template alone — no
# knowledge of gcx, peers.toml, the gateway, or the X-Gascity-Origin
# convention. Empirically this leads to mayors "discovering"
# cross-city is unsupported and writing direct dolt INSERTs into
# peer wisps tables, bypassing the entire gateway/auth/nudge stack.
#
# This check renders the resolved mayor prompt and looks for the
# fragment's marker H2 ("Cross-City Operational Prime"). Missing →
# warning with the recipe path.
#
# Exit codes: 0=OK, 1=Warning (wiring missing), 2=Error
# stdout: first line=summary message, rest=details

set -euo pipefail

# Sentinel string from packs/gascity-comms/template-fragments/
# cross-city-prime.template.md. If the fragment is rendered, this
# will appear in `gc prime mayor`. Keep in sync if the fragment H2
# ever changes.
SENTINEL="Cross-City Operational Prime"

# Resolve the gc binary. Default install is /opt/homebrew/bin/gc on
# macOS but $GC_BIN overrides for tests / non-standard installs.
GC_BIN="${GC_BIN:-gc}"
if ! command -v "$GC_BIN" >/dev/null 2>&1; then
    echo "gc binary not found on PATH (looked for: $GC_BIN)"
    exit 2
fi

# `gc prime mayor` needs a city in scope. The doctor harness sets
# GC_CITY; respect it via --city to avoid cwd-walking surprises.
prime_args=(prime mayor)
if [ -n "${GC_CITY:-}" ]; then
    prime_args=(--city "$GC_CITY" "${prime_args[@]}")
fi

# Render and capture. `gc prime` shouldn't fail on a healthy city,
# but if it does we surface that as an Error (exit 2) so the
# operator sees the underlying problem, not a false negative.
if ! prompt=$("$GC_BIN" "${prime_args[@]}" 2>&1); then
    echo "could not render mayor prompt via 'gc prime mayor'"
    echo "---"
    echo "$prompt"
    exit 2
fi

if printf '%s' "$prompt" | grep -qF "$SENTINEL"; then
    echo "cross-city-prime fragment is wired into the mayor prompt"
    exit 0
fi

# Wiring missing. Help the operator find the recipe and the two
# files they need to write.
echo "cross-city-prime fragment is NOT wired into the mayor prompt"
cat <<'EOF'

The gascity-comms pack is imported (this check would not run otherwise),
but the host hasn't completed the per-host opt-in. Fresh mayor sessions
will come up without knowledge of gcx, peers.toml, the Tailscale gateway,
or the X-Gascity-Origin convention — and have been observed to bypass
the entire stack via direct dolt INSERTs into peer wisps tables.

Fix (per docs/mayor-prompt-prime-recipe.md and
docs/cross-city-prime-wiring-gap.md):

  1. Write a host-local mayor template override at:
       <city-root>/agents/mayor/prompt.template.md
     Copy from:
       <city-root>/.gc/system/packs/gastown/agents/mayor/prompt.template.md
     After {{ template "propulsion-mayor" . }}, insert:
       {{ template "cross-city-prime" . }}
     Then INLINE this host's facts directly at the same insertion
     point (Tailscale IP, peers from ~/.gc/peers.toml, active rigs,
     recent local decisions). Do NOT use a separate prime.local.md
     with {{ template "local-prime" . }} — the indirection looks
     correct but the host-local fragment location isn't scanned by
     gc's template loader. Inline content in the override file is
     the supported path. See docs/host-prime-stub.md for the
     content guide (4 questions to answer).

  2. Run `gc reload` (or `gc supervisor reload` if the city
     controller is busy).

Re-run `gc doctor` after to verify.
EOF
exit 1
