# PostgreSQL Migration Guide — Minimal Downtime (Manual)

> This is the **fully manual** step-by-step procedure for cross-provider
> PostgreSQL migration using `pg_dump`/`pg_restore` + logical replication.
>
> For an automated version that handles snapshot coordination, progress
> monitoring, proxy setup, and table exclusions, see
> [`migrate.sh`](../README.md) in the root of this repository.

---

## Connection Variables

Set these once and reuse throughout:

```bash
# Source (old provider)
export SRC_HOST="source-db.oldprovider.com"
export SRC_PORT="5432"
export SRC_DB="myapp"
export SRC_USER="myapp_admin"

# Target (new provider)
export TGT_HOST="target-db.newprovider.com"
export TGT_PORT="5432"
export TGT_DB="myapp"
export TGT_USER="myapp_admin"

# Shorthand connection strings
export SRC="postgresql://${SRC_USER}@${SRC_HOST}:${SRC_PORT}/${SRC_DB}"
export TGT="postgresql://${TGT_USER}@${TGT_HOST}:${TGT_PORT}/${TGT_DB}"
```

---

## Step 1 — Pre-flight Checks

### Check PostgreSQL versions

```bash
psql "$SRC" -c "SELECT version();"
psql "$TGT" -c "SELECT version();"
```

### List extensions on source

```bash
psql "$SRC" -c "SELECT extname, extversion FROM pg_extension ORDER BY extname;"
```

### Check database size

```bash
psql "$SRC" -c "SELECT pg_size_pretty(pg_database_size('$SRC_DB'));"
```

### Verify `wal_level` is set to `logical` on source

```bash
psql "$SRC" -c "SHOW wal_level;"
```

> If it's not `logical`, you'll need to change it and restart the source.
> Many managed providers let you set this via a parameter group / config panel.
>
> ```sql
> ALTER SYSTEM SET wal_level = 'logical';
> -- Then restart the PostgreSQL instance
> ```

### Check `max_replication_slots` and `max_wal_senders`

```bash
psql "$SRC" -c "SHOW max_replication_slots;"
psql "$SRC" -c "SHOW max_wal_senders;"
```

> Ensure both are >= the number of subscriptions you plan to create (at least 1).

---

## Step 2 — Create Roles on Target

Dump roles from source and apply to target. `pg_dumpall` with `--roles-only`
pulls global role definitions:

```bash
pg_dumpall -h "$SRC_HOST" -p "$SRC_PORT" -U "$SRC_USER" --roles-only > roles.sql
```

Review and clean up the file (remove provider-specific superuser roles, etc.):

```bash
less roles.sql    # review before applying
psql "$TGT" -f roles.sql
```

---

## Step 3 — Migrate Schema (Pre-data Only)

We use `pg_dump` with `--format=directory` so we can restore in sections:

- **pre-data:** table definitions, types, sequences — no indexes or constraints
- **post-data:** indexes, foreign keys, triggers — applied after the data load

This is faster than creating indexes before the load (bulk index creation is
much faster than incremental inserts into existing indexes) and avoids FK
ordering issues during parallel restore entirely.

### Dump schema

```bash
pg_dump "$SRC" \
  --schema-only \
  --no-owner \
  --no-privileges \
  --format=directory \
  --file=schema.dir
```

> `--no-owner` and `--no-privileges` help avoid errors from roles
> that don't exist yet or differ between providers.
>
> **Tip:** If the source has extensions with large internal catalogs (e.g.
> TimescaleDB with thousands of chunk tables), add `--schema=public` to
> limit the dump to your application schema. This can reduce dump time
> from tens of minutes to seconds.

### Install required extensions on target first

```bash
# For each extension your app uses:
psql "$TGT" -c "CREATE EXTENSION IF NOT EXISTS pgcrypto;"
psql "$TGT" -c "CREATE EXTENSION IF NOT EXISTS pg_trgm;"
# ... etc.
```

### Apply pre-data section (tables only — no indexes, no FKs)

```bash
pg_restore \
  --dbname="$TGT" \
  --no-owner \
  --no-privileges \
  --section=pre-data \
  schema.dir 2>&1 | tee schema_import.log
```

> The post-data section (indexes + FKs) will be applied **after** the
> data load in Step 5. This makes the restore faster and avoids FK
> ordering problems during parallel restore.

### Verify — compare table counts

```bash
# Source
psql "$SRC" -c "SELECT schemaname, count(*) FROM pg_tables
  WHERE schemaname NOT IN ('pg_catalog','information_schema')
  GROUP BY schemaname;"

# Target (should match)
psql "$TGT" -c "SELECT schemaname, count(*) FROM pg_tables
  WHERE schemaname NOT IN ('pg_catalog','information_schema')
  GROUP BY schemaname;"
```

---

## Step 4 — Create Publication + Replication Slot + Dump (Atomically)

The key to a gap-free migration is that the replication slot and the data
dump share **the same consistent snapshot**. The slot will replay WAL
starting right after that snapshot, while the dump captures everything up
to it — no gap, no overlap, no duplicates.

> **Why this matters:** If the slot and the dump use different snapshots
> (e.g., creating the slot in one transaction and exporting a snapshot in
> another), any writes committed between the two points will appear in
> *both* the dump and the WAL stream, causing duplicate-key errors when
> the subscriber tries to apply them.

### 4a. On the source — create the publication

```bash
psql "$SRC" -c "CREATE PUBLICATION migration_pub FOR ALL TABLES;"
```

> To replicate only specific tables:
> ```sql
> CREATE PUBLICATION migration_pub FOR TABLE users, orders, products;
> ```
>
> **Note:** Unlogged tables cannot be added to publications (they don't
> generate WAL). If you have unlogged tables, use an explicit table list
> instead of `FOR ALL TABLES`. The `migrate.sh` tool handles this
> automatically.

### 4b. Create the replication slot, export a snapshot, and dump — all from the same consistent point

The replication slot must be created and the snapshot exported **in the
same transaction**, and that transaction must use **REPEATABLE READ**
isolation. That transaction must stay open until `pg_dump` finishes
using the snapshot.

> **Why REPEATABLE READ READ ONLY?** With the default READ COMMITTED
> isolation, each statement gets a fresh snapshot. Writes committed
> between `pg_create_logical_replication_slot` and `pg_export_snapshot()`
> would appear in both the dump (via the newer snapshot) and the WAL
> stream (via the slot), causing duplicate-key errors. REPEATABLE READ
> locks the snapshot at the first statement, ensuring the slot and the
> exported snapshot share the same consistent point. READ ONLY further
> prevents accidental writes in this session.

```bash
# Terminal 1 — create slot + export snapshot, keep the transaction open
#
# IMPORTANT: run psql interactively (do NOT use a heredoc — it closes
# stdin and psql exits, rolling back the transaction).
psql "$SRC"
```

Then type these commands at the psql prompt:

```sql
BEGIN TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY;
SELECT pg_create_logical_replication_slot('migration_sub', 'pgoutput');
SELECT pg_export_snapshot();
-- Note the snapshot ID, e.g. '00000003-00000001-1'
-- *** Keep this session open until pg_dump finishes ***
```

```bash
# Terminal 2 — run pg_dump using that snapshot
pg_dump "$SRC" \
  --data-only \
  --format=directory \
  --compress=gzip \
  --snapshot="00000003-00000001-1" \
  --file=data.dir
```

> **Note on compression:** `zstd` gives better compression ratio and speed
> but not all `pg_dump` builds include zstd support. Use `gzip` as a safe
> fallback. Use `--compress=0` if CPU is the bottleneck and you have disk
> to spare.

> Replace `00000003-00000001-1` with the actual snapshot ID from Terminal 1.
>
> Once pg_dump completes, go back to Terminal 1 and type `COMMIT;`. The
> replication slot persists independently of the transaction.
>
> **Do NOT commit before pg_dump finishes** — the snapshot is only valid
> while the exporting transaction is open.
>
> **Why directory format?** `pg_restore --jobs` works best with directory
> format, enabling parallel restore across tables. The dump itself is
> single-threaded when pinned to a snapshot (`--snapshot` and `--jobs`
> cannot be combined), but the restore in the next step benefits greatly
> from parallelism.

### 4c. Monitor WAL retention during the load

The slot prevents WAL cleanup until the subscriber catches up. For large
databases where the dump + restore takes hours, WAL can accumulate on the
source. Keep an eye on disk usage:

```bash
# Check WAL disk usage on source
psql "$SRC" -c "
  SELECT
    slot_name,
    pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn) AS retained_wal_bytes,
    pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) AS retained_wal
  FROM pg_replication_slots
  WHERE slot_name = 'migration_sub';
"
```

> **Warning:** If the source runs low on disk, you may need to abort and
> drop the slot with `SELECT pg_drop_replication_slot('migration_sub');`.
> Ensure you have enough headroom before starting (estimate: retained WAL ≈
> write rate × total dump+restore time).

---

## Step 5 — Restore Data + Start Replication

### 5a. Restore data to target (parallel)

Since we applied only the pre-data section in Step 3 (tables without
indexes or foreign keys), we can safely do a parallel restore with no
FK ordering issues and no index maintenance overhead:

```bash
pg_restore \
  --dbname="$TGT" \
  --data-only \
  --no-owner \
  --no-privileges \
  --jobs=4 \
  data.dir 2>&1 | tee restore.log
```

> Adjust `--jobs` to match your available cores. For large databases,
> 4–8 jobs is a good starting point.

### 5b. Build indexes and foreign keys

Now apply the post-data section from the schema dump. This builds all
indexes from scratch (much faster than incremental inserts) and creates
foreign keys in one pass:

```bash
pg_restore \
  --dbname="$TGT" \
  --no-owner \
  --no-privileges \
  --jobs=4 \
  --section=post-data \
  schema.dir 2>&1 | tee postdata.log
```

> This is also parallelizable — indexes on different tables are built
> concurrently.

### 5c. Verify row counts after load

```bash
for table in users orders products; do
  echo "=== $table ==="
  psql "$SRC" -t -c "SELECT count(*) FROM $table;"
  psql "$TGT" -t -c "SELECT count(*) FROM $table;"
done
```

> Counts may differ slightly because writes continued on source during the
> load. That's expected — replication will catch up the delta.

### 5d. On the target — create the subscription using the existing slot

```bash
psql "$TGT" -c "
  CREATE SUBSCRIPTION migration_sub
    CONNECTION 'host=${SRC_HOST} port=${SRC_PORT} dbname=${SRC_DB} user=${SRC_USER} password=YOUR_PASSWORD'
    PUBLICATION migration_pub
    WITH (
      copy_data = false,       -- we already loaded the data
      create_slot = false,     -- use the slot we created in Step 4b
      slot_name = 'migration_sub'
    );
"
```

> **Why `copy_data = false` and `create_slot = false`:**
> - The bulk load already handled the initial data.
> - The replication slot was created before the dump, so all WAL since
>   that point has been retained. The subscription will now replay those
>   accumulated changes and then switch to live streaming.
>
> **Connectivity:** The `CONNECTION` string must be reachable from the
> target database server, not from your workstation. If the target cannot
> directly reach the source (e.g. source is behind a VPN), you can use a
> TCP proxy (`socat`) on a machine that can reach both:
> ```bash
> # On a machine with access to both source and target
> socat TCP-LISTEN:5432,fork,reuseaddr TCP:source-host:5432
> ```
> Then use the proxy machine's address in the `CONNECTION` string.

### 5e. Verify replication is running

```bash
# On source — check the slot is now active
psql "$SRC" -c "SELECT slot_name, active, restart_lsn FROM pg_replication_slots;"

# On target — check subscription status
psql "$TGT" -c "SELECT subname, subenabled, subconninfo FROM pg_subscription;"

# On target — check replication worker status
psql "$TGT" -c "
  SELECT
    pid,
    subname,
    received_lsn,
    latest_end_lsn,
    latest_end_time
  FROM pg_stat_subscription
  WHERE subname = 'migration_sub';
"
```

### 5f. Monitor replication lag over time

```bash
# Run on source to see how far behind the subscriber is
psql "$SRC" -c "
  SELECT
    slot_name,
    confirmed_flush_lsn,
    pg_current_wal_lsn(),
    pg_wal_lsn_diff(pg_current_wal_lsn(), confirmed_flush_lsn) AS lag_bytes
  FROM pg_replication_slots
  WHERE slot_name = 'migration_sub';
"
```

> The subscription will first replay the WAL that accumulated during the
> dump + restore. Once `lag_bytes` is consistently near 0, you're ready
> for cutover.

---

## Step 6 — Validate Data on Target

### Compare row counts across all tables

```bash
psql "$SRC" -t -A -c "
  SELECT tablename FROM pg_tables
  WHERE schemaname = 'public' ORDER BY tablename;
" | while read -r table; do
  src_count=$(psql "$SRC" -t -A -c "SELECT count(*) FROM \"$table\";")
  tgt_count=$(psql "$TGT" -t -A -c "SELECT count(*) FROM \"$table\";")
  if [ "$src_count" != "$tgt_count" ]; then
    echo "MISMATCH $table: src=$src_count tgt=$tgt_count"
  else
    echo "OK       $table: $src_count rows"
  fi
done
```

### Spot-check a few critical tables with checksums

```bash
# MD5 checksum of entire table (works for small-medium tables)
psql "$SRC" -t -c "SELECT md5(string_agg(t::text, '' ORDER BY id)) FROM users t;"
psql "$TGT" -t -c "SELECT md5(string_agg(t::text, '' ORDER BY id)) FROM users t;"
```

### Run your application test suite against the target

```bash
DATABASE_URL="$TGT" ./run_tests.sh
```

---

## Step 7 — Cutover (The Minimal-Downtime Window)

This is the critical phase. The downtime is the gap between stopping writes
and switching your app to the new database.

```bash
# 1. Put app in maintenance mode / stop writes
#    (app-specific — e.g., scale down workers, enable maintenance page)

# 2. Wait for final replication catch-up
#    Re-run the lag check until lag_bytes = 0
psql "$SRC" -c "
  SELECT pg_wal_lsn_diff(pg_current_wal_lsn(), confirmed_flush_lsn) AS lag_bytes
  FROM pg_replication_slots
  WHERE slot_name LIKE 'migration_sub%';
"

# 3. Do a final row count comparison on critical tables
for table in users orders products; do
  echo "=== $table ==="
  psql "$SRC" -t -c "SELECT count(*) FROM $table;"
  psql "$TGT" -t -c "SELECT count(*) FROM $table;"
done

# 4. Reset sequences on target (logical replication does NOT replicate sequences)
psql "$SRC" -t -A -c "
  SELECT 'SELECT setval(''' || sequence_schema || '.' || sequence_name || ''', '
    || last_value || ', true);'
  FROM information_schema.sequences s
  JOIN pg_sequences ps ON s.sequence_name = ps.sequencename
  WHERE sequence_schema = 'public';
" | psql "$TGT"

# 5. Drop the subscription on target (stop replication)
psql "$TGT" -c "ALTER SUBSCRIPTION migration_sub DISABLE;"
psql "$TGT" -c "DROP SUBSCRIPTION migration_sub;"

# 6. Drop the publication on source
psql "$SRC" -c "DROP PUBLICATION migration_pub;"

# 7. Update your app's DATABASE_URL / connection string to point to $TGT
#    (DNS update, config change, secret rotation — depends on your setup)

# 8. Bring app back online
```

> **Typical downtime: 30 seconds to 5 minutes**, depending on how fast
> you can verify lag=0, reset sequences, and flip the connection.

---

## Step 8 — Post-Migration

### Refresh planner statistics

```bash
psql "$TGT" -c "ANALYZE;"
```

### Reindex (optional but recommended for fresh statistics)

```bash
psql "$TGT" -c "REINDEX DATABASE $TGT_DB;"
```

### Verify connections and performance

```bash
# Active connections
psql "$TGT" -c "SELECT count(*), state FROM pg_stat_activity GROUP BY state;"

# Slow queries (if pg_stat_statements is enabled)
psql "$TGT" -c "
  SELECT query, calls, mean_exec_time
  FROM pg_stat_statements
  ORDER BY mean_exec_time DESC LIMIT 10;
"
```

### Make source read-only as a rollback safety net

```bash
psql "$SRC" -c "ALTER DATABASE $SRC_DB SET default_transaction_read_only = on;"
```

### Clean up after rollback window (e.g., 1 week later)

```bash
# Drop the replication slot on source if it wasn't cleaned up
psql "$SRC" -c "SELECT pg_drop_replication_slot('migration_sub');"
```

---

## Quick Troubleshooting

| Problem | Check |
|---|---|
| Subscription not starting | Source firewall / security group allows target IP on port 5432 |
| `wal_level` not logical | Requires source restart after changing; some managed providers need a support ticket |
| Replication lag not decreasing | Check `max_wal_senders`, network throughput, target disk I/O |
| Permission denied on source | Replication user needs `REPLICATION` attribute + `SELECT` on published tables |
| Sequences out of sync after cutover | Re-run the sequence reset script from Step 7.4 |
| Missing data in some tables | Verify those tables are included in the publication |
| Source disk filling up during load | WAL retained by the slot is accumulating; check with `pg_replication_slots` query from Step 4c. Speed up restore or increase disk |
| Slot dropped accidentally before subscribe | Data gap is possible; restart from Step 4b and redo the dump |
| Duplicate key errors on subscriber | Slot and dump used different snapshots — writes between the two appear in both. Drop subscription, drop slot, truncate target, and redo Step 4 with slot + snapshot in the same transaction |
| FK constraint errors during parallel restore | Restore pre-data section only (Step 3), load data without indexes/FKs, then apply post-data section after (Step 5b) |
| `cannot add relation to publication` | Table is unlogged — use explicit table list instead of `FOR ALL TABLES` |
| `pg_dump` hangs on catalog queries | Source has large internal catalogs (e.g. TimescaleDB chunks) — add `--schema=public` |
| Subscription cannot resolve source hostname | Target can't reach source directly — use a TCP proxy (socat) on an intermediary machine |
| `invalid compression specification: ZSTD` | `pg_dump` build lacks zstd support — use `--compress=gzip` instead |
