# Refinery latency tuning

> Standalone note on bounding refinery find-work latency. Companion to `docs/lessons-learned.md` § C (alias canonicalization) and `docs/refinery-materialization.md` (on-demand spawn root cause). Tracking bead: `dgu-arvqg`.

## Symptom

After alias canonicalization (`gc-fix-refinery-routing`) was applied and the on-demand refinery slot started waking correctly, a second-order latency surfaced: once the refinery was awake and idle, freshly-pushed polecat branches sat unconsumed for up to ~5 minutes before the refinery picked them up. The mayor flagged this twice in cadence checks before the work was filed.

## Diagnosis

The refinery's find-work loop in `mol-refinery-patrol.toml` blocks on a typed event watch:

```bash
SEQ=$(gc events --seq)
gc events --watch --type=bead.updated --after=$SEQ --timeout {{event_timeout}}s
```

`event_timeout` defaults to `30`. The formula's prose instructs the agent: *"On timeout: re-check anyway, then wait again with doubled timeout (cap 300s)."* So during quiet stretches the watch grows by powers of two (30s → 60s → 120s → 240s → 300s) and pins at 300s thereafter. A polecat done-sequence that lands during the 300s window can sit ~5 min before the watch returns and the refinery re-scans for assigned work.

Empirical confirmation (refinery `yg-0fier`, dv-gascity-utils, 2026-04-28): session peek shows the watch at 30s and 60s timeouts in succession, demonstrating the doubling. `gc events` over the last hour shows ~300+ `bead.updated` events flowing freely (mostly `actor=human` and `actor=cache-reconcile`), so the event stream itself is healthy — the latency is purely in the agent's wait posture, not in event delivery.

The four candidate root causes considered:

1. **Watch filter too narrow.** Ruled out — `--type=bead.updated` matches the events polecats fire (`gc bd update --status=open --assignee=...`). Live event stream confirms.
2. **`--after=$SEQ` cursor not advancing.** Ruled out — the live refinery session captures fresh `$SEQ` each iteration; cursor advances correctly.
3. **Polecats not firing the right event type.** Ruled out — every `gc bd update` fires `bead.updated`.
4. **Doubling-backoff overshoots.** **This is the cause.** The 300s cap is too high for an interactive merge queue.

## Fix (B.4 — defense in depth)

Two complementary patches, applied together via `gc-tune-refinery-loop` (in `packs/gascity-comms/assets/scripts/`):

### 1. Cap the doubling at 60s

`packs/gastown/formulas/mol-refinery-patrol.toml` — replace `cap 300s` with `cap 60s`. Worst-case polecat-to-refinery latency is now bounded at one minute regardless of how long the refinery has been idle. The trade-off is more frequent (cheap) re-subscriptions during multi-hour quiet periods, which is acceptable.

### 2. Polecat-side wake nudge

`packs/gastown/formulas/mol-polecat-work.toml`, `packs/gastown/agents/polecat/prompt.template.md`, `packs/gastown/template-fragments/approval-fallacy.template.md` — add a non-blocking `gc session nudge` to the polecat done-sequence after the refinery reassignment:

```bash
gc session nudge "$GC_RIG/gastown.refinery" "new work: <work-bead>" 2>/dev/null || true
```

This sends a text input to the running refinery session. It does **not** interrupt an in-progress `gc events --watch` (the runtime queues the input until the watch returns), but it ensures the refinery sees a clear "work is here" signal as soon as it next prompts. Failure is ignored — the bead's `assignee` + `gc.routed_to` still drives the reconciler's on-demand spawn path, so this is purely additive.

The nudge is symmetric with the existing mail-nudge architecture and serves as documentation of intent: polecats actively hand off rather than relying on event diffusion.

## Why not B.1 alone, or B.3?

- **B.1 (nudge only)** doesn't bound the worst case: `gc session nudge` does not break a blocked subprocess watch. If the refinery is mid-`--watch --timeout 300s`, the nudge waits for that watch to return regardless. Latency is still up to 300s.
- **B.3 (broaden the watch filter)** would help if events were being missed, but they aren't. Broadening adds noise without changing the doubling problem.
- **B.2 (cap only)** is the load-bearing fix; B.1 is the redundancy. B.4 is the right shape.

## Verification recipe

End-to-end measurement requires a live refinery and at least one tracked work bead. Recommended synthetic test:

```bash
# Pre-conditions: refinery awake and idle; no other queue contention.
# 1. Sling a tiny doc-only bead routed to the rig's polecat pool:
gc sling --type=task --priority=3 \
  --title="latency-test: refinery wake timing" \
  --description="Append a no-op bullet to docs/refinery-latency-tuning.md."

# 2. Note the timestamp the polecat closes with `gc runtime drain-ack`.
# 3. Note the timestamp the refinery's wisp moves to `merge-push` step.
# 4. Difference is end-to-end latency.
```

Target: <60s in a steady-state-quiet case (no other queue contention), down from up to 300s pre-fix.

> Live numbers from a real synthetic sling will be added here once a test cycle has been run against a patched town. The cap-at-60s ceiling is the design contract.

## Out of scope

- **Cold-start refinery latency.** When the refinery slot is `reserved-unmaterialized (on_demand)`, the reconciler still has its own tick cadence before it spawns the session. That's a separate concern (tracked separately).
- **Cross-rig refinery coordination.** This fix is per-rig.
- **Replacing the watch with SSE subscription.** Overkill for a tuning fix; revisit if the cap-60s approach proves insufficient.

## Applying the fix

```bash
~/.gc/bin/gc-tune-refinery-loop                  # scan ~/* and patch every gastown pack
~/.gc/bin/gc-tune-refinery-loop --dry-run        # preview without writing
~/.gc/bin/gc-tune-refinery-loop ~/yggdrasil      # explicit root
```

Idempotent — re-runs report `already fixed`. Composes cleanly with `gc-fix-refinery-routing` (alias canonicalization) and `gc-fix-merge-strategy` (PR-protected branch detection); apply order does not matter.
