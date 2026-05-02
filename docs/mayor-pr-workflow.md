# Mayor PR Workflow

> **Status:** convention. Captures per-PR-opening discipline observed
> by mayor sessions across yg + mg, formalized after a 2026-05-02
> incident where a fresh PR's body listed three "open" companion PRs
> that had all merged. The cost is one `gh pr view` per reference
> (~1s); the cost of skipping it is shipping PR descriptions and
> coord mail that drift out of sync within hours.

## The rule

**Before listing previously-opened PRs in a new PR's body or in
cross-city coordination mail, verify each referenced PR's CURRENT
state via `gh pr view`.** Don't assume "open last time I checked"
still holds.

## Why

Cross-city + collaborative-loop sessions open PRs in clusters: a
diagnostic PR, a helper PR, a doc PR, sometimes more. Reviewers (yg
or mg humans, sometimes the other-city mayor) merge them in any
order, often within minutes of opening. By the time the *next* PR in
the cluster is being written, multiple PRs that were "open just now"
may have landed.

Listing those still as "open" in the new PR's "see also" or in
coord mail to the peer mayor is misinformation:

- Reviewers waste time clicking through to a merged PR thinking
  there's still review work.
- Cross-city coord drifts — mg may decline to deploy thinking yg
  is "still iterating" when in fact the work is in main.
- The new PR's own description loses credibility if any of its
  cross-references is obviously stale.

Concrete incident: PR
[#24](https://github.com/DataViking-Tech/dv-gascity-utils/pull/24)
opened with a "Other open PRs (mine)" footer listing #15, #19, #21,
#24. Post-open verification showed #15, #19, #21 had merged. Three
out of four claimed-open PRs were stale at the moment of opening.

## How

Before pasting the "see also" / "other open PRs" block, run:

```bash
for pr in <list-of-numbers>; do
    state=$(gh pr view "$pr" --repo <owner>/<repo> --json state --jq '.state')
    echo "  #$pr: $state"
done
```

Then group references by current state in the body:

```markdown
## See also

Open:
- #N — <one-line>

Recently merged (2026-05-02 yg-side cleanup):
- #M — <one-line>

Closed without merge:
- #X — <one-line, reason>
```

Or if grouping is overkill, drop merged/closed entries from the
"open" list entirely and link the merged ones inline elsewhere
(e.g., in the "Why now" or "Background" section).

## Same rule for cross-city mail

`gcx mail send midgard:gastown.mayor` messages that summarize PR
state to the peer mayor follow the same discipline. mg-mayor reads
them once and acts; if the snapshot is stale, mg makes deploy
decisions on stale data.

```bash
# Before drafting the mail body, snapshot:
for pr in 15 19 21 24; do
    gh pr view $pr --repo DataViking-Tech/dv-gascity-utils \
        --json number,state,title \
        --jq '"  #\(.number) [\(.state)] \(.title)"'
done
```

Paste the snapshot directly into the mail (or summarize). The peer
mayor sees current state, not last-known-state.

## When this rule does NOT apply

- The new PR's *own* body (the change being submitted). Don't
  cross-reference yourself.
- PRs in repos you don't have read access to (`gh pr view` will
  error; note them as "external" without state).
- Single-PR runs where there are no companion PRs to cross-reference
  — the rule is a no-op when the list is empty.

## Discipline, not tooling

This is a per-PR-opening checklist item, not a script that runs
automatically. The `gh` calls are too cheap to wrap in a helper, and
PR-opening is rare enough that adding tooling would be over-fitting.
Treat it as part of the same checklist as:

- Title under 70 chars.
- Body has a Summary, the change, and a Test plan.
- HEREDOC for the body to preserve formatting.
- (NEW) Verify each cross-referenced PR's current state.

## See also

- `docs/collaborative-loops.md` — autonomous variant ships the
  monitoring loop that surfaces fresh inbound mail; this rule covers
  the *outgoing* discipline.
- `docs/cross-city-mail-protocol.md` — payload-level contract for
  the mail this rule applies to.
- `feedback_pr_cross_reference_check.md` (mayor memory) — the
  same rule, kept in mayor memory so it's loaded into every mayor
  turn without needing to re-read this doc.
