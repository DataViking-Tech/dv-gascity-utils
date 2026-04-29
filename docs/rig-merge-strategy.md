# Rig merge strategy

How a polecat decides whether the refinery should land its branch via direct
merge or via a pull request, and how to override that decision per rig, per
bead, or per host.

## Why this exists

Polecats hand work beads to the refinery without setting
`metadata.merge_strategy`, which the refinery defaults to `direct`. Direct
merge calls `git push origin <target>`, which is rejected by GitHub branch
protection (error GH013) on rigs whose default branch is protected — the
mayor then has to open a PR by hand.

The fix shipped here makes the polecat's submit-and-exit step **auto-detect
branch protection** at submit time and set `metadata.merge_strategy=mr` when
the target is protected. The refinery already supports `mr` and publishes a
PR via `gh pr create` instead of attempting a direct merge.

Tracking bead: `dgu-26ptn`. Symptoms it eliminates: GH013 on `tc-*` and
`tr-*` polecat work, manual mayor PR creation for every protected-rig polecat.

## Resolution order

The polecat resolves merge strategy at submit time in this order — the first
rule that produces a value wins:

1. **`metadata.merge_strategy` already set on the work bead.**
   This catches `gc sling --merge mr` and `gc convoy create --merge mr`
   (when the convoy propagates merge metadata to children). Anything the
   caller explicitly asked for is honored without further detection.
2. **Per-rig override file `<rig-root>/.gc-merge-strategy`.**
   A single line containing `mr` or `direct`. Lives in the rig repo so it
   travels with the source. Use this when auto-detect can't see protection
   (private repos with non-admin tokens are fine in step 3, but local-only
   repos with no GitHub remote land here) or when you want explicit
   intent in the repo history.
3. **Auto-detect via the GitHub branches API.**
   ```
   gh api repos/<owner>/<repo>/branches/<target> --jq '.protected'
   ```
   The plain `/branches/<name>` endpoint exposes the `protected` boolean
   to any token that can read the branch. The admin-only
   `/branches/<name>/protection` sub-endpoint returns 404 to non-admin
   tokens and **must not be used** for this check.
4. **Fallback `direct`.**
   No remote, no override, no protection signal — keep the previous
   default. Direct merge will simply fail loudly on protected branches,
   which surfaces the misconfiguration without silently doing the wrong
   thing.

## Installing the patch

The polecat done-sequence lives in the gastown system pack. That pack is
materialized per-host into `<town>/.gc/system/packs/gastown/` and is **not**
in any git repo, so the only way to apply the resolution-order logic to a
running city is to patch the per-host runtime files in place.

The helper script handles this:

```bash
~/dv-gascity-utils/packs/gascity-comms/assets/scripts/gc-fix-merge-strategy
```

Defaults to scanning every `~/<town>/.gc/system/packs/gastown` it finds and
patching:

- `formulas/mol-polecat-work.toml` (the actual logic, in step
  `submit-and-exit`)
- `agents/polecat/prompt.template.md` (one-line note in the FINAL REMINDER
  section)
- `template-fragments/approval-fallacy.template.md` (matching note in the
  fragment included by the polecat prompt)

The script is idempotent — a marker check on each file makes re-runs safe.
Use `--dry-run` to preview, or pass explicit roots like
`gc-fix-merge-strategy ~/yggdrasil ~/asgard` to limit scope.

The standard per-host installation links the helper into `~/.gc/bin`:

```bash
ln -sf ~/dv-gascity-utils/packs/gascity-comms/assets/scripts/gc-fix-merge-strategy ~/.gc/bin/gc-fix-merge-strategy
```

After patching, no `gc reload` is required — the rig's `.beads/formulas/*`
are symlinks into the system pack, so changes to the source TOML are
visible immediately. New wisps materialize step descriptions from the
patched template and existing in-flight wisps keep their already-cooked
descriptions (re-pour or wait for the next sling to pick up the change).

## Per-bead override

The CLI flag is the established mechanism:

```bash
gc sling <rig>/polecat <bead-or-text> --merge mr
```

Sling stamps `metadata.merge_strategy=mr` on the routed bead, which the
polecat sees in step 1 of the resolution order and skips the auto-detect.

Useful when:

- The rig is normally `direct` but a specific change wants PR review.
- The auto-detect would pick the wrong answer for a one-off case (rare).
- You're testing the `mr` path on a normally-unprotected rig.

## Per-rig override

Drop a single-line file at the rig's repo root:

```bash
echo mr > /Users/mani/traitprint/.gc-merge-strategy
```

Acceptable values: `mr`, `direct`. Whitespace is trimmed.

Commit the file so the override travels with the rig. Don't add it for rigs
whose protection is already correctly auto-detected — it's just one more
piece of state to maintain. Reach for it when:

- The rig has no GitHub remote (auto-detect will return empty).
- You want the merge strategy pinned in source history rather than
  inferred from a live API call.
- The token used by the polecat doesn't have read access to the branch
  metadata (rare; typically only happens with severely scoped tokens).

## What about a `gc rig add --merge mr` field?

There isn't one today. The `[[rigs]]` blocks in `site.toml` carry only
`name`, `path`, and `imports`; the `[[agent]]` blocks (including the
polecat) have no `merge_strategy` field; and the auto-convoy created by
`gc sling` does not currently propagate `--merge` to its children.

If we want `merge_strategy` to be a first-class rig setting, that's a
gc-side change (binary + config schema). Filed as out-of-scope for the
fix shipped here — the per-host patch + per-rig override file gets us
working PR-protected polecat work without waiting on a binary change.

## Rigs covered today (yg side)

- `dv-gascity-utils` → unprotected → auto-detect resolves to `direct`.
- `traitprint-cloud` → protected → auto-detect resolves to `mr`.
- `traitprint` → protected → auto-detect resolves to `mr`.
- `synth-panel` → check at submit time; auto-detect handles either way.

Mirror to mg side: run `gc-fix-merge-strategy` on the mg host once the
helper script is symlinked into `~/.gc/bin/` there.

## Verifying the patch

After running the helper, the patched formula step contains a `MERGE_STRATEGY=`
shell variable in the submit-and-exit step. Quick check:

```bash
grep -c MERGE_STRATEGY= ~/<town>/.gc/system/packs/gastown/formulas/mol-polecat-work.toml
# expect: 4 or more  (the variable appears in the resolution flow)
```

Live check from a polecat worktree on a protected rig:

```bash
TARGET=main
ORIGIN_REPO=$(gh repo view --json nameWithOwner -q '.nameWithOwner')
gh api "repos/$ORIGIN_REPO/branches/$TARGET" --jq '.protected'
# expect: true   (auto-detect would resolve to mr)
```

If the live check returns nothing or `false` on a rig you know is
protected, the token used by `gh` may lack read access — fall back to a
per-rig override file.
