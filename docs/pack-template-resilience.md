# Pack template resilience: gc-fix-watch

The gc binary embeds pack contents (formulas, orders, prompt templates,
etc.) at compile time and re-renders them to disk under
`<town>/.gc/system/packs/` on supervisor startup, on some `gc supervisor
reload` paths, and during heavy reconciler events. Any in-place patches
applied by `gc-fix-*` helpers are wiped by the next render burst.

This is wider than "survives `gc supervisor reload`" — see midgard ↔
yggdrasil coordination thread (mg-wisp-oly, yg-wisp-t6k, ..., yg-wisp-pt7)
for evidence on both hosts. Marker-based idempotency in helpers protects
against double-patching but does nothing about templater wipe.

## Why not patch the source

The gc binary embeds packs at compile time. `strings $(which gc)` returns
exact pack content. There is no source-on-disk to patch — `<brew>/Cellar/
gascity/<ver>/` contains only the binary. So:

- A binary fix that adds config-level pool override (e.g. `[[orders.overrides]] pool = "<fqn>"` actually being honored by the dispatch path) is the right long-term answer.
- Until that lands, post-template fix is the only host-local option.

## What gc-fix-watch does

Polling daemon (no fswatch dep):

1. Discovers towns: every `$HOME/<town>/.gc/system/packs/`.
2. Hashes each town's pack tree (mtime + size + path, sorted, sha256).
3. Every `--interval` seconds, re-hashes; if changed, debounces 2s, then
   invokes every executable named `gc-fix-*` in `~/.gc/bin/` against the
   town root. Helpers themselves are idempotent (marker-based) — re-fires
   on unchanged trees report "already fixed" and exit cheaply.
4. Updates the baseline post-helpers (helpers may rewrite files).

Pack-agnostic: any future helper participates by symlinking into
`~/.gc/bin/gc-fix-<name>`. No edits to gc-fix-watch required.

## Installing

```bash
ln -sf ~/dv-gascity-utils/packs/gascity-comms/assets/scripts/gc-fix-watch \
    ~/.gc/bin/gc-fix-watch
```

Foreground for testing:

```bash
gc-fix-watch --interval 30
```

Background (macOS):

```bash
sed "s|{{HOME}}|$HOME|g" \
    ~/dv-gascity-utils/packs/gascity-comms/assets/launchd/com.dv-gascity.fix-watch.plist.template \
    > ~/Library/LaunchAgents/com.dv-gascity.fix-watch.plist
launchctl load ~/Library/LaunchAgents/com.dv-gascity.fix-watch.plist
tail -f ~/Library/Logs/gc-fix-watch.log
```

Background (Linux):

```bash
cp ~/dv-gascity-utils/packs/gascity-comms/assets/systemd/gc-fix-watch.service.template \
    ~/.config/systemd/user/gc-fix-watch.service
systemctl --user daemon-reload
systemctl --user enable --now gc-fix-watch.service
journalctl --user -u gc-fix-watch -f
```

## Operating notes

- **Initial helper run.** gc-fix-watch only re-applies on detected change.
  If the gc binary re-templates the pack tree before the watcher starts,
  the watcher takes a baseline of the wiped state and never re-applies.
  Run helpers manually once before activating the watcher (or include a
  startup-run wrapper if you prefer).
- **Cadence.** 30s default is well under the time it takes for
  re-templated work to propagate to running sessions. Tighten with
  `--interval` if you observe missed cycles.
- **Helper failures don't kill the watcher.** A non-zero exit from any
  fix-* helper is logged and ignored; subsequent helpers in the same
  cycle still run.
- **Excludes self.** gc-fix-watch matches its own name pattern but is
  filtered out at dispatch — no infinite recursion when symlinked
  alongside the other helpers.

## Tracking

- mg-side: see mg-ovjgn (pool FQN mismatch root cause) and the coordination
  thread starting at mg-wisp-oly.
- The "real fix" is binary-side: orders.overrides should accept and honor
  a `pool` field, and the templater should not silently overwrite files
  that already match the desired output. Both filed as upstream bugs.
