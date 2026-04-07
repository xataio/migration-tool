#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# migrate.sh — Single migration tool for zero-downtime PostgreSQL migrations
#
# Usage:
#   migrate.sh <subcommand>
#
# Subcommands:
#   preflight         Check versions, tools, wal_level, connectivity
#   copy-schema       Dump schema from source, apply pre-data to target
#   dump-and-restore  Create pub+slot, snapshot dump, restore data+indexes, start subscription
#   monitor           Watch replication lag
#   verify            Compare row counts, write_log gaps, checksums, sequence values
#   cutover           Sync sequences, tear down replication cleanly
#   cleanup           Abort/reset: drop subscription, publication, slot (for failed migrations)
#
# Required env vars:  SRC, TGT (connection strings)
# Optional env vars:  MIGRATE_SLOT (default: migration_sub)
#                     MIGRATE_PUB  (default: migration_pub)
#                     MIGRATE_JOBS (default: 4)
#                     MIGRATE_WORK_DIR (default: .)
# =============================================================================

# ---------------------------------------------------------------------------
# Config defaults
# ---------------------------------------------------------------------------
SLOT_NAME="${MIGRATE_SLOT:-migration_sub}"
PUB_NAME="${MIGRATE_PUB:-migration_pub}"
WORK_DIR="${MIGRATE_WORK_DIR:-.}"
JOBS="${MIGRATE_JOBS:-4}"
SCHEMA_DIR="${WORK_DIR}/schema.dir"
DATA_DIR="${WORK_DIR}/data.dir"
# Comma-separated list of tables to exclude from data dump (schema still copied)
EXCLUDE_DATA="${MIGRATE_EXCLUDE_DATA:-}"
# Comma-separated list of tables to exclude entirely (schema + data)
EXCLUDE_TABLES="${MIGRATE_EXCLUDE_TABLES:-}"
# Comma-separated list of schemas to dump (default: all schemas)
SCHEMAS="${MIGRATE_SCHEMAS:-}"
# Connection string the target uses to reach the source (via proxy if needed)
# If not set, $SRC is used directly in CREATE SUBSCRIPTION
SRC_PROXY="${MIGRATE_SRC_PROXY:-${SRC:-}}"
# Local port for the socat proxy
PROXY_PORT="${MIGRATE_PROXY_PORT:-5432}"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
green()  { printf "\033[32m%s\033[0m\n" "$*"; }
yellow() { printf "\033[33m%s\033[0m\n" "$*"; }
red()    { printf "\033[31m%s\033[0m\n" "$*"; }
bold()   { printf "\033[1m%s\033[0m\n" "$*"; }

die() { red "ERROR: $*" >&2; exit 1; }

# Background directory size monitor. Usage:
#   start_size_monitor <dir> <label>   — starts background monitor, sets SIZE_MON_PID
#   stop_size_monitor                  — kills it
STOP_FILE=""

start_size_monitor() {
  local dir="$1" label="$2"
  STOP_FILE=$(mktemp)
  local sf="$STOP_FILE"
  (
    trap 'exit 0' TERM
    while [[ -f "$sf" ]]; do
      if [[ -d "$dir" ]]; then
        local size
        size=$(du -sh "$dir" 2>/dev/null | cut -f1)
        printf "\r\033[K  %s: %s" "$label" "$size"
      fi
      sleep 2
    done
  ) &
  SIZE_MON_PID=$!
}

stop_size_monitor() {
  if [[ -n "${SIZE_MON_PID:-}" ]]; then
    rm -f "$STOP_FILE"
    kill "$SIZE_MON_PID" 2>/dev/null || true
    wait "$SIZE_MON_PID" 2>/dev/null || true
    unset SIZE_MON_PID
    printf "\r\033[K"
  fi
}

# Background database size monitor for restore progress
start_db_size_monitor() {
  local connstr="$1" label="$2"
  STOP_FILE=$(mktemp)
  local sf="$STOP_FILE"
  (
    trap 'exit 0' TERM
    while [[ -f "$sf" ]]; do
      local size
      size=$(psql "$connstr" -t -A -c "SELECT pg_size_pretty(pg_database_size(current_database()));" 2>/dev/null)
      printf "\r\033[K  %s: %s" "$label" "$size"
      sleep 3
    done
  ) &
  SIZE_MON_PID=$!
}

# Convert glob patterns (with *) to regex patterns (with .*)
glob_to_regex() {
  echo "$1" | sed 's/\*/\.\*/g'
}

require_env() {
  local var="$1"
  if [[ -z "${!var:-}" ]]; then
    die "Required environment variable $var is not set"
  fi
}

require_cmd() {
  local cmd="$1"
  if ! command -v "$cmd" &>/dev/null; then
    die "Required command '$cmd' not found in PATH"
  fi
}

# ---------------------------------------------------------------------------
# preflight
# ---------------------------------------------------------------------------
do_preflight() {
  require_env SRC
  require_env TGT

  bold "=== Preflight Checks ==="
  echo ""

  green "[1/7] Checking required tools..."
  for cmd in psql pg_dump pg_restore python3; do
    require_cmd "$cmd"
    echo "  OK  $cmd ($(command -v "$cmd"))"
  done
  echo ""

  green "[2/7] PostgreSQL versions..."
  SRC_VERSION=$(psql "$SRC" -t -A -c "SHOW server_version_num;")
  TGT_VERSION=$(psql "$TGT" -t -A -c "SHOW server_version_num;")
  PGDUMP_VERSION=$(pg_dump --version | grep -oE '[0-9]+\.[0-9]+' | head -1)
  PGDUMP_MAJOR=$(echo "$PGDUMP_VERSION" | cut -d. -f1)
  SRC_MAJOR=$((SRC_VERSION / 10000))
  echo "  Source:  $(psql "$SRC" -t -A -c "SELECT version();")"
  echo "  Target:  $(psql "$TGT" -t -A -c "SELECT version();")"
  echo "  pg_dump: $PGDUMP_VERSION"
  if [[ "$PGDUMP_MAJOR" -lt "$SRC_MAJOR" ]]; then
    die "pg_dump major version ($PGDUMP_MAJOR) is older than source server ($SRC_MAJOR). Install postgresql$SRC_MAJOR client tools."
  fi
  echo ""

  green "[3/7] Checking wal_level on source..."
  WAL_LEVEL=$(psql "$SRC" -t -A -c "SHOW wal_level;")
  if [[ "$WAL_LEVEL" != "logical" ]]; then
    die "wal_level is '$WAL_LEVEL' on source — must be 'logical'. Change it and restart the source."
  fi
  echo "  OK  wal_level = $WAL_LEVEL"
  echo ""

  green "[4/7] Checking replication settings on source..."
  MAX_SLOTS=$(psql "$SRC" -t -A -c "SHOW max_replication_slots;")
  MAX_SENDERS=$(psql "$SRC" -t -A -c "SHOW max_wal_senders;")
  if [[ "$MAX_SLOTS" -lt 1 ]]; then
    yellow "  WARN  max_replication_slots = $MAX_SLOTS (need >= 1)"
  else
    echo "  OK  max_replication_slots = $MAX_SLOTS"
  fi
  if [[ "$MAX_SENDERS" -lt 1 ]]; then
    yellow "  WARN  max_wal_senders = $MAX_SENDERS (need >= 1)"
  else
    echo "  OK  max_wal_senders = $MAX_SENDERS"
  fi
  echo ""

  green "[5/7] Extensions on source..."
  psql "$SRC" -c "SELECT extname, extversion FROM pg_extension ORDER BY extname;"
  echo ""

  green "[6/7] Database size..."
  psql "$SRC" -c "SELECT pg_size_pretty(pg_database_size(current_database())) AS source_db_size;"
  echo ""

  green "[7/7] Checking for existing slot/publication..."
  EXISTING_SLOT=$(psql "$SRC" -t -A -c "SELECT count(*) FROM pg_replication_slots WHERE slot_name = '$SLOT_NAME';")
  EXISTING_PUB=$(psql "$SRC" -t -A -c "SELECT count(*) FROM pg_publication WHERE pubname = '$PUB_NAME';")
  if [[ "$EXISTING_SLOT" -gt 0 ]]; then
    yellow "  WARN  Replication slot '$SLOT_NAME' already exists on source"
  else
    echo "  OK  No existing slot '$SLOT_NAME'"
  fi
  if [[ "$EXISTING_PUB" -gt 0 ]]; then
    yellow "  WARN  Publication '$PUB_NAME' already exists on source"
  else
    echo "  OK  No existing publication '$PUB_NAME'"
  fi

  echo ""
  bold "=== Preflight complete ==="
}

# ---------------------------------------------------------------------------
# copy-schema
# ---------------------------------------------------------------------------
do_copy_schema() {
  require_env SRC
  require_env TGT

  bold "=== Copy Schema ==="
  echo ""

  if [[ -d "$SCHEMA_DIR" ]]; then
    yellow "Removing existing $SCHEMA_DIR..."
    rm -rf "$SCHEMA_DIR"
  fi

  # Build --exclude-table flags
  SCHEMA_EXCLUDE_FLAGS=()
  if [[ -n "$EXCLUDE_TABLES" ]]; then
    IFS=',' read -ra EXCL_TBL_LIST <<< "$EXCLUDE_TABLES"
    for tbl in "${EXCL_TBL_LIST[@]}"; do
      tbl=$(echo "$tbl" | xargs)
      SCHEMA_EXCLUDE_FLAGS+=(--exclude-table="$tbl")
    done
    yellow "Excluding tables entirely: ${EXCL_TBL_LIST[*]}"
  fi

  # Build --schema flags
  if [[ -n "$SCHEMAS" ]]; then
    IFS=',' read -ra SCHEMA_LIST <<< "$SCHEMAS"
    for s in "${SCHEMA_LIST[@]}"; do
      SCHEMA_EXCLUDE_FLAGS+=(--schema="$(echo "$s" | xargs)")
    done
    yellow "Limiting to schemas: $SCHEMAS"
  fi

  green "[1/4] Dumping schema from source..."
  pg_dump "$SRC" \
    --schema-only \
    --no-owner \
    --no-privileges \
    --format=directory \
    ${SCHEMA_EXCLUDE_FLAGS[@]+"${SCHEMA_EXCLUDE_FLAGS[@]}"} \
    --file="$SCHEMA_DIR"
  echo "  Saved to $SCHEMA_DIR"
  echo ""

  green "[2/4] Creating extensions on target..."
  psql "$SRC" -t -A -c "SELECT extname FROM pg_extension WHERE extname != 'plpgsql' ORDER BY extname;" | while read -r ext; do
    if [[ -n "$ext" ]]; then
      echo "  Creating extension: $ext"
      psql "$TGT" -c "CREATE EXTENSION IF NOT EXISTS \"$ext\";" 2>&1 || yellow "  WARN  Could not create extension '$ext'"
    fi
  done
  echo ""

  green "[3/4] Restoring pre-data section to target..."
  pg_restore \
    --dbname="$TGT" \
    --no-owner \
    --no-privileges \
    --section=pre-data \
    "$SCHEMA_DIR" 2>&1 | tee "${WORK_DIR}/schema_import.log"
  echo ""

  green "[4/4] Verifying table counts..."
  SRC_TABLES=$(psql "$SRC" -t -A -c "SELECT count(*) FROM pg_tables WHERE schemaname NOT IN ('pg_catalog','information_schema');")
  TGT_TABLES=$(psql "$TGT" -t -A -c "SELECT count(*) FROM pg_tables WHERE schemaname NOT IN ('pg_catalog','information_schema');")
  if [[ "$SRC_TABLES" == "$TGT_TABLES" ]]; then
    green "  OK  Table count matches: $SRC_TABLES tables"
  else
    red "  MISMATCH  Source has $SRC_TABLES tables, target has $TGT_TABLES tables"
  fi

  echo ""
  bold "=== Schema copy complete ==="
}

# ---------------------------------------------------------------------------
# verify-schema
# ---------------------------------------------------------------------------
do_verify_schema() {
  require_env SRC
  require_env TGT

  bold "=== Schema Verification ==="
  echo ""

  # Build exclusion list for filtering
  local -a EXCLUDED=()
  if [[ -n "$EXCLUDE_TABLES" ]]; then
    IFS=',' read -ra _tmp <<< "$EXCLUDE_TABLES"
    for tbl in "${_tmp[@]}"; do EXCLUDED+=("$(echo "$tbl" | xargs)"); done
  fi

  green "[1/5] Comparing table lists..."
  SRC_TBLS=$(psql "$SRC" -t -A -c "
    SELECT tablename FROM pg_tables
    WHERE schemaname = 'public' ORDER BY tablename;
  ")
  TGT_TBLS=$(psql "$TGT" -t -A -c "
    SELECT tablename FROM pg_tables
    WHERE schemaname = 'public' ORDER BY tablename;
  ")

  # Filter out excluded tables from source list
  if [[ ${#EXCLUDED[@]} -gt 0 ]]; then
    EXCLUDE_PATTERN=$(IFS='|'; echo "${EXCLUDED[*]}" | sed 's/\*/\.\*/g')
    SRC_TBLS=$(echo "$SRC_TBLS" | grep -vE "^($EXCLUDE_PATTERN)$" || true)
  fi

  MISSING_ON_TGT=$(comm -23 <(echo "$SRC_TBLS" | sort) <(echo "$TGT_TBLS" | sort))
  EXTRA_ON_TGT=$(comm -13 <(echo "$SRC_TBLS" | sort) <(echo "$TGT_TBLS" | sort))

  if [[ -z "$MISSING_ON_TGT" ]]; then
    green "  OK  All source tables exist on target"
  else
    red "  MISSING on target:"
    echo "$MISSING_ON_TGT" | while read -r t; do
      [[ -n "$t" ]] && red "    $t"
    done
  fi
  if [[ -n "$EXTRA_ON_TGT" ]]; then
    yellow "  Extra on target (not on source):"
    echo "$EXTRA_ON_TGT" | while read -r t; do
      [[ -n "$t" ]] && yellow "    $t"
    done
  fi
  echo ""

  green "[2/5] Comparing column counts per table..."
  local col_ok=0 col_mismatch=0
  echo "$SRC_TBLS" | while read -r tbl; do
    [[ -z "$tbl" ]] && continue
    src_cols=$(psql "$SRC" -t -A -c "
      SELECT count(*) FROM information_schema.columns
      WHERE table_schema = 'public' AND table_name = '$tbl';
    " 2>/dev/null || echo "N/A")
    tgt_cols=$(psql "$TGT" -t -A -c "
      SELECT count(*) FROM information_schema.columns
      WHERE table_schema = 'public' AND table_name = '$tbl';
    " 2>/dev/null || echo "0")
    if [[ "$src_cols" == "$tgt_cols" ]]; then
      : # silent OK
    else
      red "  MISMATCH $tbl: source=$src_cols cols, target=$tgt_cols cols"
      col_mismatch=1
    fi
  done
  if [[ "${col_mismatch:-0}" -eq 0 ]]; then
    green "  OK  All tables have matching column counts"
  fi
  echo ""

  green "[3/5] Comparing indexes..."
  yellow "  (Note: indexes are created during dump-and-restore post-data step, not copy-schema)"
  SRC_IDX=$(psql "$SRC" -t -A -c "
    SELECT count(*) FROM pg_indexes WHERE schemaname = 'public';
  ")
  TGT_IDX=$(psql "$TGT" -t -A -c "
    SELECT count(*) FROM pg_indexes WHERE schemaname = 'public';
  ")
  echo "  Source: $SRC_IDX indexes"
  echo "  Target: $TGT_IDX indexes"
  if [[ "$SRC_IDX" == "$TGT_IDX" ]]; then
    green "  OK  Index counts match"
  else
    yellow "  DIFFER  (may include excluded table indexes)"
    # Show missing indexes
    MISSING_IDX=$(comm -23 \
      <(psql "$SRC" -t -A -c "SELECT tablename || '.' || indexname FROM pg_indexes WHERE schemaname = 'public' ORDER BY 1;") \
      <(psql "$TGT" -t -A -c "SELECT tablename || '.' || indexname FROM pg_indexes WHERE schemaname = 'public' ORDER BY 1;"))
    if [[ -n "$MISSING_IDX" ]]; then
      echo "  Missing on target:"
      echo "$MISSING_IDX" | head -20 | while read -r idx; do
        yellow "    $idx"
      done
      TOTAL_MISSING=$(echo "$MISSING_IDX" | wc -l | tr -d ' ')
      if [[ "$TOTAL_MISSING" -gt 20 ]]; then
        yellow "    ... and $((TOTAL_MISSING - 20)) more"
      fi
    fi
  fi
  echo ""

  green "[4/5] Comparing sequences..."
  SRC_SEQS=$(psql "$SRC" -t -A -c "
    SELECT sequencename FROM pg_sequences WHERE schemaname = 'public' ORDER BY sequencename;
  ")
  TGT_SEQS=$(psql "$TGT" -t -A -c "
    SELECT sequencename FROM pg_sequences WHERE schemaname = 'public' ORDER BY sequencename;
  ")
  MISSING_SEQS=$(comm -23 <(echo "$SRC_SEQS" | sort) <(echo "$TGT_SEQS" | sort))
  if [[ -z "$MISSING_SEQS" ]]; then
    green "  OK  All source sequences exist on target"
  else
    red "  MISSING on target:"
    echo "$MISSING_SEQS" | while read -r s; do
      [[ -n "$s" ]] && red "    $s"
    done
  fi
  echo ""

  green "[5/5] Comparing foreign keys..."
  yellow "  (Note: FKs are created during dump-and-restore post-data step, not copy-schema)"
  SRC_FKS=$(psql "$SRC" -t -A -c "
    SELECT count(*) FROM pg_constraint
    WHERE contype = 'f' AND connamespace = 'public'::regnamespace;
  ")
  TGT_FKS=$(psql "$TGT" -t -A -c "
    SELECT count(*) FROM pg_constraint
    WHERE contype = 'f' AND connamespace = 'public'::regnamespace;
  ")
  echo "  Source: $SRC_FKS foreign keys"
  echo "  Target: $TGT_FKS foreign keys"
  if [[ "$SRC_FKS" == "$TGT_FKS" ]]; then
    green "  OK  FK counts match"
  else
    yellow "  DIFFER  (may include excluded table FKs)"
  fi

  echo ""
  bold "=== Schema verification complete ==="
}

# ---------------------------------------------------------------------------
# dump-and-restore
# ---------------------------------------------------------------------------
do_dump_and_restore() {
  require_env SRC
  require_env TGT

  bold "=== Dump and Restore ==="
  echo ""

  # Prerequisite check
  if [[ ! -d "$SCHEMA_DIR" ]]; then
    die "$SCHEMA_DIR not found. Run 'copy-schema' first."
  fi

  # Build exclude flags for pg_dump
  DUMP_EXCLUDE_FLAGS=()

  # Tables excluded from data only (schema still copied)
  if [[ -n "$EXCLUDE_DATA" ]]; then
    IFS=',' read -ra EXCL_DATA_LIST <<< "$EXCLUDE_DATA"
    green "Excluding data for tables: ${EXCL_DATA_LIST[*]}"
    for tbl in "${EXCL_DATA_LIST[@]}"; do
      tbl=$(echo "$tbl" | xargs)
      FK_REFS=$(psql "$SRC" -t -A -c "
        SELECT conrelid::regclass || '.' || conname
        FROM pg_constraint
        WHERE confrelid = '\"$tbl\"'::regclass AND contype = 'f';
      " 2>/dev/null || true)
      if [[ -n "$FK_REFS" ]]; then
        die "Cannot exclude '$tbl' — referenced by foreign keys: $FK_REFS"
      fi
      DUMP_EXCLUDE_FLAGS+=(--exclude-table-data="$tbl")
    done
    echo ""
  fi

  # Tables excluded entirely (already excluded from schema dump)
  if [[ -n "$EXCLUDE_TABLES" ]]; then
    IFS=',' read -ra EXCL_TBL_LIST <<< "$EXCLUDE_TABLES"
    green "Excluding tables entirely: ${EXCL_TBL_LIST[*]}"
    for tbl in "${EXCL_TBL_LIST[@]}"; do
      tbl=$(echo "$tbl" | xargs)
      DUMP_EXCLUDE_FLAGS+=(--exclude-table="$tbl")
    done
    echo ""
  fi

  # Combine both exclusion lists for publication
  ALL_EXCLUDED=()
  if [[ -n "$EXCLUDE_DATA" ]]; then
    IFS=',' read -ra _tmp <<< "$EXCLUDE_DATA"
    for tbl in "${_tmp[@]}"; do ALL_EXCLUDED+=("$(echo "$tbl" | xargs)"); done
  fi
  if [[ -n "$EXCLUDE_TABLES" ]]; then
    IFS=',' read -ra _tmp <<< "$EXCLUDE_TABLES"
    for tbl in "${_tmp[@]}"; do ALL_EXCLUDED+=("$(echo "$tbl" | xargs)"); done
  fi

  # Check for stale slot and drop it
  EXISTING_SLOT=$(psql "$SRC" -t -A -c "SELECT count(*) FROM pg_replication_slots WHERE slot_name = '$SLOT_NAME';")
  if [[ "$EXISTING_SLOT" -gt 0 ]]; then
    yellow "Stale replication slot '$SLOT_NAME' found — dropping it..."
    psql "$SRC" -c "SELECT pg_drop_replication_slot('$SLOT_NAME');"
  fi

  # Check for stale publication and drop it
  EXISTING_PUB=$(psql "$SRC" -t -A -c "SELECT count(*) FROM pg_publication WHERE pubname = '$PUB_NAME';")
  if [[ "$EXISTING_PUB" -gt 0 ]]; then
    yellow "Stale publication '$PUB_NAME' found — dropping it..."
    psql "$SRC" -c "DROP PUBLICATION $PUB_NAME;"
  fi

  green "[1/5] Creating publication on source..."
  # Always use explicit table list to exclude unlogged tables (can't replicate)
  EXCLUDE_PATTERN=""
  if [[ ${#ALL_EXCLUDED[@]} -gt 0 ]]; then
    EXCLUDE_PATTERN=$(IFS='|'; echo "${ALL_EXCLUDED[*]}" | sed 's/\*/\.\*/g')
  fi
  PUB_TABLES=$(psql "$SRC" -t -A -c "
    SELECT string_agg(quote_ident(c.relname), ', ')
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public'
      AND c.relkind = 'r'
      AND c.relpersistence = 'p'
      $([ -n "$EXCLUDE_PATTERN" ] && echo "AND c.relname !~ '^($EXCLUDE_PATTERN)$'")
    ;
  ")
  if [[ -z "$PUB_TABLES" ]]; then
    die "No tables left after exclusions"
  fi
  # Check for skipped unlogged tables
  UNLOGGED=$(psql "$SRC" -t -A -c "
    SELECT string_agg(c.relname, ', ')
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public' AND c.relkind = 'r' AND c.relpersistence = 'u';
  ")
  if [[ -n "$UNLOGGED" ]]; then
    yellow "Skipping unlogged tables (cannot replicate): $UNLOGGED"
  fi
  if [[ ${#ALL_EXCLUDED[@]} -gt 0 ]]; then
    yellow "Excluding: ${ALL_EXCLUDED[*]}"
  fi
  psql "$SRC" -c "CREATE PUBLICATION $PUB_NAME FOR TABLE $PUB_TABLES;"
  echo ""

  green "[2/5] Creating replication slot + snapshot dump..."
  SNAPSHOT_FILE=$(mktemp)
  READY_FILE=$(mktemp)
  rm -f "$SNAPSHOT_FILE" "$READY_FILE"

  snapshot_cleanup() {
    rm -f "$SNAPSHOT_FILE" "$READY_FILE"
    if [[ -n "${HOLDER_PID:-}" ]]; then
      kill "$HOLDER_PID" 2>/dev/null || true
      wait "$HOLDER_PID" 2>/dev/null || true
    fi
  }
  trap snapshot_cleanup EXIT

  # Background Python process to hold transaction open
  python3 -c "
import subprocess, os, sys, time, signal

conn = os.environ['SRC']
slot = '$SLOT_NAME'
snapshot_file = '$SNAPSHOT_FILE'
ready_file = '$READY_FILE'

proc = subprocess.Popen(
    ['psql', conn, '-t', '-A', '-q'],
    stdin=subprocess.PIPE,
    stdout=subprocess.PIPE,
    stderr=subprocess.PIPE,
    text=True
)

commands = '''
BEGIN TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY;
SELECT pg_create_logical_replication_slot('{slot}', 'pgoutput');
SELECT pg_export_snapshot();
'''.format(slot=slot)

proc.stdin.write(commands)
proc.stdin.flush()

lines = []
for i in range(2):
    line = proc.stdout.readline().strip()
    lines.append(line)

snapshot_id = lines[1]
print(f'Snapshot ID: {snapshot_id}')

with open(snapshot_file, 'w') as f:
    f.write(snapshot_id)

with open(ready_file, 'w') as f:
    f.write('ready')

print('Holding transaction open... waiting for dump to finish.')

def handle_signal(signum, frame):
    pass

signal.signal(signal.SIGUSR1, handle_signal)

while os.path.exists(ready_file):
    time.sleep(0.5)

print('Dump complete, closing transaction.')
proc.stdin.write('COMMIT;\n')
proc.stdin.close()
proc.wait()
" &

  HOLDER_PID=$!

  # Wait for snapshot to be ready
  echo "  Waiting for snapshot..."
  for i in $(seq 1 60); do
    if [[ -f "$READY_FILE" ]] && [[ -f "$SNAPSHOT_FILE" ]]; then
      break
    fi
    sleep 1
  done

  if [[ ! -f "$SNAPSHOT_FILE" ]]; then
    die "Timed out waiting for snapshot"
  fi

  SNAPSHOT_ID=$(cat "$SNAPSHOT_FILE")
  echo "  Snapshot ID: $SNAPSHOT_ID"

  if [[ -d "$DATA_DIR" ]]; then
    yellow "  Removing existing $DATA_DIR..."
    rm -rf "$DATA_DIR"
  fi

  echo "  Running pg_dump..."
  start_size_monitor "$DATA_DIR" "Dumping"
  # Build schema flags
  SCHEMA_FILTER_FLAGS=()
  if [[ -n "$SCHEMAS" ]]; then
    IFS=',' read -ra SCHEMA_LIST <<< "$SCHEMAS"
    for s in "${SCHEMA_LIST[@]}"; do
      SCHEMA_FILTER_FLAGS+=(--schema="$(echo "$s" | xargs)")
    done
  fi

  pg_dump "$SRC" \
    ${SCHEMA_FILTER_FLAGS[@]+"${SCHEMA_FILTER_FLAGS[@]}"} \
    --data-only \
    --format=directory \
    --compress=gzip \
    --snapshot="$SNAPSHOT_ID" \
    ${DUMP_EXCLUDE_FLAGS[@]+"${DUMP_EXCLUDE_FLAGS[@]}"} \
    --file="$DATA_DIR"
  stop_size_monitor

  echo "  Dump complete: $(du -sh "$DATA_DIR" | cut -f1)"

  # Signal holder to close transaction
  rm -f "$READY_FILE"
  wait "$HOLDER_PID" 2>/dev/null || true
  unset HOLDER_PID
  echo ""

  green "[3/5] Restoring data to target..."
  start_db_size_monitor "$TGT" "Restoring data — target DB size"
  pg_restore \
    --dbname="$TGT" \
    --data-only \
    --no-owner \
    --no-privileges \
    --jobs="$JOBS" \
    "$DATA_DIR" 2>&1 | tee "${WORK_DIR}/restore.log" || true
  stop_size_monitor
  echo ""

  green "[4/5] Building indexes and foreign keys (post-data)..."
  start_db_size_monitor "$TGT" "Building indexes — target DB size"
  pg_restore \
    --dbname="$TGT" \
    --no-owner \
    --no-privileges \
    --jobs="$JOBS" \
    --section=post-data \
    "$SCHEMA_DIR" 2>&1 | tee "${WORK_DIR}/postdata.log" || true
  stop_size_monitor
  echo ""

  green "[5/5] Creating subscription on target..."
  psql "$TGT" -c "
    CREATE SUBSCRIPTION $SLOT_NAME
      CONNECTION '$SRC_PROXY'
      PUBLICATION $PUB_NAME
      WITH (
        copy_data = false,
        create_slot = false,
        slot_name = '$SLOT_NAME'
      );
  "
  echo ""

  green "Checking initial replication status..."
  psql "$SRC" -c "
    SELECT slot_name, active, restart_lsn,
           pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), confirmed_flush_lsn)) AS lag
    FROM pg_replication_slots
    WHERE slot_name = '$SLOT_NAME';
  "
  psql "$TGT" -c "
    SELECT subname, subenabled,
           (SELECT count(*) FROM pg_stat_subscription WHERE subname = '$SLOT_NAME' AND last_msg_send_time IS NOT NULL) AS active_workers
    FROM pg_subscription
    WHERE subname = '$SLOT_NAME';
  "

  # Reset the trap
  trap - EXIT
  rm -f "$SNAPSHOT_FILE" "$READY_FILE"

  echo ""
  bold "=== Dump and restore complete. Replication is running. ==="
}

# ---------------------------------------------------------------------------
# monitor
# ---------------------------------------------------------------------------
do_monitor() {
  require_env SRC

  local INTERVAL="${MIGRATE_MONITOR_INTERVAL:-5}"

  bold "=== Replication Monitor (every ${INTERVAL}s) ==="
  yellow "Press Ctrl+C to stop."
  echo ""

  while true; do
    echo "--- $(date -u +%Y-%m-%dT%H:%M:%SZ) ---"

    psql "$SRC" -c "
      SELECT
        slot_name,
        active,
        confirmed_flush_lsn,
        pg_current_wal_lsn() AS current_wal_lsn,
        pg_wal_lsn_diff(pg_current_wal_lsn(), confirmed_flush_lsn) AS lag_bytes,
        pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), confirmed_flush_lsn)) AS lag_pretty
      FROM pg_replication_slots
      WHERE slot_name = '$SLOT_NAME';
    "

    if [[ -n "${TGT:-}" ]]; then
      psql "$TGT" -c "
        SELECT
          subname,
          pid,
          received_lsn,
          latest_end_lsn,
          latest_end_time
        FROM pg_stat_subscription
        WHERE subname = '$SLOT_NAME';
      " 2>/dev/null || true
    fi

    sleep "$INTERVAL"
  done
}

# ---------------------------------------------------------------------------
# verify
# ---------------------------------------------------------------------------
do_verify() {
  require_env SRC
  require_env TGT

  bold "=== Verification ==="
  echo ""

  green "[1/5] Comparing row counts..."
  echo ""
  psql "$SRC" -t -A -c "
    SELECT tablename FROM pg_tables
    WHERE schemaname = 'public' ORDER BY tablename;
  " | while read -r table; do
    if [[ -z "$table" ]]; then continue; fi
    src=$(psql "$SRC" -t -A -c "SELECT count(*) FROM \"$table\";" 2>/dev/null || echo "N/A")
    tgt=$(psql "$TGT" -t -A -c "SELECT count(*) FROM \"$table\";" 2>/dev/null || echo "N/A")
    if [[ "$src" == "$tgt" ]]; then
      echo "  OK       $table: $src rows"
    else
      red "  MISMATCH $table: source=$src target=$tgt"
    fi
  done
  echo ""

  green "[2/5] Checking write_log for sequence gaps..."
  echo ""
  HAS_WRITE_LOG=$(psql "$TGT" -t -A -c "SELECT count(*) FROM pg_tables WHERE schemaname='public' AND tablename='write_log';")
  if [[ "$HAS_WRITE_LOG" == "1" ]]; then
    GAP_COUNT=$(psql "$TGT" -t -A -c "
      WITH seq AS (
        SELECT id, lead(id) OVER (ORDER BY id) AS next_id FROM write_log
      )
      SELECT count(*) FROM seq WHERE next_id - id > 1;
    ")
    if [[ "$GAP_COUNT" == "0" ]]; then
      green "  No gaps detected in write_log sequence."
    else
      red "  Found $GAP_COUNT gaps in write_log sequence!"
      psql "$TGT" -c "
        WITH seq AS (
          SELECT id, lead(id) OVER (ORDER BY id) AS next_id FROM write_log
        )
        SELECT id AS gap_after, next_id AS gap_before, next_id - id - 1 AS missing_count
        FROM seq WHERE next_id - id > 1 ORDER BY id LIMIT 20;
      "
    fi
  else
    yellow "  write_log table not found — skipping gap detection."
  fi
  echo ""

  green "[3/5] Spot-checking MD5 checksums (first 1000 rows per table)..."
  echo ""
  psql "$SRC" -t -A -c "
    SELECT tablename FROM pg_tables
    WHERE schemaname = 'public' ORDER BY tablename;
  " | while read -r table; do
    if [[ -z "$table" ]]; then continue; fi
    SRC_MD5=$(psql "$SRC" -t -A -c "
      SELECT md5(string_agg(t::text, '' ORDER BY id))
      FROM (SELECT * FROM \"$table\" ORDER BY id LIMIT 1000) t;
    " 2>/dev/null || echo "N/A")
    TGT_MD5=$(psql "$TGT" -t -A -c "
      SELECT md5(string_agg(t::text, '' ORDER BY id))
      FROM (SELECT * FROM \"$table\" ORDER BY id LIMIT 1000) t;
    " 2>/dev/null || echo "N/A")
    if [[ "$SRC_MD5" == "$TGT_MD5" ]]; then
      echo "  OK       $table: $SRC_MD5"
    else
      red "  MISMATCH $table: source=$SRC_MD5 target=$TGT_MD5"
    fi
  done
  echo ""

  green "[4/5] Current replication lag..."
  echo ""
  psql "$SRC" -c "
    SELECT
      slot_name,
      active,
      pg_wal_lsn_diff(pg_current_wal_lsn(), confirmed_flush_lsn) AS lag_bytes,
      pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), confirmed_flush_lsn)) AS lag_pretty
    FROM pg_replication_slots
    WHERE slot_name = '$SLOT_NAME';
  " 2>/dev/null || yellow "  Could not check replication lag (slot may not exist)."
  echo ""

  green "[5/5] Sequence comparison..."
  echo ""
  psql "$SRC" -t -A -c "
    SELECT sequencename FROM pg_sequences WHERE schemaname = 'public' ORDER BY sequencename;
  " | while read -r seq; do
    if [[ -z "$seq" ]]; then continue; fi
    src_val=$(psql "$SRC" -t -A -c "SELECT last_value FROM pg_sequences WHERE sequencename = '$seq';" 2>/dev/null || echo "N/A")
    tgt_val=$(psql "$TGT" -t -A -c "SELECT last_value FROM pg_sequences WHERE sequencename = '$seq';" 2>/dev/null || echo "N/A")
    if [[ "$src_val" == "$tgt_val" ]]; then
      echo "  OK       $seq: $src_val"
    else
      yellow "  DIFFER   $seq: source=$src_val target=$tgt_val"
    fi
  done

  echo ""
  bold "=== Verification complete ==="
}

# ---------------------------------------------------------------------------
# cutover
# ---------------------------------------------------------------------------
do_cutover() {
  require_env SRC
  require_env TGT

  bold "=== Cutover ==="
  echo ""

  green "[1/4] Checking replication lag..."
  LAG=$(psql "$SRC" -t -A -c "
    SELECT pg_wal_lsn_diff(pg_current_wal_lsn(), confirmed_flush_lsn)
    FROM pg_replication_slots
    WHERE slot_name = '$SLOT_NAME';
  ")
  if [[ "$LAG" != "0" ]]; then
    yellow "WARNING: Replication lag is $LAG bytes (not zero)."
    echo ""
    read -r -p "Proceed anyway? (y/N) " REPLY
    if [[ "$REPLY" != "y" && "$REPLY" != "Y" ]]; then
      die "Aborted — wait for lag to reach 0 before cutover."
    fi
  else
    green "  Lag is 0 — safe to proceed."
  fi
  echo ""

  green "[2/4] Syncing sequences from source to target..."
  psql "$SRC" -t -A -c "
    SELECT 'SELECT setval(''' || quote_ident(sequence_schema) || '.' || quote_ident(sequence_name) || ''', '
      || last_value || ', true);'
    FROM information_schema.sequences s
    JOIN pg_sequences ps ON s.sequence_name = ps.sequencename
    WHERE sequence_schema = 'public';
  " | psql "$TGT"
  green "  Sequences synced."
  echo ""

  green "[3/4] Disabling and dropping subscription..."
  psql "$TGT" -c "ALTER SUBSCRIPTION $SLOT_NAME DISABLE;"
  psql "$TGT" -c "DROP SUBSCRIPTION $SLOT_NAME;"
  green "  Subscription dropped."
  echo ""

  green "[4/4] Dropping publication on source..."
  psql "$SRC" -c "DROP PUBLICATION $PUB_NAME;"
  green "  Publication dropped."

  echo ""
  bold "=== Cutover complete ==="
  green "Update your application's connection string to point to the target database."
}

# ---------------------------------------------------------------------------
# check-fks
# ---------------------------------------------------------------------------
do_check_fks() {
  require_env SRC

  bold "=== FK Check for Excluded Tables ==="
  echo ""

  if [[ -z "$EXCLUDE_DATA" && -z "$EXCLUDE_TABLES" ]]; then
    yellow "MIGRATE_EXCLUDE_DATA and MIGRATE_EXCLUDE_TABLES are not set — nothing to check."
    return
  fi

  # Combine both lists
  local -a CHECK_TABLES=()
  if [[ -n "$EXCLUDE_DATA" ]]; then
    IFS=',' read -ra _tmp <<< "$EXCLUDE_DATA"
    CHECK_TABLES+=("${_tmp[@]}")
  fi
  if [[ -n "$EXCLUDE_TABLES" ]]; then
    IFS=',' read -ra _tmp <<< "$EXCLUDE_TABLES"
    CHECK_TABLES+=("${_tmp[@]}")
  fi
  local has_errors=0

  for tbl in "${CHECK_TABLES[@]}"; do
    tbl=$(echo "$tbl" | xargs)
    green "Checking '$tbl'..."

    # Check table exists
    EXISTS=$(psql "$SRC" -t -A -c "
      SELECT count(*) FROM pg_tables
      WHERE schemaname = 'public' AND tablename = '$tbl';
    ")
    if [[ "$EXISTS" == "0" ]]; then
      red "  Table '$tbl' does not exist on source"
      has_errors=1
      continue
    fi

    # FKs pointing TO this table (other tables depend on it)
    REFS=$(psql "$SRC" -t -A -c "
      SELECT conrelid::regclass || ' -> ' || conname
      FROM pg_constraint
      WHERE confrelid = '\"$tbl\"'::regclass AND contype = 'f';
    " 2>/dev/null || true)
    if [[ -n "$REFS" ]]; then
      red "  BLOCKED — other tables reference '$tbl':"
      echo "$REFS" | while read -r ref; do
        red "    $ref"
      done
      has_errors=1
    else
      echo "  OK  No FKs reference '$tbl'"
    fi

    # FKs FROM this table (it depends on others — informational)
    DEPS=$(psql "$SRC" -t -A -c "
      SELECT confrelid::regclass || ' <- ' || conname
      FROM pg_constraint
      WHERE conrelid = '\"$tbl\"'::regclass AND contype = 'f';
    " 2>/dev/null || true)
    if [[ -n "$DEPS" ]]; then
      yellow "  INFO — '$tbl' has FKs to other tables (OK to exclude):"
      echo "$DEPS" | while read -r dep; do
        yellow "    $dep"
      done
    fi

    # Show row count for context
    ROW_COUNT=$(psql "$SRC" -t -A -c "SELECT count(*) FROM \"$tbl\";")
    echo "  Rows: $ROW_COUNT"
    echo ""
  done

  if [[ "$has_errors" -gt 0 ]]; then
    echo ""
    die "Cannot exclude tables with incoming FK references. Remove them from MIGRATE_EXCLUDE_DATA or drop the FKs first."
  fi

  bold "=== All excluded tables are safe to skip ==="
}

# ---------------------------------------------------------------------------
# proxy
# ---------------------------------------------------------------------------
do_proxy() {
  require_env SRC
  require_cmd socat

  # Parse host and port from SRC connection string
  # Handles: postgresql://user:pass@host:port/dbname?params
  SRC_HOST=$(echo "$SRC" | sed -E 's|.*@([^:/]+).*|\1|')
  SRC_PORT=$(echo "$SRC" | sed -E 's|.*:([0-9]+)/.*|\1|')
  SRC_PORT="${SRC_PORT:-5432}"

  bold "=== TCP Proxy (socat) ==="
  echo ""
  echo "  Listening on:  0.0.0.0:$PROXY_PORT"
  echo "  Forwarding to: $SRC_HOST:$SRC_PORT"
  echo ""

  # Test connectivity to source first
  green "Testing connectivity to $SRC_HOST:$SRC_PORT..."
  if socat -T2 - "TCP:$SRC_HOST:$SRC_PORT" </dev/null 2>/dev/null; then
    green "  OK  Connection successful"
  else
    # socat returns non-zero even on successful connect then close, try psql
    if psql "$SRC" -c "SELECT 1;" &>/dev/null; then
      green "  OK  Connection successful (via psql)"
    else
      die "Cannot connect to $SRC_HOST:$SRC_PORT"
    fi
  fi
  echo ""

  local MY_IP
  MY_IP=$(curl -s --max-time 5 http://checkip.amazonaws.com 2>/dev/null || echo "<this machine's public IP>")
  green "Set this on the migration runner before dump-and-restore:"
  echo ""
  bold "  export MIGRATE_SRC_PROXY='postgresql://$(echo "$SRC" | sed -E "s|.*://([^@]+)@.*|\1|")@${MY_IP}:${PROXY_PORT}/$(echo "$SRC" | sed -E "s|.*/([^?]+).*|\1|")$(echo "$SRC" | grep -oE '\?.*' || true)'"
  echo ""
  yellow "Press Ctrl+C to stop the proxy."
  echo ""

  # Run socat - fork for each connection
  socat TCP-LISTEN:${PROXY_PORT},fork,reuseaddr TCP:${SRC_HOST}:${SRC_PORT}
}

# ---------------------------------------------------------------------------
# proxy-test
# ---------------------------------------------------------------------------
do_proxy_test() {
  bold "=== Proxy Test ==="
  echo ""

  if [[ -z "${SRC_PROXY:-}" ]] || [[ "$SRC_PROXY" == "$SRC" ]]; then
    die "MIGRATE_SRC_PROXY is not set (or same as SRC). Set it to the proxy connection string first."
  fi

  require_env TGT

  green "[1/3] Testing proxy connection locally..."
  echo "  SRC_PROXY: $SRC_PROXY"
  echo ""

  RESULT=$(psql "$SRC_PROXY" -t -A -c "SELECT 'proxy_ok';" 2>&1)
  if [[ "$RESULT" == "proxy_ok" ]]; then
    green "  OK  Proxy connection works locally"
    echo "  Server version: $(psql "$SRC_PROXY" -t -A -c "SELECT version();")"
  else
    die "Local proxy connection failed: $RESULT"
  fi
  echo ""

  green "[2/3] Creating test publication + subscription..."
  local TEST_PUB="_proxy_test_pub"
  local TEST_SUB="_proxy_test_sub"

  # Clean up any leftovers
  psql "$TGT" -c "DROP SUBSCRIPTION IF EXISTS $TEST_SUB;" 2>/dev/null || true
  psql "$SRC" -c "DROP PUBLICATION IF EXISTS $TEST_PUB;" 2>/dev/null || true

  # Create a minimal publication on source
  psql "$SRC" -c "CREATE PUBLICATION $TEST_PUB;" || die "Failed to create test publication on source"

  # Create subscription on target — this is the real test
  psql "$TGT" -c "
    CREATE SUBSCRIPTION $TEST_SUB
      CONNECTION '$SRC_PROXY'
      PUBLICATION $TEST_PUB
      WITH (copy_data = false, connect = true);
  " 2>&1
  echo ""

  green "[3/3] Checking subscription status..."
  sleep 3
  psql "$TGT" -c "
    SELECT subname, subenabled,
           (SELECT count(*) FROM pg_stat_subscription WHERE subname = '$TEST_SUB' AND pid IS NOT NULL) AS connected_workers
    FROM pg_subscription
    WHERE subname = '$TEST_SUB';
  "

  SUB_OK=$(psql "$TGT" -t -A -c "
    SELECT count(*) FROM pg_stat_subscription WHERE subname = '$TEST_SUB' AND pid IS NOT NULL;
  ")

  if [[ "$SUB_OK" -gt 0 ]]; then
    green "  OK  Target successfully connected to source via proxy"
  else
    red "  FAILED  Subscription created but no active worker — check connectivity"
  fi
  echo ""

  green "Cleaning up test objects..."
  psql "$TGT" -c "ALTER SUBSCRIPTION $TEST_SUB DISABLE;" 2>/dev/null || true
  psql "$TGT" -c "DROP SUBSCRIPTION $TEST_SUB;" 2>/dev/null || true
  psql "$SRC" -c "DROP PUBLICATION IF EXISTS $TEST_PUB;" 2>/dev/null || true
  green "  Done."

  echo ""
  bold "=== Proxy test complete ==="
}

# ---------------------------------------------------------------------------
# cleanup
# ---------------------------------------------------------------------------
do_cleanup() {
  require_env TGT

  bold "=== Cleanup (abort/reset) ==="
  yellow "Tolerant of missing objects — safe to run on a partially failed migration."
  echo ""

  green "Disabling subscription on target..."
  psql "$TGT" -c "ALTER SUBSCRIPTION $SLOT_NAME DISABLE;" 2>/dev/null || true

  green "Detaching slot from subscription..."
  psql "$TGT" -c "ALTER SUBSCRIPTION $SLOT_NAME SET (slot_name = NONE);" 2>/dev/null || true

  green "Dropping subscription on target..."
  psql "$TGT" -c "DROP SUBSCRIPTION IF EXISTS $SLOT_NAME;" 2>/dev/null || true

  if [[ -n "${SRC:-}" ]]; then
    green "Dropping publication on source..."
    psql "$SRC" -c "DROP PUBLICATION IF EXISTS $PUB_NAME;" 2>/dev/null || true

    green "Dropping replication slot on source..."
    psql "$SRC" -c "SELECT pg_drop_replication_slot('$SLOT_NAME');" 2>/dev/null || true
  else
    yellow "SRC not set — skipping source cleanup (publication + slot)."
  fi

  echo ""
  bold "=== Cleanup complete ==="
}

# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------
CMD="${1:-}"
case "$CMD" in
  preflight)        do_preflight ;;
  check-fks)        do_check_fks ;;
  copy-schema)      do_copy_schema ;;
  verify-schema)    do_verify_schema ;;
  dump-and-restore) do_dump_and_restore ;;
  proxy)            do_proxy ;;
  proxy-test)       do_proxy_test ;;
  monitor)          do_monitor ;;
  verify)           do_verify ;;
  cutover)          do_cutover ;;
  cleanup)          do_cleanup ;;
  *)
    bold "migrate.sh — Zero-downtime PostgreSQL migration tool"
    echo ""
    echo "Usage: $0 <subcommand>"
    echo ""
    echo "Subcommands:"
    echo "  preflight         Check versions, tools, wal_level, connectivity"
    echo "  check-fks         Verify excluded tables (MIGRATE_EXCLUDE_DATA) have no incoming FKs"
    echo "  copy-schema       Dump schema from source, apply pre-data to target"
    echo "  verify-schema     Compare tables, columns, indexes, sequences, FKs between source and target"
    echo "  dump-and-restore  Create pub+slot, snapshot dump, restore data+indexes, start subscription"
    echo "  proxy             Start TCP proxy (socat) so target can reach source via this machine"
    echo "  proxy-test        Test proxy connectivity using MIGRATE_SRC_PROXY"
    echo "  monitor           Watch replication lag"
    echo "  verify            Compare row counts, write_log gaps, checksums, sequence values"
    echo "  cutover           Sync sequences, tear down replication cleanly"
    echo "  cleanup           Abort/reset: drop subscription, publication, slot"
    echo ""
    echo "Required env vars:  SRC, TGT (PostgreSQL connection strings)"
    echo "Optional env vars:  MIGRATE_SLOT (default: migration_sub)"
    echo "                    MIGRATE_PUB  (default: migration_pub)"
    echo "                    MIGRATE_JOBS (default: 4)"
    echo "                    MIGRATE_WORK_DIR (default: .)"
    echo "                    MIGRATE_MONITOR_INTERVAL (default: 5)"
    echo "                    MIGRATE_EXCLUDE_DATA (comma-separated tables to skip data for)"
    echo "                    MIGRATE_EXCLUDE_TABLES (comma-separated tables to exclude entirely)"
    echo "                    MIGRATE_SCHEMAS (comma-separated schemas to dump, default: all)"
    echo "                    MIGRATE_SRC_PROXY (connection string target uses to reach source via proxy)"
    echo "                    MIGRATE_PROXY_PORT (local port for socat proxy, default: 5432)"
    ;;
esac
