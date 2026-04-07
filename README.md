# Simple tool for migrating Postgres databases between providers

Single-script tool for minimal-downtime PostgreSQL migrations using `pg_dump`/`pg_restore` and logical replication.

Features:
* minimal downtime by syncing via logical replication
* copy the bulk of the data via pg_dump / pg_restore
* monitor, preflight and verify commands
* optional TCP level proxy for working around firewalls and VPN access

## Prerequisites

- PostgreSQL client tools: `psql`, `pg_dump`, `pg_restore` (version >= source server)
- `python3`
- `socat` (only if using the proxy feature)

## Quick Start

```bash
export SRC='postgresql://user:pass@source-host:5432/mydb'
export TGT='postgresql://user:pass@target-host:5432/mydb'

./migrate.sh preflight
./migrate.sh copy-schema
./migrate.sh dump-and-restore
./migrate.sh monitor           # watch until lag ~ 0, then Ctrl+C
# stop app
./migrate.sh monitor           # watch until lag = 0, normally immediatelly
./migrate.sh verify
./migrate.sh cutover
./migrate.sh verify            # final check
# start app with new connection string
```

## Subcommands

| Command | Description |
|---------|-------------|
| `preflight` | Check tools, PG versions, `wal_level`, replication settings, extensions, db size |
| `check-fks` | Verify excluded tables have no incoming foreign keys |
| `copy-schema` | Dump schema from source, apply pre-data (tables, sequences) to target |
| `verify-schema` | Compare tables, columns, indexes, sequences, FKs between source and target |
| `dump-and-restore` | Create publication + replication slot, snapshot dump, restore data + indexes, start subscription |
| `proxy` | Start a TCP proxy (socat) so the target can reach the source through this machine |
| `proxy-test` | Test proxy connectivity — local check + test subscription from target |
| `monitor` | Watch replication lag in a loop |
| `verify` | Compare row counts, sequence gaps, MD5 checksums, replication lag, sequence values |
| `cutover` | Sync sequences, disable + drop subscription, drop publication |
| `cleanup` | Abort/reset a failed migration — tolerant of missing objects |

## Environment Variables

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `SRC` | Yes | | Source PostgreSQL connection string |
| `TGT` | Yes | | Target PostgreSQL connection string |
| `MIGRATE_SLOT` | No | `migration_sub` | Replication slot name |
| `MIGRATE_PUB` | No | `migration_pub` | Publication name |
| `MIGRATE_JOBS` | No | `4` | Parallel jobs for pg_restore |
| `MIGRATE_DUMP_JOBS` | No | `1` | Parallel jobs for pg_dump (off by default) |
| `MIGRATE_WORK_DIR` | No | `.` | Directory for dump files |
| `MIGRATE_MONITOR_INTERVAL` | No | `5` | Seconds between monitor checks |
| `MIGRATE_SCHEMAS` | No | all | Comma-separated schemas to dump (e.g. `public`) |
| `MIGRATE_EXCLUDE_TABLES` | No | | Comma-separated tables to exclude entirely (schema + data). Supports `*` wildcards. |
| `MIGRATE_EXCLUDE_DATA` | No | | Comma-separated tables to exclude from data dump only (schema still copied). Supports `*` wildcards. |
| `MIGRATE_SRC_PROXY` | No | `$SRC` | Connection string the target uses to reach the source (via proxy) |
| `MIGRATE_PROXY_PORT` | No | `5432` | Local port for the socat proxy |

## How It Works

The migration follows these phases:

1. **Schema copy** — `pg_dump --schema-only` + `pg_restore --section=pre-data` creates tables and sequences on the target without indexes or foreign keys.

2. **Snapshot dump** — A Python process holds a transaction open that atomically creates a replication slot and exports a snapshot. `pg_dump` uses that snapshot to dump all data. This guarantees no gap or overlap between the dump and the replication stream.

3. **Restore** — `pg_restore` loads the data in parallel, then builds indexes and foreign keys from the post-data section.

4. **Replication** — A logical subscription on the target replays all WAL accumulated since the snapshot, then streams live changes.

5. **Cutover** — Once replication lag reaches zero, sequences are synced and the subscription is torn down.

See [docs/postgres-migration-guide.md](docs/postgres-migration-guide.md) for the full manual procedure this tool automates.

## Proxy

If the target database cannot directly reach the source (e.g. the source is behind a VPN or Tailscale), run the proxy on a machine that can reach both:

```bash
# Terminal 1: start proxy
./migrate.sh proxy

# Terminal 2: test it
export MIGRATE_SRC_PROXY='postgresql://user:pass@proxy-host:5432/mydb'
./migrate.sh proxy-test
```

The proxy uses `socat` to forward TCP connections. The `proxy-test` command creates a temporary subscription to verify end-to-end connectivity.

## Excluding Tables

For databases with extensions like TimescaleDB that create internal tables, or tables with known data issues:

```bash
# Exclude entirely (schema + data + replication)
export MIGRATE_EXCLUDE_TABLES='largetable_*,staging_backfill_*'

# Exclude data only (schema copied, but no rows dumped or replicated)
export MIGRATE_EXCLUDE_DATA='large_audit_log'

# Verify exclusions are safe (no FK references)
./migrate.sh check-fks
```

Unlogged tables are automatically excluded from the publication (they cannot participate in logical replication).

## Aborting a Failed Migration

```bash
./migrate.sh cleanup
```

This tolerantly drops the subscription, publication, and replication slot. Safe to run even if some objects don't exist.

To fully reset the target:

```sql
DROP SCHEMA public CASCADE;
CREATE SCHEMA public;
```

Then restart from `copy-schema`.
