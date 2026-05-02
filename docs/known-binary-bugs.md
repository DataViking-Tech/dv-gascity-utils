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

**Note**: a full supervisor restart DOES make the override take effect (the dispatch table is rebound at startup). See "supervisor reload doesn't refresh order dispatch tables" below — `gc-reload-orders` is the helper for the restart path.

---

## supervisor reload doesn't refresh order dispatch tables

**Trackers**: GitHub `DataViking-Tech/dv-gascity-utils#31`, bead `dgu-503ip`.

**Symptom**: `gc supervisor reload` (and `gc reload`) refresh the resolved-config view — `gc config show` and `gc order list` reflect the change immediately — but the controller's auto-dispatch loop keeps using the pre-reload active-orders set. New orders dropped under `<pack>/orders/*.toml` don't tick on schedule, and `[[orders.overrides]] enabled = false` flips don't stop the affected order from firing, until the supervisor process is fully restarted. `gc order run <name>` works manually because that path resolves from the live config; only the auto-dispatch tick is bound to the stale set.

Same shape as `mg-9d610` (overrides ignored) but distinguishable: that bug applies even after a restart, this one is healed by a restart.

**Repro** (yggdrasil, 2026-05-02):

1. Drop `mail-nudge.toml` in `maintenance/orders/`.
2. `gc supervisor reload` → "Reconciliation triggered."
3. `gc order list` shows `mail-nudge` in 3 scopes.
4. `gc order check` shows `mail-nudge` "due (elapsed 102h)" but not firing.
5. `gc order run mail-nudge` works manually; state file updates.
6. `gc supervisor stop && start` → `mail-nudge` auto-fires within ~20s.

The same pattern reproduces for `[[orders.overrides]] enabled = false`: the override is shown by `gc config show` but the order keeps firing every cooldown until the supervisor restarts.

**Why no Class A**: the dispatch-table state lives inside supervisor process memory, bound from resolved config at startup. The reload accept-path updates the snapshot the API exposes but doesn't recompute the active-orders set or swap it into the dispatch loop. No host-side config knob exists to force the rebind without a process exit.

**Why no Class B**: this isn't a pack-template surface; it's runtime state in the supervisor binary's memory. Pack-watch wouldn't trigger on the right surface.

**Workaround (Class A operational)**: `gc-reload-orders` performs the proven safe-restart cycle (graceful stop with SIGKILL fallback, launchd/systemd verify, re-bootstrap if drifted, status confirm). It packages the recipe from `docs/diagnostic-runbook.md` "Safe restart sequence" so the operator doesn't have to assemble it by hand.

```bash
ln -sf ~/dv-gascity-utils/packs/gascity-comms/assets/scripts/gc-reload-orders \
    ~/.gc/bin/gc-reload-orders

# Apply pending order/override changes
gc-reload-orders               # full cycle on the local supervisor
gc-reload-orders --dry-run     # preview the cycle without restarting
gc-reload-orders --skip-reload # skip the pre-cycle `gc supervisor reload`
```

The cycle's blast radius is the entire supervisor (every agent across every rig and city). Treat as a maintenance-window action — not a routine fix. Active polecat worktrees + bead state survive across the cycle; in-flight tmux sessions are torn down.

`gc-city-bootstrap` symlinks `gc-reload-orders` automatically — fresh hosts get it without extra setup.

**Test plan** (after the binary is fixed upstream): add a new order, run `gc supervisor reload`, then verify auto-dispatch ticks on schedule WITHOUT a supervisor restart. Until that fix, validation runs through `gc-reload-orders`.

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

**Trackers**: `mg-fl2u8` (closed per 2026-04-30 directive — no binary modifications planned), `dgu-fl2u8` (closed mirror), `yg-ueadi` (closed dup filed by synth-panel/gastown.witness 2026-04-30 hitting it during patrol).

**Symptom**: `gc runtime request-restart` (called by deacon and other agents to signal a clean restart) panics with Go runtime deadlock detection instead of blocking until the controller kills the session.

```
fatal error: all goroutines are asleep - deadlock!
goroutine 1 [select (no cases)]:
main.doRuntimeRequestRestart cmd_runtime_drain.go:462 +0x158
```

**Why this happens**: the implementation uses a `select{}` with no cases, which Go's runtime detects as definite deadlock at goroutine 1. Should be a blocking channel or signal-bound context instead.

**Workaround (Class B)**: replace `gc runtime request-restart` with `gc runtime drain-ack && exit` in agent formulas. drain-ack signals the controller to stop the session (the polecat done-and-exit pattern); controller respawns from the agent template (driven by `min_active_sessions` or queued work), and the new session picks up the next wisp from its hook.

`gc-fix-runtime-restart` patches the 4 affected formulas (mol-witness-patrol, mol-deacon-patrol, mol-refinery-patrol, mol-polecat-work) in the gastown pack. `gc-fix-watch` re-applies after every templater wipe — same pattern as `gc-fix-merge-strategy` and `gc-fix-alias-mismatch`.

```bash
ln -sf ~/dv-gascity-utils/packs/gascity-comms/assets/scripts/gc-fix-runtime-restart \
    ~/.gc/bin/gc-fix-runtime-restart
gc-fix-runtime-restart                       # patch every host town
gc-fix-runtime-restart --dry-run ~/yggdrasil # preview one town
```

The metadata side-effect (`GC_RESTART_REQUESTED`) is no longer the contract anyone depends on after this fix.

---

## events.jsonl endpoint hangs when log grows past ~400 MB

**Trackers**: `yg-wisp-djc` (DOCTOR finding 2026-04-28 flagged size at 100 MB), `yg-wisp-dv4` (ESCALATION 2026-04-30 confirmed actual service hang at 426 MB).

**Symptom**: `GET /v0/city/<name>/events` (and `?limit=1` variants) hangs indefinitely once `events.jsonl` grows past roughly 400 MB. Other endpoints (e.g. `/v0/health`) respond instantly. `gc events --watch` and `gc events --seq` fail with `context deadline exceeded`. Witnesses, refineries, and deacons that gate cycles on event-watch fall back to spin-cycles or self-restart loops.

**Evidence (yg, 2026-04-30)**:
- `events.jsonl` at 426 MB → 5+ second hangs on `/events?limit=1`
- After `mv events.jsonl events.jsonl.archive.<ts> && touch events.jsonl`: same endpoint returns 200 in 0.86ms
- No supervisor restart required — supervisor's writer continues appending to the new empty file transparently

**Why this happens**: the endpoint appears to read the full file on each request. No streaming, no pagination short-circuit. Doubled from 100 MB → 426 MB in 36h on yg without rotation, suggesting no built-in retention policy.

**Workaround (Class A — operational)**: archive + truncate when the file grows past a threshold. Verified safe on a live yg supervisor:

```bash
mv ~/<town>/.gc/events.jsonl ~/<town>/.gc/events.jsonl.archive.$(date -u +%Y-%m-%dT%H-%MZ)
touch ~/<town>/.gc/events.jsonl
chmod 644 ~/<town>/.gc/events.jsonl
```

**Workaround (Class A automated)**: `gc-events-rotate` helper. Hourly LaunchAgent (`com.dv-gascity.events-rotate`) checks every town's `events.jsonl`, rotates when over `--threshold-mb` (default 256), and prunes archives older than `--retain-days` (default 30).

```bash
ln -sf ~/dv-gascity-utils/packs/gascity-comms/assets/scripts/gc-events-rotate \
    ~/.gc/bin/gc-events-rotate

# One-shot
gc-events-rotate --dry-run            # preview
gc-events-rotate                      # apply
gc-events-rotate --threshold-mb 512   # custom threshold

# Install as hourly LaunchAgent (macOS):
sed "s|{{HOME}}|$HOME|g" \
    ~/dv-gascity-utils/packs/gascity-comms/assets/launchd/com.dv-gascity.events-rotate.plist.template \
    > ~/Library/LaunchAgents/com.dv-gascity.events-rotate.plist
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.dv-gascity.events-rotate.plist
tail -f ~/Library/Logs/gc-events-rotate.log
```

The archive files are preserved as historical record; prune by adjusting `--retain-days` or deleting manually. Re-installing on hosts after `gc-city-bootstrap` doesn't auto-install the events-rotate LaunchAgent — one more manual step in the bootstrap doc until decided otherwise.

**Why no Class B**: this isn't a pack-template surface; it's runtime state in `<town>/.gc/`. Pack-watch wouldn't fire on events.jsonl growth. The hourly Periodic LaunchAgent is the right shape.

---

## gc rig add: broken includes shape + incomplete bd init

**Trackers**: `dgu-ogey6` (open).

**Symptom**: two distinct breakages encountered when adding a rig with `gc rig add`:

1. **Includes block doesn't expand.** `gc rig add /path --include packs/gastown` writes:
   ```toml
   [[rigs]]
   name = "<rig>"
   includes = ["packs/gastown"]
   ```
   This shape is rejected at config load with `expanding packs: rig "<rig>" pack "packs/gastown": loading pack.toml: open <city>/packs/gastown/pack.toml: no such file or directory`. The bare relative path resolves against the city root, not `.gc/system/packs/`. Working form (used by every other rig in city.toml):
   ```toml
   [[rigs]]
   name = "<rig>"
   [rigs.imports]
   [rigs.imports.gastown]
   source = ".gc/system/packs/gastown"
   ```

2. **Schema bootstrap is incomplete.** After `gc rig add` reports `Initialized beads database` and writes the .beads/ files, `bd list` works (returns empty) but `bd create` fails with `database not initialized: issue_prefix config is missing` — even though `config.yaml` clearly contains `issue_prefix: <p>`. Re-running `bd init --force --prefix <p>` in the rig dir completes the missing schema half.

**Evidence**: yg, 2026-04-30, while adding `dataviking-site` rig.

**Why no Class B**: pack-template-resilience (gc-fix-watch) operates on the gastown pack tree; this is a config + dolt-table state issue specific to per-rig setup. Different surface.

**Workaround (Class A)**: `gc-rig-init` wrapper helper handles both bugs in one command, plus auto-applies the standard polecat (min_active=0) + refinery (min_active=1) scaling overrides. Idempotent.

```bash
ln -sf ~/dv-gascity-utils/packs/gascity-comms/assets/scripts/gc-rig-init \
    ~/.gc/bin/gc-rig-init

# Add a new rig (one command, no manual fixups)
gc-rig-init /path/to/myproject

# Custom prefix or no pack import
gc-rig-init /path/to/myproject --prefix mp --no-include

# Preview without changes
gc-rig-init --dry-run /path/to/myproject
```

The wrapper:
1. Calls `gc rig add` (skipped if rig already in city.toml).
2. Detects + rewrites the broken `includes = [...]` block to the expanding `[rigs.imports.<pack>] source = ...` form.
3. Adds `[[rigs.overrides]]` blocks for polecat (min_active=0) and refinery (min_active=1) if not already present.
4. Probes `bd create`. If it succeeds, init is healthy. If it returns the schema error, runs `bd init --force --prefix <p>`. If the rig has existing beads, skips init (the binary safety check would refuse anyway).

`gc-city-bootstrap` symlinks `gc-rig-init` automatically — fresh hosts get it without extra setup.

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

## controller's per-rig `bd init` step doesn't honor secrets.env

**Trackers**: `dgu-emwy6` (open). Upstream: [DataViking-Tech/dv-gascity-utils#29](https://github.com/DataViking-Tech/dv-gascity-utils/issues/29). Same root-cause family as #26 (`gc-rig-join` preflight) and the `DOLT_CLI_PASSWORD=""` pattern in `gc-rig-init` — three surfaces, one bug.

**Symptom**: supervisor's per-rig `init rig <name> beads: exec beads init` step defaults to `dolt --user root --password ""` against the configured shared dolt. On hosts whose shared dolt requires auth (mg's `GC_DOLT_USER=beads` + `GC_DOLT_PASSWORD=…` in `~/.gc/secrets.env`), the bd init call hangs and gets SIGKILL'd by the supervisor's init timeout. The per-rig init then falls into a backoff retry loop and the entire city stays stuck never coming up. Cascades: subsequent reload requests get rejected ("keeping old config"), so any city.toml edits made after init failure are silently dropped.

**Evidence**: mg, 2026-05-02:
```
gc supervisor: city 'midgard': init: beads lifecycle: init rig "dv-gascity-utils" beads:
  exec beads init: signal: killed (skipping)
gc supervisor: city 'midgard': init failure #3, next retry in 40s
```

**Root cause**: `gc-beads-bd.sh` (the bd-pack wrapper the supervisor execs) reads `${GC_DOLT_PASSWORD:-}` from its own environment. The supervisor doesn't pre-source `~/.gc/secrets.env`, so the var is unset. The wrapper's `bd init` invocation also doesn't pass `--server-user` / `BEADS_DOLT_PASSWORD`, so even if the env had been populated, bd would still default to root/empty.

**Workaround (Class B)**: `gc-fix-bd-init-auth` patches the runtime `<city>/.gc/system/packs/bd/assets/scripts/gc-beads-bd.sh` to (a) source `~/.gc/secrets.env` early, with MYSQL_PWD ↔ GC_DOLT_PASSWORD bridging, and (b) pass `--server-user "$DOLT_USER"` + `BEADS_DOLT_PASSWORD="$DOLT_PASSWORD"` to the `bd init` call. Idempotent via marker checks.

```bash
ln -sf ~/dv-gascity-utils/packs/gascity-comms/assets/scripts/gc-fix-bd-init-auth \
    ~/.gc/bin/gc-fix-bd-init-auth

gc-fix-bd-init-auth --dry-run    # preview
gc-fix-bd-init-auth              # apply across all towns under $HOME
```

`gc-fix-watch` re-applies after every supervisor templater wipe. On hosts without secrets.env (yg, asgard) the bootstrap block is a no-op — DOLT_USER stays `root` and DOLT_PASSWORD stays empty, matching pre-patch behavior.

---

## Pack-template wipe on supervisor startup / heavy reconcile

**Trackers**: discussed across `mg-d80k3`, `mg-ovjgn`, `mg-pfh96` threads. No primary bead — it's the underlying mechanism that creates Class B's reason-for-existing.

**Symptom**: every supervisor startup and several heavy reconciler events re-render embedded pack contents to disk under `<city>/.gc/system/packs/`, wiping any in-place patches.

**Evidence**: `<pack>/*.toml` files have mtimes that jump uniformly across many files at the same instant; permissions reset to `0644` (your `gc-fix-*` patches typically write `0600`).

**Workaround**: `gc-fix-watch` (this repo, PR #5 + PR #8 v2). Polls each town's pack tree every 30s, debounces 2s on detected change, invokes every `gc-fix-*` helper symlinked into `~/.gc/bin/` that hasn't already been re-applied (helpers are idempotent via marker checks).

See `docs/pack-template-resilience.md` for the full design + install instructions.

---

## bd auto-backup hook tries to mkdir the user's home dir

**Trackers**: dv-gascity-utils issue #32 (filed 2026-05-02 from midgard).

**Symptom**: every `bd create` / `bd update` / `bd close` hangs 30s+ on a failing post-write hook chain. Stderr shows:

```
Warning: auto-backup failed: register backup remote: add backup backup_export:
  Error 1105 (HY000): failed to create directory '/Users/<user>/<rig>/.beads/backup':
  mkdir /Users/<user>: permission denied
Warning: auto-export: git add failed: exit status 1
```

The hook is trying to `mkdir /Users/<user>` (the user's home directory) instead of creating the intended `<rig-root>/.beads/backup` subdirectory. Looks like a parent-dir path-resolution bug — the hook walks up the tree and tries to create the topmost component instead of creating the leaf with `mkdir -p`.

**Evidence**: the dolt row update completes in ~50ms (verifiable via direct `gc dolt sql` query). The remaining ~30-120s is the hook chain timing out. `pkill -f "bd update"` is the fastest recovery; you'll see 4 child processes per stuck bd command (the hook chain).

**Class**: C — bd binary bug. The hook isn't toggleable through any documented config (`bd config set backup.enabled false` is shadowed by an auto-enable when a git remote is detected — see `bd backup status` output: `enabled=true (auto: git remote detected)` despite `backup.enabled=false` in the explicit config).

**Workaround**: none clean. Mitigation: when slinging multiple beads, do them sequentially (don't fire 3 in parallel — they all fight the same failing mkdir and the throughput is the same). Verify writes via direct dolt query (`echo "SELECT id, ... FROM <rig>.issues WHERE id='<bead>'" | gc dolt sql`) rather than waiting for `bd update` to return.

**Detection**: `gascity-stability/doctor/check-bd-throughput` (this repo). For each rig, creates a canary bead via `bd q`, times the create, then closes the bead. Fails on `>BD_THROUGHPUT_THRESHOLD_SEC` (default 5s) or wedge past `BD_THROUGHPUT_HARD_CAP_SEC` (default 30s, kills the process group so the hook chain dies). Run as part of `gc doctor`.

---

## supervisor reload silent-failure cascade (rejected reloads keep accumulating)

**Trackers**: dv-gascity-utils issues #29, #30 (root-cause auth bug); detection check at `gascity-stability/doctor/check-reload-state`.

**Symptom**: `gc supervisor reload` returns "Reconciliation triggered." cleanly. The supervisor log emits a single `gc supervisor: config reload: validating ...: ... (keeping old config)` line. From every operator-visible surface — `gc reload`, `gc config show`, `gc rig list` — the new config looks live. But the controller's running config snapshot is unchanged from supervisor startup.

ALL subsequent edits to `city.toml` (`[[orders.overrides]] enabled = false`, new `[[rigs]]`, etc.) are silently dropped against the running controller. New orders defined in newly-imported packs don't enter the dispatch loop. Operators can spend hours editing config and watching nothing happen.

**Triggers observed**:
- Duplicate-mayor agent collision (workspace pack auto-discovers `agents/<role>/` and collides with imported pack — see PR #17 wiring-gap doc, this is the most common path)
- Adopted rig with `gc.endpoint_status: unverified` triggering bd init that hits the auth bug (#29)
- `inherited_city` endpoint without explicit `dolt.host`/`dolt.port` even when city.toml has `[dolt]` set (#30)

**Class**: C — needs upstream fix to the validator (per-error reload should emit a louder signal than a single log line; ideally non-zero exit on `gc supervisor reload`).

**Workaround**: run `check-reload-state` after every `gc supervisor reload` / `gc-reload-orders` invocation. Helper exit 1 = controller is on stale snapshot; investigate the rejection reason and fix the underlying validation error before assuming any subsequent edits are live.

---

## orders shipped in top-level imported packs are not loaded

**Trackers**: dv-gascity-utils issue #31 (resolution shipped as `gc-reload-orders`); detection check at `gascity-stability/doctor/check-orders-discovery`.

**Symptom**: `docs/cross-city-comms.md` step 8 says: "Enable the mail-nudge order in your city's pack imports (gascity-comms is imported via your city's pack.toml; the order ships with the pack and runs once the pack is loaded)." This is wrong. Top-level `[imports.X]` in city `pack.toml` loads the pack's agents and template-fragments but skips its `orders/` directory entirely.

`gc only` walks `orders/` from packs reachable through the maintenance import chain (i.e. packs inside `.gc/system/packs/` transitively imported via gastown). Standalone top-level imports get their non-order content but not their orders.

**Concrete impact (mg, 2026-05-02)**: `mail-nudge` shipped in `gascity-comms/orders/mail-nudge.toml`, imported via `pack.toml [imports.gascity-comms]`. Order never appeared in `gc order list`. Cross-city wake-on-arrival was structurally broken for 4+ days before detection.

**Class**: C for the binary; the docs+binary divergence is the operational bug.

**Workaround**: drop a copy of the order .toml into `.gc/system/packs/maintenance/orders/<name>.toml` and symlink the script (if the order's `exec` references `$PACK_DIR/assets/scripts/<name>.sh`) into `maintenance/assets/scripts/`. After change: `gc-reload-orders` (controlled supervisor cycle) so the dispatch loop picks it up.

**Detection**: `check-orders-discovery` walks each `[imports.X]` source pack's `orders/`, diffs against `gc order list`, and flags missing entries. Run as part of `gc doctor`.

---

## gc bd update from outside rig dir misses freshly-created cross-rig beads

**Trackers**: GitHub `DataViking-Tech/dv-gascity-utils#27`, bead `dgu-hmbou`.

**Symptom**: `gc bd update <id>` (and other id-bearing `bd` subcommands) from a working directory outside the bead's owning rig fails with `Error resolving <id>: no issue found matching "<id>"`, even when the bead is fully present in shared dolt and visible to `gc bd list --rig <name>`. Passing `--rig <name>` explicitly works around it. The issue is a stale routing cache between bead creation and the next read — the `bd update` resolver consults the local prefix→rig cache, which doesn't yet include the new prefix mapping.

**Repro** (midgard, 2026-05-02, from mayor home outside any rig):

```bash
$ gc bd create --rig dv-gascity-utils --title "..." --type=task --priority=2
✓ Created issue: dgu-al90e — ...

$ # Direct dolt query confirms presence:
$ echo "SELECT id FROM dgu.issues WHERE id='dgu-al90e'" | gc dolt sql
| dgu-al90e |

$ # bd list --rig works:
$ gc bd list --rig dv-gascity-utils --status=open --limit 5
○ dgu-al90e  ...

$ # But bd update without --rig fails:
$ gc bd update dgu-al90e --set-metadata gc.routed_to=...
Error resolving dgu-al90e: no issue found matching "dgu-al90e"

$ # Adding --rig works:
$ gc bd update dgu-al90e --rig dv-gascity-utils --set-metadata gc.routed_to=...
✓ Updated issue: dgu-al90e
```

Several seconds elapsed between create and the failing update — not a write-visibility race; the resolver's cache misses the new prefix mapping.

**Why this matters**: slinging a freshly-created bead to a polecat pool is a two-step CLI flow — `bd create --rig <r>` then `bd update <id> --set-metadata gc.routed_to=...`. The second step needs the rig name even though the prefix on the id already pins the rig. Every dispatch script needs to know rig names, not just prefixes — an awkward surface for orchestration layers (mayors, slings, automation).

**Why no Class A**: the cache lives inside the gc binary's resolver path. No config knob forces a cache rebuild after `bd create`.

**Why no Class B**: not a pack-template surface; resolver state is gc binary memory.

**Workaround (Class A operational)**: `gc-bd` wrapper auto-derives `--rig <name>` from the bead-id prefix and injects it before exec'ing `gc bd ...`. Drop-in for `gc bd` on every id-bearing subcommand (`update`, `show`, `close`, `reopen`, `comment`, `note`, `edit`, `assign`, `priority`, `set-state`, `label`, `link`, `delete`, `promote`, `children`). Falls through unchanged if `--rig` is already passed, the id has no recognizable prefix, the prefix doesn't match a known rig, or the matched rig is the HQ rig (gc resolves HQ beads via the default path; `gc --rig <hq-name>` is rejected).

```bash
ln -sf ~/dv-gascity-utils/packs/gascity-comms/assets/scripts/gc-bd \
    ~/.gc/bin/gc-bd

# Use exactly like `gc bd`:
gc-bd update dgu-al90e --set-metadata gc.routed_to=dv-gascity-utils/polecat
gc-bd show dgu-al90e
gc-bd close dgu-al90e
```

`gc-city-bootstrap` symlinks `gc-bd` automatically — fresh hosts get it without extra setup.

Use it in dispatch scripts and from mayor sessions where the bead being updated may live in a rig other than the caller's cwd. Direct `gc bd ...` continues to work for id-less subcommands (`bd list`, `bd ready`, `bd stats`) and from inside the bead's owning rig dir.

**Test plan** (after the binary is fixed upstream): from a working dir outside any rig, run `gc bd create --rig <r> --title ...` followed immediately by `gc bd update <id> --set-metadata k=v` WITHOUT `--rig` and confirm the update succeeds. Until that fix lands, validation runs through `gc-bd`.

---

## How to add a new entry

1. Reproduce on at least one host. Capture exact error strings + binary version.
2. File a tracking bead in your local store: `bd create --title="[gc binary bug] <symptom>" --type=bug`.
3. If the bug is cross-host, mirror to dgu via direct SQL (see mg-pfh96 → dgu-pfh96 example) or ask the dgu owner to mirror.
4. Add a section to this file with: trackers, symptom, evidence, workaround (or "none — Class C").
5. Cross-reference from the bead's metadata: `bd update <id> --set-metadata docs_url=<this-file>`.
