# Multiple Cities, One Dolt Server

Each Gas City "city" is its own GC supervisor + controller + runtime tree.
This pattern keeps that one-supervisor-per-city autonomy but folds every
city's beads storage into a single shared Dolt SQL server. Cities stay
isolated at the database level (one SQL database per rig prefix) while
sharing one process, one data directory, one backup target, and one set of
diagnostic tools.

Verified live on `mani-mac-mini`: `yggdrasil` (the canonical host) and
`asgard` (an external city on the same machine) both write into the dolt
server at `127.0.0.1:16022`, with data on disk under
`/Users/mani/yggdrasil/.beads/dolt`.

## What this pattern is

- **Per-city supervisor.** Each city retains its own `gc` supervisor,
  controller, runtime tree (`<city>/.gc/`), pack imports, hooks, mail,
  formulas, etc. Cities do not share a control plane.
- **Shared Dolt SQL server.** Exactly one `dolt sql-server` process runs.
  It listens on a single TCP port. Every city's `.beads/config.yaml`
  points at that endpoint.
- **One database per rig prefix.** Each rig's prefix (`yg`, `as`, `sp`,
  `dgu`, …) maps to a Dolt database with the same name. A city's
  controller only touches databases whose prefixes belong to its rigs.
- **Canonical vs. external roles.** One city is the *canonical host* —
  it owns the `dolt sql-server` config (under
  `<city>/.gc/runtime/packs/dolt/`), starts/stops the server, and owns
  the on-disk data directory. Every other city is *external* — it has
  no local dolt process; its config records the canonical host's
  `host`/`port`/`user`.

## Architecture

```
   yggdrasil (canonical)              asgard (external)
   /Users/mani/yggdrasil              /Users/mani/asgard
   ─────────────────────              ────────────────────
   gc supervisor                       gc supervisor
   controller                          controller
   pack: dolt  ◄── owns server         (no dolt pack)
   prefix: yg                          prefix: as
            │                                  │
            │   127.0.0.1:16022                │
            └────────►  ◄─────────────────────┘
                        │
              ┌─────────▼──────────────────┐
              │     dolt sql-server        │
              │  data_dir:                 │
              │   ~/yggdrasil/.beads/dolt  │
              │  databases:                │
              │   yg, as, dgu, sp, sy, mg  │
              └────────────────────────────┘
```

The endpoint is loopback. Cross-host dolt sharing (e.g. via Tailscale)
is not wired up by these commands today — the `cross-city-comms.md`
gateway is for the supervisor HTTP API, not the SQL server. Cities co-
located on the same host can share dolt; cities on different hosts each
run their own server.

## Concepts

### Endpoint origin/status

Each city's `.beads/config.yaml` carries two GC-specific keys that record
which side of the relationship it sits on:

| `gc.endpoint_origin` | Meaning                                            |
|----------------------|----------------------------------------------------|
| `managed_city`       | City owns the dolt server (canonical host)         |
| `city_canonical`     | City points at an external dolt server             |

`gc.endpoint_status` is `verified` (live-checked at config time) or
`unverified` (recorded without contacting the server — set by
`use-external --adopt-unverified`).

### One database per prefix

`bd` and `gc beads` resolve a city's storage by reading
`metadata.json → dolt_database` (e.g. `"dolt_database": "as"`) and
opening that database on the configured server. The DB name equals the
rig prefix, not the city name.

### Reserved-word prefixes

Some prefixes collide with SQL reserved words: `as` is the obvious one
that's already in use, but `is`, `or`, `to`, `in`, `on` would break the
same way. Anywhere these names appear in raw SQL they need backticks:

```sql
USE `as`;
SELECT * FROM `as`.issues;
CREATE DATABASE `as`;
```

`gc dolt list`, `gc bd …`, and `gc dolt sql` quote correctly internally.
Hand-written SQL (including the manual setup steps below) must quote.

## Why this pattern

Pros (observed):

- **Single backup target.** Backing up `<canonical>/.beads/dolt` covers
  every city's data. `gc dolt sync` pushes one set of remotes.
- **Cross-database visibility.** `gc dolt list` enumerates every city's
  prefix from one place. `gc dolt sql` can run cross-DB queries.
- **Less process overhead.** One `dolt sql-server` instead of N. No port
  collisions or per-city RAM duplication.
- **Foundation for the shared-rig pattern.** Multiple cities can mount
  the same prefix database (the open design problem in
  [`shared-rig-prefix.md`](./shared-rig-prefix.md) depends on this).

Cons (observed):

- **Shared failure domain.** If the canonical city's dolt process dies
  or the data dir is corrupted, every external city loses beads access
  — even ones owned by a city the human didn't touch.
- **Asymmetric disk footprint.** All databases physically live under
  the canonical host's `<city>/.beads/dolt`. `du -sh` on the canonical
  city includes data the canonical city doesn't own.
- **Reserved-word minefield.** Prefix `as` works but every SQL touch of
  it needs backticks. Easy to forget in ad-hoc queries.
- **`bd init` doesn't fully seed external-mode databases.** The
  `issue_prefix` config row sometimes has to be hand-inserted (see
  pitfalls).
- **Loopback-only.** Cities on different hosts can't currently share a
  server through these commands.

## Worked recipe: convert an embedded city to shared

This is the actual asgard story. Asgard was created by `gc init` in
embedded dolt mode — it had its own `dolt sql-server` listening on
port 16640 (the port is hashed from the city path, so it's stable per
city but not predictable). The goal: have asgard share yggdrasil's
existing server at `127.0.0.1:16022` instead.

### 1. Confirm the canonical server is up

```bash
gc --city /Users/mani/yggdrasil dolt status
```

If not running:

```bash
gc --city /Users/mani/yggdrasil dolt start
```

The server config lives at
`/Users/mani/yggdrasil/.gc/runtime/packs/dolt/dolt-config.yaml` and is
managed by the dolt pack — don't edit it by hand.

### 2. Point the external city at the shared endpoint

```bash
gc beads city use-external \
  --city /Users/mani/asgard \
  --host 127.0.0.1 \
  --port 16022 \
  --user root \
  --adopt-unverified
```

This rewrites `<city>/.beads/config.yaml`:

- adds `dolt.host`, `dolt.port`, `dolt.user`
- sets `dolt.auto-start: false` (no embedded server anymore)
- sets `gc.endpoint_origin: city_canonical`
- sets `gc.endpoint_status: unverified` (because of `--adopt-unverified`)
- rewrites inherited rig mirrors so each rig under the city points at
  the same canonical endpoint

`--dry-run` is available if you want to see the planned rewrites first.
`--adopt-unverified` is what you want when the database it's about to
adopt doesn't exist yet (you're about to create it in step 3); without
it, `use-external` will refuse to adopt an endpoint it can't validate.

The reverse, `gc beads city use-managed`, swings a city back to running
its own embedded server.

### 3. Create the database on the shared server

`use-external` does not create the DB. Do it manually, with backticks
if the prefix is a reserved word:

```bash
gc --city /Users/mani/yggdrasil dolt sql -q "CREATE DATABASE \`as\`"
```

For non-reserved prefixes the backticks are optional but harmless.

### 4. Hand-seed the `issue_prefix` config row

Known gap: when a city is in external (canonical) mode, `bd init`
doesn't reliably seed the `issue_prefix` row in the new database's
`config` table. Without it, `bd` cannot mint new issue IDs for the city.
Insert it manually and commit (Dolt commits, not git):

```bash
gc --city /Users/mani/yggdrasil dolt sql -q "USE \`as\`; \
  INSERT INTO config VALUES('issue_prefix','as'); \
  CALL DOLT_COMMIT('-Am','seed issue_prefix');"
```

### 5. Bootstrap schema

If the database is empty, populate the bd schema. Either let `bd init`
run (it will create the tables even if it skips the config row) or
clone the schema from another already-populated database with
`bd bootstrap`.

### 6. Verify

```bash
cd /Users/mani/asgard
gc bd list                    # should hit the shared server
gc dolt list                  # should now include `as` from any city
```

For asgard the resulting `<city>/.beads/config.yaml` looks like:

```yaml
issue_prefix: as
issue-prefix: as
dolt.auto-start: false
gc.endpoint_origin: city_canonical
gc.endpoint_status: unverified
dolt.host: 127.0.0.1
dolt.port: 16022
dolt.user: root
```

Compare with the canonical host (yggdrasil), which has no host/port:

```yaml
issue_prefix: yg
issue-prefix: yg
dolt.auto-start: false
gc.endpoint_origin: managed_city
gc.endpoint_status: verified
```

### 7. Optional: clean up embedded artifacts

Switching to external mode does not delete the city's old embedded
dolt files. After the migration, asgard still had the leftovers:

```
asgard/.beads/dolt              # old data dir
asgard/.beads/embeddeddolt
asgard/.beads/dolt-server.port
asgard/.beads/dolt-server.port.bak
asgard/.beads/dolt.embedded.bak
asgard/.gc/runtime/packs/dolt/  # old dolt pack runtime
```

These are safe to remove once the shared endpoint is verified working.
There is no automated cleanup; the only first-class tool in this area
is `gc dolt cleanup`, which removes orphaned databases on the *server*
side (not stale embedded artifacts under an external city).

## Pitfalls

### Reserved-word prefixes break ad-hoc SQL

Prefix `as` is in production use today. Without backticks, statements
like `USE as` and `CREATE DATABASE as` are syntax errors. Always quote
when writing raw SQL against these prefixes; `gc` and `bd` themselves
quote correctly.

### `bd init` doesn't seed `issue_prefix` in external mode

In the asgard migration the `config` table came up empty enough that
`bd` couldn't mint IDs until the `issue_prefix` row was hand-inserted
(step 4 above). Treat this as a required manual step when adopting a
fresh prefix on the canonical server. It's reasonable to also re-run
`gc dolt sql -q "USE \`<prefix>\`; SELECT * FROM config"` to spot-check
that the row landed.

### Embedded dolt port is hashed from the city path

Before the migration, asgard's embedded dolt was on port 16640. That
number isn't configurable; it's derived from the absolute city path.
Don't try to memorize it — read it from the city's local
`<city>/.gc/runtime/packs/dolt/dolt-config.yaml`. Once the city is
external, the embedded port is irrelevant (and the server isn't running
anyway because `dolt.auto-start: false`).

### Embedded artifacts persist after migration

`use-external` rewrites configs but doesn't delete the old embedded
data dir or pack runtime under the city. Leaving them is harmless but
clutters disk-usage analysis and confuses anyone reading the city's
`.beads/`. Remove them by hand after the new endpoint is verified
(step 7).

### Data physically lives on the canonical host

Every database on the shared server lives under
`<canonical-city>/.beads/dolt/<prefix>/`. Asgard's data is on
yggdrasil's disk. Backups, snapshots, `du`, accidental `rm`, encryption
configs — all of these live with the canonical host, not with the
city the data "belongs" to.

### `gc dolt sql` interactive auth

`gc dolt sql -q '…'` will refuse non-interactive mode without
credentials in some environments (`Failed to parse credentials:
operation not supported by device`). Use `gc --city <canonical> dolt
sql -q '…'` from a terminal that can handle a password prompt, or pipe
in via the dolt CLI directly when scripting.

### Cross-host sharing is not implemented

The dolt listener defaults to `0.0.0.0` in the generated config but the
GC tooling assumes loopback when a city is external. If you want
`midgard` (different machine) to share `mani-mac-mini`'s dolt server
you need a bespoke setup — none of `gc beads city use-external`,
`gc dolt`, or the Caddy gateway is the right tool. For now: each host
runs its own dolt server, cross-host coordination happens through the
mail gateway, not the SQL server.

## Reference

Live config (as of writing):

- `/Users/mani/yggdrasil/.beads/config.yaml` — `managed_city` example
  (no host/port; owns the server)
- `/Users/mani/asgard/.beads/config.yaml` — `city_canonical` example
  (records `dolt.host`/`dolt.port`/`dolt.user`)
- `/Users/mani/yggdrasil/.gc/runtime/packs/dolt/dolt-config.yaml` —
  generated server config; port `16022`, data dir
  `~/yggdrasil/.beads/dolt`
- `gc dolt list` (from any city) — shows `yg`, `as`, `dgu`, `sp`, `sy`,
  `mg`

CLI surfaces touched in this recipe:

- `gc beads city use-external` / `use-managed` (with `--dry-run`,
  `--adopt-unverified`)
- `gc dolt status` / `start` / `list` / `sql` / `cleanup` / `sync` /
  `health`
- `bd init`, `bd bootstrap`, `bd list`

Related docs:

- [`cross-city-comms.md`](./cross-city-comms.md) — supervisor HTTP API
  cross-host (Caddy + `gcx`); orthogonal to the dolt sharing pattern.
- [`shared-rig-prefix.md`](./shared-rig-prefix.md) — joining more than
  one city to the *same* prefix DB on the shared server. Recipe + helper
  + `metadata`-table audit + verified single-host primitives. Cross-host
  validation pending.
