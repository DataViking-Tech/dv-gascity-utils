# Agent Alias Canonicalization

Why `<rig>/gastown.<role>` is the canonical agent-alias form, how short-form
references silently break routing, and the audit + fixer workflow that keeps
installed packs aligned.

## The problem class

Gas City addresses agents by a two-part name: the rig prefix and the
agent's pack-namespaced base. The reconciler's `namedWorkReady` check
matches an assignee against the **full pack-prefixed agent name** —
i.e. `<rig>/<pack>.<role>`, where `<pack>` is the pack that defines the
agent. For gastown-namespaced agents the canonical form is:

```
<rig>/gastown.refinery
<rig>/gastown.polecat
<rig>/gastown.witness
<rig>/gastown.dog
```

If a template emits the SHORT form (`<rig>/refinery`) at runtime — through
an `--assignee=`, `gc.routed_to=`, `pool:` label, or a `gc nudge` /
`gc mail send` recipient — the reconciler's match fails silently:

- The on-demand agent slot never wakes (no session is started).
- The bead sits at status `open` with the wrong assignee.
- Polecats with full-form claim queries (`gc bd list --assignee=<rig>/gastown.polecat`)
  never see the rerouted bead.
- The only signal is `poolDesired` log lines that never fire.

This is an entire **class** of bugs, not a single site. We've hit it
three times already:

| Bead | Surface |
|------|---------|
| `dgu-fze` | Polecat done-sequence wrote `<rig>/refinery`; on-demand refinery slot never spawned. |
| `dgu-3u9` | Root-cause writeup for the refinery materialization failure. |
| `dgu-wrdjs` | Refinery rejection path wrote `<rig>/polecat`; polecats with full-form claim queries missed the bead. |
| `dgu-yykmt` | This bead — generalize the fix instead of patching site-by-site. |

## Why pack-namespacing exists

A rig may host agents from multiple packs (e.g. `gastown.polecat`
alongside `wyvern.tester` if a hypothetical `wyvern` pack defined its
own polecat-style agent). The pack prefix disambiguates: there is no
ambiguous bare `polecat` to assign to.

For rigs that only use the gastown pack (every rig in this codebase),
the prefix is always `gastown.`. The audit and fixer assume this; rigs
that adopt other packs would need different canonical forms (out of
scope here).

## Three rig-token surfaces

Templates emit aliases via three tokens, depending on context:

| Token | Where it appears | Substitution |
|-------|------------------|--------------|
| `<rig>` | formula step bodies, agent prompts (literal placeholder) | Manually substituted by the reading agent |
| `{{ .RigName }}` | agent prompt templates (Go template) | Rendered at prompt-render time |
| `$GC_RIG` | shell scripts inside formula step bodies | Resolved at process start |

Each is a legitimate way to template the rig name. The bug class is
*the role part after the slash* — the missing `gastown.` prefix.

## What the audit catches (and what it doesn't)

`gc-audit-alias-mismatch` walks every installed system pack and flags
short-form aliases. The detection regex (POSIX ERE):

```
(<rig>|\{\{ *\.RigName *\}\}|\$GC_RIG)/(refinery|polecat|witness|dog)([^A-Za-z0-9_-]|$)
```

Trailing-context rules keep us from flagging:

- `polecats` (plural) — next char is alphanumeric, not boundary.
- `polecat-name` — next char is `-`, which is also excluded.
- `{{.Rig}}/refinery` — that's a path token (`work_dir = ".gc/worktrees/{{.Rig}}/refinery"`),
  not an alias. The audit requires `.RigName` (with `Name`), not bare `.Rig`.
- `mayor/dog`, `just/dog/whatever` — no rig token, so not flagged. (Dog
  is sometimes city-scoped without a rig prefix.)

Already-canonical forms (`<rig>/gastown.refinery`) don't match because
the segment after `/` starts with `gastown.`, not the bare role base.

The audit is read-only and exits non-zero when findings exist (suitable
for CI gating). Use `--no-fail` to report-only, or `--json` for
machine-readable output.

## What the fixer rewrites

`gc-fix-alias-mismatch` applies the canonical replacement via Perl
in-place rewrite. Replacement: insert `gastown.` between the rig token
and the role base name, preserving any trailing context character.

```
<rig>/refinery"            → <rig>/gastown.refinery"
{{ .RigName }}/witness     → {{ .RigName }}/gastown.witness
$GC_RIG/polecat            → $GC_RIG/gastown.polecat
pool:<rig>/polecat         → pool:<rig>/gastown.polecat
```

It's idempotent: re-running on a fixed pack reports `no short-form
patterns found`. Add `--dry-run` to preview without touching files,
`--pack=<name>` to limit the rewrite to a single pack (e.g.
`--pack=gastown`).

## Pattern B — bare `pool` field in order/formula TOMLs

A second alias-mismatch surface, same class of bug, different shape.
Order TOMLs (and the formulas that template them) carry a `pool` field
that names the agent template the order dispatches to. The supervisor's
dispatch query expects the FQN form (`gastown.dog`), but stock pack
TOMLs emit the bare role name (`dog`). Result: the supervisor never
matches a real pool, the order's session never spawns, work piles up.

(Tracking: mg-ovjgn. Validation set on midgard: 16 orphan beads recovered
manually before the fixer extension landed — mg-201z+3, mg-gjr7+3,
mg-oc06+3, mg-wg2cp+3, all with metadata.gc.routed_to flipped from `dog`
to `gastown.dog`.)

The fixer's pattern B detection (POSIX ERE):

```
^pool[[:space:]]*=[[:space:]]*"(refinery|polecat|witness|dog)"[[:space:]]*$
```

Anchored to line start and end, so the rewrite is intentionally NARROW:

- `pool = "dog"` (whole line) — rewritten to `pool = "gastown.dog"`.
- `pool: <rig>/dog` (label form, embedded) — handled by pattern A, not B.
- `gateway_pool = "dog"`, `polecat_namepool = "..."` — not anchored to
  bare `pool`, so untouched.
- `pool = "dog-quotes-with-suffix"` — value not in the role vocabulary
  (`refinery|polecat|witness|dog`), untouched.

Scope is limited to `*.toml` (the `pool` field has no meaning in `.md`).

The audit script (`gc-audit-alias-mismatch`) does NOT yet flag pattern B
findings — extension pending. For now, dry-run the fixer to see them:

```bash
gc-fix-alias-mismatch --dry-run | grep 'pattern B'
```

## Doctor check

`packs/gascity-comms/doctor/check-alias-mismatch/run.sh` wraps the audit
for `gc doctor`. It scans the current city's installed packs (via
`$GC_CITY`) and:

- Exits 0 + `"no short-form agent alias mismatches"` on a clean tree.
- Exits 1 + the audit findings + a hint to run the fixer when drift
  appears.

Run it after every `gc reload` if you've seen pack templates regenerate.

## The runbook

After every `gc reload`, pack import, or fresh install:

```bash
# Inspect findings (read-only)
gc-audit-alias-mismatch
gc-audit-alias-mismatch ~/yggdrasil           # one town
gc-audit-alias-mismatch --json | jq .         # machine-readable

# Apply the canonical replacement
gc-fix-alias-mismatch --dry-run               # preview
gc-fix-alias-mismatch                         # apply (default: every host town)
gc-fix-alias-mismatch ~/yggdrasil             # one town
gc-fix-alias-mismatch --pack=gastown          # one pack

# Verify
gc-audit-alias-mismatch                       # should report 0 findings
```

The `gc-fix-refinery-routing` shim still works (forwards to
`gc-fix-alias-mismatch`) — keep it symlinked if you have existing
muscle memory or scripts that call it by the old name.

## Caveats

**Pack-source upstream is out of scope.** This codebase doesn't own
the gastown pack; the audit + fixer rewrite the *installed* pack tree
at `~/<town>/.gc/system/packs/gastown/`. If `gc reload` re-syncs from
an upstream that ships short-form templates, drift returns and the
fixer must be re-run. The doctor check is the long-term watchtower.

**Pack-specific canonicalization.** The fixer hard-codes `gastown.` as
the canonical pack prefix. Cities that use only the gastown pack
(everywhere we've shipped) get the right answer. A multi-pack city
where some agents come from a different pack would need
parameterization — file an upstream bead if that becomes a real shape.

**In-flight sessions are not retroactively fixed.** Templates are
rendered at session-start. Long-running sessions hold the pre-fix
prompt in memory; the fix lands at the next session start. This is
fine for the gastown architecture (sessions are short-lived) but
worth flagging for refinery/witness sessions that run for hours.
