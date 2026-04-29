# Known gc binary bugs

Catalog of bugs in the gc binary (homebrew gascity 1.0.0 as of 2026-04-29) that we work around per-host until they get a real fix in a future release. Each entry pairs a symptom + evidence + workaround you can apply yourself.

This file is the canonical reference. Each bug also has primary tracking beads (mg- prefix) and may have dgu- mirrors for local routing on yggdrasil.

## How bugs end up here

The gc binary embeds packs (formulas, orders, prompt templates, scripts) at compile time. There is no source-on-disk for those embedded resources — `strings $(which gc)` returns them. So no Class A or Class B fix can produce a long-lived patch; the templater rewrites pack files on every supervisor startup or heavy reconciler event.

That leaves three workaround shapes:

- **Class A** — host-local config fixes that don't touch packs (e.g., `~/.gc/supervisor-wrapper.sh` env, `city.toml` overrides where they actually work). Survive everything.
- **Class B** — post-template patchers that re-apply after the binary writes pack files. Shipped as `gc-fix-*` helpers, run automatically by `gc-fix-watch`. Survive in steady state; have to re-run after every binary re-template (which `gc-fix-watch` handles).
- **Class C** — no host-local fix possible. Bug requires a binary patch upstream. We document the symptom + workaround + tracker so anyone hitting it locally knows what they're seeing.

The bugs below are mostly Class C. Where a Class A or B workaround landed, the entry calls it out.

---

## Pool FQN mismatch on order dispatch

**Trackers**: `mg-ovjgn` (closed — workaround sufficient), cross-host evidence in coordination thread.

**Symptom**: order TOMLs ship `pool = "<role>"` (bare). Supervisor's dispatch query asks `bd ready --metadata-field gc.routed_to=<pack>.<role>` (FQN). Mismatch — query never matches, no session ever spawns. Affects every pack-imported pool agent (`dog`, `polecat`, `witness`, `refinery`).

**Evidence**: doctor reports `stale-routed-config: <bead> routes to missing config target "<role>"`. Confirmed on both midgard and yggdrasil.

**Why no Class A**: `[[orders.overrides]]` config TABLE accepts a `pool` field at validate-time but the dispatch path silently ignores it. Confirmed by side-by-side test on mg.

**Workaround (Class B)**: `gc-fix-alias-mismatch` rewrites bare `pool = "<role>"` → `pool = "gastown.<role>"` in TOMLs. Pattern B coverage added in PR #4. `gc-fix-watch` re-applies after every templater wipe. Audit script (`gc-audit-alias-mismatch`) flags pattern B findings since PR #7.

---

## orders.overrides `enabled = false` silently ignored

**Trackers**: `mg-9d610` (open).

**Symptom**: `[[orders.overrides]] name = "<order>" enabled = false` in `city.toml` is accepted by the config validator and shown in `gc config show`, but the order keeps firing every cooldown.

**Evidence**: midgard `city.toml` had `mol-dog-backup`, `mol-dog-phantom-db`, `mol-dog-jsonl` all overridden to `enabled = false`. All three kept firing per `events.jsonl` `order.fired` events. Same shape as the pool-override bug — the config table is accepted-but-ignored.

**Why no Class A**: validator accepts the field; emission path doesn't honor it.

**Operational impact**:
- For script-based orders (mol-dog-jsonl invokes a bash script): firing produces an order-tracking bead that auto-closes. No accumulation.
- For molecule-based orders (mol-dog-backup, mol-dog-phantom-db emit dog-formula molecules): orphan beads pile up. Manual cleanup until binary fix.

**Workaround (Class A)**: periodic `bd close` of orphan beads under disabled orders. Leak rate observed at midgard: ~0.07% (1 orphan per 1345 auto-closes in 24h) so not worth automating.

---

## dolt/orders/* dog orders permanently stuck after bd-error during dispatch

**Trackers**: `mg-pfh96` (primary), `dgu-pfh96` (mirror).

**Symptom**: the 3 dog orders living under `dolt/orders/*` (`mol-dog-doctor` 5m, `mol-dog-stale-db` 15m, `mol-dog-compactor` 24h) stop firing PERMANENTLY after the supervisor encounters a bd-list/bd-create error during dispatch. `mol-dog-jsonl` and `mol-dog-reaper` (under `maintenance/orders/`, different pack) keep firing through the same class of errors.

**Evidence**:
- yggdrasil: 172 mol-dog-doctor entries between 2026-04-27 14:55 and 18:08; only 2 successful `order.fired` ever. After a `bd list: exit status 1: [mysql] packets.go:58 unexpected EOF`, no further fires.
- midgard: 224 mol-dog-doctor entries; last activity 2026-04-28 with same error shape (Dolt circuit-breaker trip during connection-refused window).

**Differential**: `dolt/orders/*` and `maintenance/orders/*` use different code paths for tracking-bead reads. One handles transient bd errors gracefully; the other gets stuck in some cached failure state.

**Workaround**: `gc supervisor restart` unsticks the orders for ONE fire post-restart, then they stick again on next bd error. Verified test on yggdrasil 2026-04-29: timeline matches the prediction exactly. Full restart runbook + caveats lives at `docs/diagnostic-runbook.md` ("Supervisor restart — caveats and workaround"). Restart-as-workaround is awful but reliable.

**Why no Class A or B**: the stuck-state cache is internal to the gc binary. No config knob found that resets it.

---

## bd broad-listing queries hang past 120s on remote Dolt over Tailscale

**Trackers**: `mg-5n9s` (open).

**Symptom**: `bd` commands without an `--assignee` filter (`bd list` with type/status filters but no assignee, `bd ready` unassigned, `gc doctor`, `gc status`) timeout after 120s. Narrow queries (`bd list --assignee=X`, `bd show`, `bd update`, `gc mail inbox`, `gc rig list`) return promptly.

**Evidence**: confirmed on midgard cycle by gastown.deacon. `gc doctor` reports `beads-store: store ping failed: bd store ping: timed out after 120s` even though dolt-server check passes. Direct `dolt sql -q 'SELECT 1'` against the same host returns instantly.

**Why no Class A**: query planner inside the gc binary doesn't terminate against remote Dolt over Tailscale once the dataset crossed a recent growth threshold.

**Workaround (Class A, partial)**: disable `bd` auto-export in `.beads/config.yaml`:

```yaml
backup:
  enabled: false
export:
  auto: false
```

This eliminates the post-write JSONL export which is the noisiest broad-listing path. Doesn't fix the underlying broad-query wedge for legitimate listings.

**Related**: `mg-0efp` — refinery materialization stalls, same wedge pattern.

**Diagnostic recipe** for stuck `bd` PIDs (when supervisor wedges):

```bash
ps -A -o pid,etime,command | grep 'bin/bd '   # find bd PIDs with long etime
tail -50 ~/.gc/supervisor.log | grep -E 'timed out|circuit-breaker|mail/'
# kill the stuck PID, retry the original op
```

---

## gc dolt health probes localhost instead of configured remote Dolt server

**Trackers**: `mg-8yih` (open).

**Symptom**: `gc dolt health --json` returns `server.running=false`, `reachable=false`, `databases=[]` even when the configured remote Dolt server is reachable and direct SQL + bd commands work fine. Env vars set correctly: `GC_DOLT_HOST=mani-mac-mini.tail032ed9.ts.net`, `GC_DOLT_PORT=16022`.

**Evidence**: `bd list` against the same host returns instantly. `gc doctor`'s `dolt-server` check (separate code path) reports the remote correctly. Only `gc dolt health` is hard-coded to probe localhost.

**Risk**: deacon patrol formula treats `reachable=false` as CRITICAL escalation — without manual override it would page the mayor falsely.

**Workaround**: don't use `gc dolt health` for remote-Dolt verification. Use one of:
- `gc doctor` (dolt-server check is correct against remote)
- `bd stats` (returns zero work if dolt unreachable; succeeds if reachable)
- `dolt --no-tls --host <host> --port <port> sql -q 'SELECT 1'` (direct probe)

If you have a deacon health-scan formula referencing `gc dolt health`, swap it for `gc doctor --json | jq` or `bd stats`.

---

## gc supervisor stop ignores SIGTERM on long-running daemons

**Trackers**: surfaced during yggdrasil restart-test 2026-04-29 (PR #9). No primary bead yet.

**Symptom**: `gc supervisor stop` returns the OK message `Supervisor stopping...` but the daemon doesn't exit. Direct `kill <pid>` is also ignored. Observed on yg with a supervisor running 1d 19h with 944 min of accumulated CPU time.

**Workaround**: SIGKILL. The `docs/diagnostic-runbook.md` restart sequence builds it in:

```bash
gc supervisor stop
for i in 1 2 3 4 5; do
    sleep 3
    if ! kill -0 $SUPERVISOR_PID 2>/dev/null; then break; fi
done
if kill -0 $SUPERVISOR_PID 2>/dev/null; then
    kill -9 $SUPERVISOR_PID
fi
```

**Why no Class A**: signal handling is in the gc binary. No config knob.

---

## launchd drift after a failed gc supervisor stop

**Trackers**: surfaced during yggdrasil restart-test 2026-04-29 (PR #9). No primary bead yet.

**Symptom**: after a `gc supervisor stop` that didn't actually stop the daemon (see SIGTERM-ignore bug above), launchd's view of the supervisor service drifts to "registered but not running" with PID `-`. The next bootstrap attempt then tries to start a second supervisor that can't bind port 8372 because the orphan is still holding it.

**Workaround**: re-bootstrap the LaunchAgent after killing the orphan:

```bash
launchctl bootout gui/$(id -u)/com.gascity.supervisor 2>/dev/null
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.gascity.supervisor.plist
```

Full sequence in `docs/diagnostic-runbook.md` — "Safe restart sequence".

**Why no Class A**: launchd integration is in the gc binary. No config knob.

---

## gc runtime request-restart panics with select-no-cases deadlock

**Trackers**: `mg-fl2u8` (open).

**Symptom**: `gc runtime request-restart` (called by deacon and other agents to signal a clean restart) panics with Go runtime deadlock detection instead of blocking until the controller kills the session.

```
fatal error: all goroutines are asleep - deadlock!
goroutine 1 [select (no cases)]:
main.doRuntimeRequestRestart cmd_runtime_drain.go:462 +0x158
```

**Why this happens**: the implementation uses a `select{}` with no cases, which Go's runtime detects as definite deadlock at goroutine 1. Should be a blocking channel or signal-bound context instead.

**Workaround**: none. The metadata side-effect (`GC_RESTART_REQUESTED`) may or may not be set before the panic; agents calling this should NOT depend on the contract. Reconcile via the controller's metadata watcher instead.

---

## jsonl-export.sh column rename type → issue_type

**Trackers**: `mg-yras` (closed — workaround applied).

**Symptom**: `mol-dog-jsonl` order produces 0 records on every fire. The embedded `jsonl-export.sh` references column `type` but the issues table uses `issue_type`.

**Evidence**: `strings $(which gc) | grep 'type NOT IN'` returns the buggy line.

**Workaround (Class A)**: set `GC_JSONL_SCRUB=false` in `~/.gc/supervisor-wrapper.sh` before exec'ing the supervisor. With `SCRUB=false`, the script skips the broken `WHERE` clause entirely and exports all rows. Acceptable when the archive remote is a local bare git repo (no public exposure).

**Why no Class B**: the script is binary-templated under `<city>/.gc/system/packs/maintenance/assets/scripts/jsonl-export.sh`. A `gc-fix-jsonl-export-column` helper would have to re-apply on every templater wipe. The Class A env-var workaround is sufficient.

---

## gcx mail reply hangs on stuck supervisor connection pool

**Trackers**: `mg-492d` (closed — fixed).

**Symptom**: `gcx mail reply <wisp-id>` produces zero stdout/stderr for >30s. Supervisor's mail GET endpoint itself responds in 20ms via direct curl — the wedge is in gcx's HTTP client.

**Root cause**: gcx's `urllib.request.urlopen(req)` was called WITHOUT a timeout argument, defaulting to `socket.getdefaulttimeout() = None = block forever`.

**Fix landed**: pass `timeout=30` to `urlopen()`. URLError/TimeoutError exit code 2. Lives in dv-gascity-utils gcx (line 126). Mirror the patch into your local `<city>/.gc/system/packs/gascity-comms/assets/scripts/gcx` if your copy predates it. **gcx is NOT binary-embedded**, so the in-place patch persists.

---

## Pack-template wipe on supervisor startup / heavy reconcile

**Trackers**: discussed across `mg-d80k3`, `mg-ovjgn`, `mg-pfh96` threads. No primary bead — it's the underlying mechanism that creates Class B's reason-for-existing.

**Symptom**: every supervisor startup and several heavy reconciler events re-render embedded pack contents to disk under `<city>/.gc/system/packs/`, wiping any in-place patches.

**Evidence**: `<pack>/*.toml` files have mtimes that jump uniformly across many files at the same instant; permissions reset to `0644` (your `gc-fix-*` patches typically write `0600`).

**Workaround**: `gc-fix-watch` (this repo, PR #5 + PR #8 v2). Polls each town's pack tree every 30s, debounces 2s on detected change, invokes every `gc-fix-*` helper symlinked into `~/.gc/bin/` that hasn't already been re-applied (helpers are idempotent via marker checks).

See `docs/pack-template-resilience.md` for the full design + install instructions.

---

## How to add a new entry

1. Reproduce on at least one host. Capture exact error strings + binary version.
2. File a tracking bead in your local store: `bd create --title="[gc binary bug] <symptom>" --type=bug`.
3. If the bug is cross-host, mirror to dgu via direct SQL (see mg-pfh96 → dgu-pfh96 example) or ask the dgu owner to mirror.
4. Add a section to this file with: trackers, symptom, evidence, workaround (or "none — Class C").
5. Cross-reference from the bead's metadata: `bd update <id> --set-metadata docs_url=<this-file>`.
