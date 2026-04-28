# Multiple Cities, One Dolt Server

> **Status:** skeleton. Polecat: flesh out the sections below from the live setup on `mani-mac-mini` (yggdrasil + asgard against shared dolt at 127.0.0.1:16022) and the cross-machine setup with midgard (`sol-mac-mini`).

## What this pattern is

(Polecat: explain the architecture in 2-3 paragraphs. Each city runs its own gc supervisor + controller. They share a single Dolt SQL server. The shared server hosts one database per rig prefix — yg, mg, as, sp, etc. Cities are isolated at the database level (each city's controller only writes to its own prefix-rooted DB) but the shared server gives a single point of backup, observability, and cross-database queries.)

## Why this pattern

- (Pro: simpler ops, single dolt instance to back up / observe)
- (Pro: cross-database visibility for tooling like `gc dolt list`)
- (Pro: makes the "shared rig" pattern possible — multiple cities working on the same `sp` DB)
- (Con: shared failure domain — dolt outage hits all cities)

## How to set it up

(Polecat: write the step-by-step. Look at `gc beads city use-external --host 127.0.0.1 --port 16022 --user root` — that's the command that points a city at the shared server. Reference the asgard-shared-dolt steps captured in `~/.claude/projects/-Users-mani-yggdrasil/memory/cross_city_architecture.md` if available.)

Steps to capture:
1. Stand up dolt server on the canonical host (port 16022 here).
2. New city: `gc init <name>`. Default uses embedded mode (its own dolt server on a different port).
3. Switch to shared: `gc beads city use-external --city <path> --host <shared-host> --port 16022 --user root --adopt-unverified`.
4. Stop/clean the embedded dolt artifacts in `<city>/.beads/dolt*`.
5. Create the database on the shared server: `dolt sql -q "CREATE DATABASE \`<prefix>\`"` (note backticks for reserved-word prefixes like `as`).
6. Bootstrap the schema (clone from another city's DB or apply schema dump).
7. Insert the `issue_prefix` config row (manual gotcha — bd init in this mode doesn't always seed it).
8. Reload city + verify with `bd list`.

## Reference

- Live yg + asgard config in `/Users/mani/yggdrasil/.beads/config.yaml` and `/Users/mani/asgard/.beads/config.yaml`.
- The dolt server config is auto-generated under `~/yggdrasil/.gc/runtime/packs/dolt/dolt-config.yaml`.
