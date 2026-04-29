# gc-fix-alias-mismatch-suffix.pl — perl rewrites for the suffix-aware
# refinery claim. Invoked by gc-fix-alias-mismatch under perl -i -0777
# (slurp mode) so multi-line patterns and section injection work in one
# pass. Three transformations:
#
#   (a) mol-refinery-patrol.toml find-work step — inject a REFINERY_ALIAS
#       derivation that strips a trailing -N from $GC_AGENT, then swap the
#       work-bead claim query to use it.
#   (b) agents/refinery/prompt.template.md — insert an "Alias Derivation"
#       section before "Sequential Rebase Protocol" if missing.
#   (c) agents/refinery/prompt.template.md quick-reference row — swap the
#       work-bead claim query from $GC_ALIAS to $REFINERY_ALIAS.
#
# Each rewrite is pattern-idempotent: re-running matches nothing because
# the post-fix text doesn't satisfy the unfixed-pattern detector.

# (a) Formula find-work injection.
s{^(\s*)WORK=\$\(gc bd list --assignee=\$GC_AGENT --status=open}{${1}REFINERY_ALIAS=\$(printf '%s' "\$GC_AGENT" | sed -E 's/-[0-9]+\$//')\n${1}WORK=\$(gc bd list --assignee="\$REFINERY_ALIAS" --status=open}gm;

# (b) Refinery prompt — inject Alias Derivation section if missing.
if (m{^## Sequential Rebase Protocol}m && !m{^## Alias Derivation}m) {
    my $section = q{## Alias Derivation

The runtime may spawn this refinery with a slot-suffixed alias
(`{{ .RigName }}/gastown.refinery-1` when `min_active_sessions` is set),
but polecats canonicalize work-bead assignees to the unsuffixed form
`{{ .RigName }}/gastown.refinery`. Strip the suffix to match either
form on work-bead claim queries:

```bash
REFINERY_ALIAS=$(printf '%s' "$GC_ALIAS" | sed -E 's/-[0-9]+$//')
```

Use `$REFINERY_ALIAS` for work-bead claim queries (`--status=open`).
Wisp lookups, wisp assignments, and event watches stay on `$GC_ALIAS`
because those are session-bound to this specific slot.

---

};
    s{^(## Sequential Rebase Protocol)}{$section$1}m;
}

# (c) Refinery prompt quick-ref — swap to $REFINERY_ALIAS.
s{(\| Find assigned work \|\s*`gc bd list --assignee=)"?\$GC_ALIAS"?(\s+--status=open[^`]*`\s*\|)}{${1}"\$REFINERY_ALIAS"${2}}gm;
