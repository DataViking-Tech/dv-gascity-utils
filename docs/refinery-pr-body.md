# Refinery PR body (and back-link to the GitHub issue)

The refinery's `mr` strategy publishes a pull request via `gh pr create`.
Out of the box, the formula's `PR_BODY` is a 3-line stub:

```
## Summary
Automated pull request published by Gastown Refinery.
- Issue: $WORK
- Branch: $BRANCH
- Target: $TARGET
```

This is fine for a human who already knows the bead, but it doesn't link
back to the GitHub issue the bead was created from, and it gives no
context on what the PR contains. Reviewers have to dig.

## What this adjustment does

The patched `PR_BODY` builds:

- **`Closes #N`** when the bead's `external_ref` matches `gh-N`. GitHub's
  closing-keyword auto-link kicks in, so merging the PR also closes the
  source issue.
- **GitHub issue URL** rendered as a clickable link, derived from the rig
  origin (`gh repo view --json nameWithOwner`).
- **External ref** (e.g. `gh-343`) and **work bead ID** (`sp-698yla`) for
  cross-system traceability.
- **Commit log** (`git log --oneline origin/<target>..<branch>`, capped at
  15 commits) so reviewers see the change at a glance without expanding
  the diff.
- **Issue context** — the bead description blockquoted (capped at 60
  lines) so reviewers don't have to switch tabs to read the original
  ask.
- **Test plan checklist** so PR templates aren't completely empty —
  reviewers tick CI / acceptance / regression boxes.

## Why this exists

Earlier mayors observed:

1. Polecats were submitting work via `mr` strategy with stub PR bodies,
   and reviewers had to leave the PR to find the original issue. Net
   result: review latency.
2. The bead's `external_ref` (set when the mayor creates a bead from a
   GitHub issue, e.g. `gc bd create ... --external-ref gh-343`) was
   already capturing the link — the refinery just wasn't using it.
3. `Closes #N` is the canonical way to tie a PR back to a GitHub issue
   so the issue auto-closes on merge. Adding it costs nothing and saves
   a manual close step every time.

This adjustment makes the refinery do what a careful human would do
when opening the PR by hand.

## Where the change lives

The PR-body block is in the `merge-push` step of the refinery formula:

```
~/<town>/.gc/system/packs/gastown/formulas/mol-refinery-patrol.toml
```

Look for the section beginning `**If MERGE_STRATEGY = "mr":**` and the
`PR_BODY=$(cat <<EOF` heredoc within it.

The dv-gascity-utils mirror at
`.beads/formulas/mol-refinery-patrol.toml` is a **symlink** to that
system-pack file (verify with `ls -la`), so a single edit propagates
to both views. No `gc reload` needed; the rig's `.beads/formulas/*`
are also symlinks into the system pack, so the refinery picks up the
new heredoc on its next wisp.

## Variables added before the heredoc

```bash
EXTERNAL_REF=$(gc bd show $WORK --json | jq -r '.[0].external_ref // empty')
BEAD_DESC=$(gc bd show $WORK --json | jq -r '.[0].description // ""' | sed 's/^/> /' | head -60)
COMMIT_LOG=$(git log --oneline "origin/$TARGET..$BRANCH" 2>/dev/null | head -15)
GH_ISSUE_LINK=""
GH_ISSUE_REF=""
if echo "$EXTERNAL_REF" | grep -qE '^gh-[0-9]+$'; then
  GH_ISSUE_NUM="${EXTERNAL_REF#gh-}"
  GH_ISSUE_LINK="https://github.com/$ORIGIN_REPO/issues/$GH_ISSUE_NUM"
  GH_ISSUE_REF="Closes #$GH_ISSUE_NUM"
fi
```

`$ORIGIN_REPO` is already set earlier in the same step (line ~278 in
the canonical formula), and `$WORK` / `$BRANCH` / `$TARGET` are set in
step 2. No new bead-metadata contract is required — `external_ref` is
the standard field the mayor already populates.

## Bash conditional expansion

The heredoc uses `${VAR:+...}` to conditionally render rows when the
variable is non-empty:

```bash
${GH_ISSUE_REF:+$GH_ISSUE_REF}
${GH_ISSUE_LINK:+- **GitHub issue:** $GH_ISSUE_LINK}
${EXTERNAL_REF:+- **External ref:** \`$EXTERNAL_REF\`}
```

A bead with no `external_ref` (e.g. an internal bead never created from
a GitHub issue) drops the issue lines cleanly — no `Closes #` line, no
broken-link row, no empty bullet. The PR still gets the work-bead ID,
branch, target, commit log, and bead description.

## Per-city / per-host application

Today this is a single in-place edit on the host that runs the
refinery. To roll out across multiple hosts (yg, mg, asgard) without
copy-pasting, follow the pattern of `gc-fix-merge-strategy` and
`gc-fix-refinery-routing`:

1. Write a `gc-fix-refinery-pr-body` script in
   `packs/gascity-comms/assets/scripts/` that scans every
   `~/<town>/.gc/system/packs/gastown/formulas/mol-refinery-patrol.toml`
   and applies the substitution under a marker check.
2. Symlink it into `~/.gc/bin/gc-fix-refinery-pr-body` per the
   established pattern.
3. Wire it into `gc-fix-watch` so it runs on every helper cycle and
   re-patches if a fresh `gc pack import` overwrites the formula.

Until that helper is shipped, the change persists only as long as the
system pack isn't re-imported. Re-imports will revert the formula to
the upstream stub; re-applying is a 12-line manual edit (the heredoc
plus the variable extraction above).

## Verifying the patch

After editing, the next refinery cycle on a `mr`-strategy bead opens a
PR with the new body. Quick check on a freshly opened PR:

```bash
gh pr view <PR-number> --repo <owner>/<repo> --json body --jq '.body' | head -30
```

Expect to see `Closes #N`, the `GitHub issue:` row, the work bead ID,
the commit log block, and the blockquoted issue context. If the
`Closes #N` line is missing on a bead you know was created from a
GitHub issue, double-check the bead's `external_ref`:

```bash
gc bd show <bead> --json | jq -r '.[0].external_ref'
# expect: gh-<number>
```

A bead created with `gc bd create ... --external-ref gh-NNN` will have
the field; a bead created without that flag will skip the issue-link
rows (and that's the documented behavior, not a bug).

## What to do if the upstream stub returns

If you spot a refinery PR with the bare 3-line body, the formula was
re-imported from upstream and lost the patch. Two options:

1. **Re-apply manually.** Edit
   `~/<town>/.gc/system/packs/gastown/formulas/mol-refinery-patrol.toml`,
   find `**If MERGE_STRATEGY = "mr":**`, and replace the
   `EXISTING_PR=...` / `ISSUE_TITLE=...` / `PR_BODY=...` block with the
   variables-and-heredoc version above. No reload needed.
2. **Ship the helper script.** If this happens regularly enough to
   notice, that's the signal to land `gc-fix-refinery-pr-body` and let
   `gc-fix-watch` keep the patch alive across re-imports — same shape
   as `gc-fix-merge-strategy`.

## Related docs

- [`rig-merge-strategy.md`](./rig-merge-strategy.md) — how the polecat
  decides whether to use `mr` or `direct` in the first place. If the
  polecat picks `direct`, the refinery never reaches the `PR_BODY`
  block and this adjustment is irrelevant.
- [`refinery-latency-tuning.md`](./refinery-latency-tuning.md) — other
  refinery-side knobs.
- [`refinery-materialization.md`](./refinery-materialization.md) —
  how refinery wisps are materialized from formulas.
