# Refinery Materialization

> **Status:** root cause identified for `dv-gascity-utils/gastown.refinery` (and `synth-panel/gastown.refinery`) sticking at `reserved-unmaterialized (on_demand)` even when polecat branches are queued. Manual wake recipe verified live. Follow-up bead `dgu-fze` filed for the proper formula/prompt fix.

## The symptom

`gc status` shows the refinery's named-session slot stuck at:

```
dv-gascity-utils/gastown.refinery   reserved-unmaterialized (on_demand)
```

…while polecat branches sit unmerged on `origin` and the Refinery never spawns to consume them. Mayor's workaround has been to `git merge --no-ff && git push` each branch by hand. `gc session new dv-gascity-utils/gastown.refinery --no-attach` *appears* to start something — `Session yg-x9zhv created` — but `gc status` still reports the named slot as `reserved-unmaterialized`. The session shows up in `gc session list` but not in the named-slot accounting.

## What's actually going on

Two independent things are conspiring.

### 1. The refinery is `mode = "on_demand"`

`packs/gastown/pack.toml` declares the named-session lifecycle modes:

```toml
[[named_session]]
template = "witness"
scope = "rig"
mode = "always"

[[named_session]]
template = "refinery"
scope = "rig"
mode = "on_demand"
```

`always` sessions are spawned by the reconciler at startup and kept alive — that's why witnesses just work. `on_demand` sessions are kept asleep until the reconciler decides there's work for them. The reconciler reports its decision per template-tick in the `template_tick_summary` trace record, and the relevant field is `fields.work_requested`.

Pull last-day refinery ticks and you see:

```
$ gc trace show --since 24h --type template_tick_summary | jq '
    [.[] | select(.template == "dv-gascity-utils/gastown.refinery")] |
    {ticks: length, work_req_true: ([.[] | select(.fields.work_requested == true)] | length)}'
{
  "ticks": 48,
  "work_req_true": 0
}
```

Compare the polecat pool over the same window: `work_req_true: 53` of 124 ticks. So the polecat side of the routing demonstrably works; only the refinery side is silent.

### 2. The polecat done-sequence routes to the wrong name

The reconciler's `namedWorkReady` check matches **bead assignee against the named session's full template name** — for the refinery that is `dv-gascity-utils/gastown.refinery` (rig prefix + `gastown.` namespace + agent base). The polecat work query for its own pool already uses that full form: `gc.routed_to=dv-gascity-utils/gastown.polecat`. Bead `dgu-3u9` (this very investigation's work bead) carries `gc.routed_to: "dv-gascity-utils/gastown.polecat"` and the polecat pool reconciler matches it. That side is healthy.

The terminal step of `mol-polecat-work.toml` does not use the same convention when handing off to the refinery:

```bash
# packs/gastown/formulas/mol-polecat-work.toml, step submit-and-exit
gc bd update {{issue}} --status=open \
  --assignee=<rig>/refinery \
  --set-metadata gc.routed_to=<rig>/refinery
```

For `dv-gascity-utils` that expands to `assignee=dv-gascity-utils/refinery` — the `gastown.` segment is missing. The named session is `dv-gascity-utils/gastown.refinery`, so `namedWorkReady` does not see this bead as belonging to the slot, `work_requested` stays `false`, and the on-demand reconciler never wakes the refinery. The same short form is duplicated in:

- `packs/gastown/agents/polecat/prompt.template.md` (the polecat done-sequence the agent prompt instructs)
- `packs/gastown/template-fragments/approval-fallacy.template.md`

Three call-sites, all wrong in the same way.

Direct evidence: bead `dgu-wisp-ip7a` is currently `assignee: dv-gascity-utils/refinery` (poured by the patrol loop after mayor manually merged dgu-2ro). It has been sitting there since `2026-04-28T06:06:10Z`, the refinery template kept emitting `work_requested: false` for the entire interval, and no reconciler wake fired.

### 3. Why mayor's manual `gc session new` looked like a no-op

`gc session new dv-gascity-utils/gastown.refinery --no-attach` *did* create a session — `yg-x9zhv` — but inspect it and you see:

```
Template:    "dv-gascity-utils/gastown.refinery"
Alias:       ""
SessionName: "s-yg-x9zhv"
```

Compare the witness, which is bound correctly:

```
Template:    "dv-gascity-utils/gastown.witness"
Alias:       "dv-gascity-utils/gastown.witness"
SessionName: "dv-gascity-utils--gastown__witness"
```

`gc session new` does not auto-bind to the named-session slot — you have to pass `--alias` (or use a different command, see below). Without an alias, the session is anonymous; the reconciler does not credit it toward the named-slot's max-active-sessions accounting and `gc status` keeps reporting `reserved-unmaterialized`. The session can still process work in practice (mayor's `yg-x9zhv` did merge dgu-2ro and pour the next patrol wisp), but the controller will not restart it on crash and a future controller restart will leave the slot empty again.

## Working manual recipe (verified 2026-04-28)

When the queue stalls, materialize the refinery with `gc session wake`:

```bash
gc session wake dv-gascity-utils/gastown.refinery
# → Session yg-XXXXX: wake requested.
```

Verify it bound to the slot — `Alias` should equal the named-session FQN, not be empty:

```bash
gc session list --json | jq '.[] | select(.Template == "dv-gascity-utils/gastown.refinery") | {ID, State, Alias, SessionName}'
# Expected:
# {
#   "ID": "yg-XXXXX",
#   "State": "creating",   # then "active" on next tick
#   "Alias": "dv-gascity-utils/gastown.refinery",
#   "SessionName": "dv-gascity-utils--gastown__refinery"
# }
```

`gc status` should flip the named slot from `reserved-unmaterialized` to `creating` and then `awake/active`:

```
dv-gascity-utils/gastown.refinery   creating (on_demand)
```

`gc session new <fqn>` is *not* the right tool unless you also pass `--alias <fqn>` — confirmed live, the no-`--alias` form leaves the slot unbound. `gc session wake <fqn>` does the binding for you.

The new refinery session reads its prompt, pours/picks up a `mol-refinery-patrol` wisp, and starts draining the queue. There is no need to mail it or to set additional metadata; the patrol loop watches `bd events` once it's running.

### Sweeping mis-routed beads

The polecat done-sequence has been writing the short form for a while, so the queue contains beads that the materialized refinery's `bd list --assignee="$GC_ALIAS"` query may not see. To list them:

```bash
gc bd list --assignee=dv-gascity-utils/refinery --status=open
```

Each one should be either (a) reassigned to the full form so the refinery picks it up, or (b) handled by the active session whose `$GC_ALIAS` was *also* set to the short form (mayor's yg-x9zhv operated this way). One-shot remediation:

```bash
gc bd update <bead-id> --assignee=dv-gascity-utils/gastown.refinery
```

The prompt's "find work" patterns (`bd list --assignee=$GC_ALIAS`) work either way — what matters for materialization is the reconciler's view, not the refinery's own scan.

## Proper fix (follow-up)

The clean fix is alignment: every place that routes to the refinery should use the **full template name** `<rig>/gastown.refinery`, the same convention the polecat pool already uses for itself. Three files to update:

1. `packs/gastown/formulas/mol-polecat-work.toml` — step `submit-and-exit`, the `gc bd update` line.
2. `packs/gastown/agents/polecat/prompt.template.md` — the "FINAL REMINDER" done-sequence block.
3. `packs/gastown/template-fragments/approval-fallacy.template.md` — same done-sequence pattern.

Replace `<rig>/refinery` with `<rig>/gastown.refinery` (template-rendered as `{{ .RigName }}/gastown.refinery` in the prompt files). The Refinery's own startup (`gc bd list --assignee="$GC_ALIAS"`) keeps working because in a properly-bound named session, `$GC_ALIAS` equals the full template name.

Confidence is high that this is sufficient: the polecat pool uses exactly this convention and its `work_requested` count is non-zero. No reconciler/controller change is required — only the formula and two prompt templates. Tracking bead: `dgu-fze`.

## Reference: what the trace says

```bash
# Per-template work_requested signal:
gc trace show --since 24h --type template_tick_summary | jq '
  [.[] | select(.template | test("(refinery|polecat)$"))] |
  group_by(.template)[] |
  {template: .[0].template,
   ticks: length,
   work_req_true: ([.[] | select(.fields.work_requested == true)] | length),
   last_open: (last | .fields.open_count),
   last_pool: (last | .fields.pool_desired),
   last_reason: (last | .reason_code)}'
```

Sample output (this investigation):

```
{"template": "dv-gascity-utils/gastown.polecat",  "ticks": 124, "work_req_true": 53, ...}
{"template": "dv-gascity-utils/gastown.refinery", "ticks":  48, "work_req_true":  0, ...}
```

The 0 vs 53 contrast across the same controller, same rig, same time window is the cleanest available diagnostic for "is on-demand demand getting through?"
