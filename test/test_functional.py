"""Functional tests for specific migration features.

Each test class creates its own tiny schema, runs a targeted migration,
verifies the feature under test, and cleans up. Designed to run in ~3 min.
"""

import os
import shutil
import socket
import subprocess
import time

import psycopg2
import pytest

from conftest import ReconnectingConnection, make_migrate


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def wait_for_replication(src_conn, slot_name, timeout=60):
    """Poll pg_replication_slots until replication lag reaches 0."""
    deadline = time.time() + timeout
    cur = src_conn.cursor()
    lag = None
    while time.time() < deadline:
        cur.execute(
            """
            SELECT pg_wal_lsn_diff(pg_current_wal_lsn(), confirmed_flush_lsn)
            FROM pg_replication_slots
            WHERE slot_name = %s;
            """,
            (slot_name,),
        )
        row = cur.fetchone()
        if row is None:
            time.sleep(2)
            continue
        lag = row[0]
        if lag == 0:
            return
        time.sleep(2)
    pytest.fail(f"Replication did not catch up within {timeout}s (lag={lag})")


def setup_src(src_conn, tgt_conn, ddl, seed=None):
    """Wipe both SRC and TGT public schemas, run DDL (+ optional seed) on SRC."""
    for conn in (src_conn, tgt_conn):
        cur = conn.cursor()
        cur.execute("DROP SCHEMA public CASCADE; CREATE SCHEMA public;")

    src_cur = src_conn.cursor()
    src_cur.execute(ddl)
    if seed:
        src_cur.execute(seed)


def cleanup_tables(src_conn, tgt_conn, tables):
    """DROP CASCADE given tables from both databases."""
    for conn in (src_conn, tgt_conn):
        cur = conn.cursor()
        for t in tables:
            try:
                cur.execute(f'DROP TABLE IF EXISTS {t} CASCADE')
            except Exception:
                pass


def find_free_port():
    """Find a free TCP port on localhost."""
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


# ---------------------------------------------------------------------------
# TestQuotedTableNames
# ---------------------------------------------------------------------------

class TestQuotedTableNames:
    """Verify migration handles quoted/reserved-word table names."""

    TABLES = ['"User"', '"Order"', '"Group"']
    SLOT = "func_quoted_sub"
    PUB = "func_quoted_pub"

    DDL = """
        CREATE TABLE "User" (
            id bigint PRIMARY KEY GENERATED ALWAYS AS IDENTITY,
            name text,
            email text UNIQUE
        );
        CREATE TABLE "Order" (
            id bigint PRIMARY KEY GENERATED ALWAYS AS IDENTITY,
            user_id bigint REFERENCES "User"(id),
            total numeric(10,2)
        );
        CREATE TABLE "Group" (
            id bigint PRIMARY KEY GENERATED ALWAYS AS IDENTITY,
            name text UNIQUE
        );
    """

    SEED = """
        INSERT INTO "User" (name, email) VALUES
            ('Alice', 'alice@example.com'),
            ('Bob', 'bob@example.com'),
            ('Carol', 'carol@example.com');
        INSERT INTO "Order" (user_id, total) VALUES
            (1, 10.00), (1, 20.00), (2, 30.00), (2, 40.00), (3, 50.00);
        INSERT INTO "Group" (name) VALUES ('admin'), ('users');
    """

    @pytest.fixture(autouse=True)
    def _setup(self, src_conn, tgt_conn, tmp_path):
        self.src = src_conn
        self.tgt = tgt_conn
        self.migrate = make_migrate(tmp_path, self.SLOT, self.PUB)
        setup_src(self.src, self.tgt, self.DDL, self.SEED)
        yield
        # cleanup
        try:
            self.migrate("cleanup")
        except Exception:
            pass
        cleanup_tables(self.src, self.tgt, self.TABLES)

    def test_quoted_migration(self):
        r = self.migrate("copy-schema")
        assert r.returncode == 0, f"copy-schema failed:\n{r.stderr}"

        r = self.migrate("dump-and-restore", timeout=600)
        assert r.returncode == 0, f"dump-and-restore failed:\n{r.stderr}"

        wait_for_replication(self.src, self.SLOT)

        # Insert during replication
        src_cur = self.src.cursor()
        src_cur.execute(
            """INSERT INTO "User" (name, email) VALUES ('Dave', 'dave@example.com')"""
        )

        # Wait for it to replicate
        deadline = time.time() + 30
        while time.time() < deadline:
            tgt_cur = self.tgt.cursor()
            tgt_cur.execute("""SELECT count(*) FROM "User" WHERE name = 'Dave'""")
            if tgt_cur.fetchone()[0] == 1:
                break
            time.sleep(1)
        else:
            pytest.fail("Replicated row not found on target within 30s")

        # Cutover
        r = self.migrate("cutover", input_text="y\n")
        assert r.returncode == 0, f"cutover failed:\n{r.stderr}"

        # Verify row counts
        for table in self.TABLES:
            src_cur = self.src.cursor()
            src_cur.execute(f"SELECT count(*) FROM {table}")
            src_count = src_cur.fetchone()[0]
            tgt_cur = self.tgt.cursor()
            tgt_cur.execute(f"SELECT count(*) FROM {table}")
            tgt_count = tgt_cur.fetchone()[0]
            assert src_count == tgt_count, (
                f"Row count mismatch on {table}: src={src_count} tgt={tgt_count}"
            )

        # Verify sequences synced (this tests the setval quoting fix)
        src_cur = self.src.cursor()
        src_cur.execute(
            "SELECT sequencename, last_value FROM pg_sequences "
            "WHERE schemaname = 'public' ORDER BY sequencename"
        )
        src_seqs = dict(src_cur.fetchall())
        tgt_cur = self.tgt.cursor()
        tgt_cur.execute(
            "SELECT sequencename, last_value FROM pg_sequences "
            "WHERE schemaname = 'public' ORDER BY sequencename"
        )
        tgt_seqs = dict(tgt_cur.fetchall())

        for seq_name, src_val in src_seqs.items():
            tgt_val = tgt_seqs.get(seq_name)
            assert tgt_val is not None, f"Sequence {seq_name} missing on target"
            assert abs(src_val - tgt_val) <= 1, (
                f"Sequence {seq_name} off: src={src_val} tgt={tgt_val}"
            )


# ---------------------------------------------------------------------------
# TestSequences
# ---------------------------------------------------------------------------

class TestSequences:
    """Verify sequences are correctly synced during cutover."""

    TABLES = ["seq_test", "seq_test_default", "seq_ref"]
    SLOT = "func_seq_sub"
    PUB = "func_seq_pub"

    DDL = """
        CREATE TABLE seq_test (
            id bigint PRIMARY KEY GENERATED ALWAYS AS IDENTITY,
            val text
        );
        CREATE TABLE seq_test_default (
            id bigint PRIMARY KEY GENERATED BY DEFAULT AS IDENTITY,
            val text
        );
        CREATE SEQUENCE seq_ref_id_seq;
        CREATE TABLE seq_ref (
            id bigint PRIMARY KEY DEFAULT nextval('seq_ref_id_seq'),
            val text
        );
    """

    @pytest.fixture(autouse=True)
    def _setup(self, src_conn, tgt_conn, tmp_path):
        self.src = src_conn
        self.tgt = tgt_conn
        self.migrate = make_migrate(tmp_path, self.SLOT, self.PUB)
        seed = "\n".join(
            f"INSERT INTO {t} (val) SELECT 'row' || g FROM generate_series(1,10) g;"
            for t in self.TABLES
        )
        setup_src(self.src, self.tgt, self.DDL, seed)
        yield
        try:
            self.migrate("cleanup")
        except Exception:
            pass
        cleanup_tables(self.src, self.tgt, self.TABLES)
        # Also drop standalone sequence
        for conn in (self.src, self.tgt):
            try:
                conn.cursor().execute("DROP SEQUENCE IF EXISTS seq_ref_id_seq CASCADE")
            except Exception:
                pass

    def test_sequence_sync(self):
        r = self.migrate("copy-schema")
        assert r.returncode == 0, f"copy-schema failed:\n{r.stderr}"

        r = self.migrate("dump-and-restore", timeout=600)
        assert r.returncode == 0, f"dump-and-restore failed:\n{r.stderr}"

        wait_for_replication(self.src, self.SLOT)

        r = self.migrate("cutover", input_text="y\n")
        assert r.returncode == 0, f"cutover failed:\n{r.stderr}"

        # Compare sequences
        src_cur = self.src.cursor()
        src_cur.execute(
            "SELECT sequencename, last_value FROM pg_sequences "
            "WHERE schemaname = 'public' ORDER BY sequencename"
        )
        src_seqs = dict(src_cur.fetchall())

        tgt_cur = self.tgt.cursor()
        tgt_cur.execute(
            "SELECT sequencename, last_value FROM pg_sequences "
            "WHERE schemaname = 'public' ORDER BY sequencename"
        )
        tgt_seqs = dict(tgt_cur.fetchall())

        for seq_name, src_val in src_seqs.items():
            tgt_val = tgt_seqs.get(seq_name)
            assert tgt_val is not None, f"Sequence {seq_name} missing on target"
            assert abs(src_val - tgt_val) <= 1, (
                f"Sequence {seq_name} off: src={src_val} tgt={tgt_val}"
            )

        # Insert on TGT without specifying ID — should not collide
        tgt_cur.execute(
            "INSERT INTO seq_test_default (val) VALUES ('after_cutover') RETURNING id"
        )
        new_id = tgt_cur.fetchone()[0]
        assert new_id > 10, f"Expected id > 10, got {new_id} — sequence not synced"


# ---------------------------------------------------------------------------
# TestForeignKeys
# ---------------------------------------------------------------------------

class TestForeignKeys:
    """Verify foreign key constraints are preserved after migration."""

    TABLES = ["fk_grandchild", "fk_child", "fk_parent"]  # drop order
    SLOT = "func_fk_sub"
    PUB = "func_fk_pub"

    DDL = """
        CREATE TABLE fk_parent (
            id bigint PRIMARY KEY GENERATED ALWAYS AS IDENTITY,
            name text
        );
        CREATE TABLE fk_child (
            id bigint PRIMARY KEY GENERATED ALWAYS AS IDENTITY,
            parent_id bigint NOT NULL REFERENCES fk_parent(id),
            val text
        );
        CREATE TABLE fk_grandchild (
            id bigint PRIMARY KEY GENERATED ALWAYS AS IDENTITY,
            child_id bigint NOT NULL REFERENCES fk_child(id),
            val text
        );
    """

    SEED = """
        INSERT INTO fk_parent (name) VALUES ('p1'), ('p2'), ('p3');
        INSERT INTO fk_child (parent_id, val) VALUES
            (1,'c1'),(1,'c2'),(2,'c3'),(2,'c4'),(3,'c5'),(3,'c6');
        INSERT INTO fk_grandchild (child_id, val) VALUES
            (1,'g1'),(1,'g2'),(2,'g3'),(2,'g4'),(3,'g5'),(3,'g6'),
            (4,'g7'),(4,'g8'),(5,'g9'),(5,'g10'),(6,'g11'),(6,'g12');
    """

    @pytest.fixture(autouse=True)
    def _setup(self, src_conn, tgt_conn, tmp_path):
        self.src = src_conn
        self.tgt = tgt_conn
        self.migrate = make_migrate(tmp_path, self.SLOT, self.PUB)
        setup_src(self.src, self.tgt, self.DDL, self.SEED)
        yield
        try:
            self.migrate("cleanup")
        except Exception:
            pass
        cleanup_tables(self.src, self.tgt, self.TABLES)

    def test_foreign_keys_preserved(self):
        r = self.migrate("copy-schema")
        assert r.returncode == 0, f"copy-schema failed:\n{r.stderr}"

        r = self.migrate("dump-and-restore", timeout=600)
        assert r.returncode == 0, f"dump-and-restore failed:\n{r.stderr}"

        # Verify FK count matches
        r = self.migrate("verify-schema")
        assert r.returncode == 0, f"verify-schema failed:\n{r.stderr}"

        # Count FKs on source
        src_cur = self.src.cursor()
        src_cur.execute("""
            SELECT count(*) FROM information_schema.table_constraints
            WHERE constraint_type = 'FOREIGN KEY' AND table_schema = 'public'
        """)
        src_fk_count = src_cur.fetchone()[0]

        # Count FKs on target
        tgt_cur = self.tgt.cursor()
        tgt_cur.execute("""
            SELECT count(*) FROM information_schema.table_constraints
            WHERE constraint_type = 'FOREIGN KEY' AND table_schema = 'public'
        """)
        tgt_fk_count = tgt_cur.fetchone()[0]
        assert src_fk_count == tgt_fk_count, (
            f"FK count mismatch: src={src_fk_count} tgt={tgt_fk_count}"
        )
        assert src_fk_count == 2, f"Expected 2 FKs, got {src_fk_count}"

        # Verify FK enforcement on target: insert with bad parent_id should fail
        tgt_cur = self.tgt.cursor()
        with pytest.raises(psycopg2.errors.ForeignKeyViolation):
            tgt_cur.execute(
                "INSERT INTO fk_child (parent_id, val) VALUES (9999, 'bad')"
            )

        wait_for_replication(self.src, self.SLOT)

        r = self.migrate("cutover", input_text="y\n")
        assert r.returncode == 0, f"cutover failed:\n{r.stderr}"


# ---------------------------------------------------------------------------
# TestIndexes
# ---------------------------------------------------------------------------

class TestIndexes:
    """Verify indexes are correctly copied during migration."""

    TABLES = ["idx_test"]
    SLOT = "func_idx_sub"
    PUB = "func_idx_pub"

    DDL = """
        CREATE TABLE idx_test (
            id bigint PRIMARY KEY GENERATED ALWAYS AS IDENTITY,
            name text,
            email text UNIQUE,
            tags text[],
            metadata jsonb DEFAULT '{}',
            created_at timestamptz DEFAULT now()
        );
        CREATE INDEX idx_test_name ON idx_test(name);
        CREATE INDEX idx_test_tags ON idx_test USING gin(tags);
        CREATE INDEX idx_test_metadata ON idx_test USING gin(metadata);
    """

    SEED = """
        INSERT INTO idx_test (name, email, tags, metadata) VALUES
            ('alice', 'a@x.com', ARRAY['a','b'], '{"role":"admin"}'),
            ('bob',   'b@x.com', ARRAY['c'],     '{"role":"user"}'),
            ('carol', 'c@x.com', ARRAY['a','c'], '{"role":"user"}'),
            ('dave',  'd@x.com', ARRAY['b'],     '{"role":"admin"}'),
            ('eve',   'e@x.com', ARRAY['a','b','c'], '{"role":"mod"}');
    """

    @pytest.fixture(autouse=True)
    def _setup(self, src_conn, tgt_conn, tmp_path):
        self.src = src_conn
        self.tgt = tgt_conn
        self.migrate = make_migrate(tmp_path, self.SLOT, self.PUB)
        setup_src(self.src, self.tgt, self.DDL, self.SEED)
        yield
        try:
            self.migrate("cleanup")
        except Exception:
            pass
        cleanup_tables(self.src, self.tgt, self.TABLES)

    def test_indexes_preserved(self):
        r = self.migrate("copy-schema")
        assert r.returncode == 0, f"copy-schema failed:\n{r.stderr}"

        r = self.migrate("dump-and-restore", timeout=600)
        assert r.returncode == 0, f"dump-and-restore failed:\n{r.stderr}"

        # Verify index count matches
        r = self.migrate("verify-schema")
        assert r.returncode == 0, f"verify-schema failed:\n{r.stderr}"

        src_cur = self.src.cursor()
        src_cur.execute("""
            SELECT count(*) FROM pg_indexes
            WHERE schemaname = 'public' AND tablename = 'idx_test'
        """)
        src_idx_count = src_cur.fetchone()[0]

        tgt_cur = self.tgt.cursor()
        tgt_cur.execute("""
            SELECT count(*) FROM pg_indexes
            WHERE schemaname = 'public' AND tablename = 'idx_test'
        """)
        tgt_idx_count = tgt_cur.fetchone()[0]
        assert src_idx_count == tgt_idx_count, (
            f"Index count mismatch: src={src_idx_count} tgt={tgt_idx_count}"
        )

        # Verify each index exists with correct access method
        expected_indexes = {
            "idx_test_pkey": "btree",
            "idx_test_email_key": "btree",
            "idx_test_name": "btree",
            "idx_test_tags": "gin",
            "idx_test_metadata": "gin",
        }
        tgt_cur.execute("""
            SELECT indexname,
                   (SELECT amname FROM pg_am WHERE oid = (
                       SELECT relam FROM pg_class WHERE relname = indexname
                   ))
            FROM pg_indexes
            WHERE schemaname = 'public' AND tablename = 'idx_test'
        """)
        tgt_indexes = dict(tgt_cur.fetchall())

        for idx_name, expected_am in expected_indexes.items():
            actual_am = tgt_indexes.get(idx_name)
            assert actual_am is not None, f"Index {idx_name} missing on target"
            assert actual_am == expected_am, (
                f"Index {idx_name}: expected {expected_am}, got {actual_am}"
            )

        wait_for_replication(self.src, self.SLOT)

        r = self.migrate("cutover", input_text="y\n")
        assert r.returncode == 0, f"cutover failed:\n{r.stderr}"


# ---------------------------------------------------------------------------
# TestProxy
# ---------------------------------------------------------------------------

class TestProxy:
    """Verify migration works through a socat proxy."""

    TABLES = ["proxy_test"]
    SLOT = "func_proxy_sub"
    PUB = "func_proxy_pub"

    DDL = """
        CREATE TABLE proxy_test (
            id bigint PRIMARY KEY GENERATED ALWAYS AS IDENTITY,
            val text
        );
    """
    SEED = """
        INSERT INTO proxy_test (val) VALUES ('a'), ('b'), ('c');
    """

    @pytest.fixture(autouse=True)
    def _setup(self, src_conn, tgt_conn, tmp_path):
        if not shutil.which("socat"):
            pytest.skip("socat not installed")

        # Proxy only works when TGT can reach the local socat listener.
        # Skip if TGT is a remote host (it can't connect back to localhost).
        tgt_dsn = os.environ["TGT"]
        tgt_host = self._parse_connstr(tgt_dsn)[0]
        if tgt_host not in ("localhost", "127.0.0.1", "::1"):
            pytest.skip("proxy test requires TGT on localhost (remote TGT can't reach local socat)")

        self.src = src_conn
        self.tgt = tgt_conn
        self.migrate = make_migrate(tmp_path, self.SLOT, self.PUB)
        setup_src(self.src, self.tgt, self.DDL, self.SEED)
        self.socat_proc = None
        yield
        if self.socat_proc:
            self.socat_proc.kill()
            self.socat_proc.wait()
        try:
            self.migrate("cleanup")
        except Exception:
            pass
        cleanup_tables(self.src, self.tgt, self.TABLES)

    def _parse_connstr(self, dsn):
        """Extract host and port from a psycopg2-compatible DSN."""
        conn = psycopg2.connect(dsn)
        params = conn.get_dsn_parameters()
        conn.close()
        return params["host"], int(params.get("port", 5432))

    def _build_proxy_connstr(self, original_dsn, proxy_port):
        """Build a connection string that goes through the local proxy."""
        from urllib.parse import urlparse, urlunparse

        parsed = urlparse(original_dsn)
        proxy_netloc = f"{parsed.username}"
        if parsed.password:
            proxy_netloc = f"{parsed.username}:{parsed.password}"
        proxy_netloc += f"@127.0.0.1:{proxy_port}"
        return urlunparse(parsed._replace(netloc=proxy_netloc))

    def test_proxy_migration(self):
        src_dsn = os.environ["SRC"]
        src_host, src_port = self._parse_connstr(src_dsn)
        proxy_port = find_free_port()

        # Start socat proxy
        self.socat_proc = subprocess.Popen(
            [
                "socat",
                f"TCP-LISTEN:{proxy_port},fork,reuseaddr",
                f"TCP:{src_host}:{src_port}",
            ],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        # Give socat a moment to bind
        time.sleep(1)

        proxy_dsn = self._build_proxy_connstr(src_dsn, proxy_port)
        extra_env = {"MIGRATE_SRC_PROXY": proxy_dsn}

        r = self.migrate("copy-schema")
        assert r.returncode == 0, f"copy-schema failed:\n{r.stderr}"

        r = self.migrate("dump-and-restore", timeout=600, extra_env=extra_env)
        assert r.returncode == 0, f"dump-and-restore failed:\n{r.stderr}"

        wait_for_replication(self.src, self.SLOT)

        # Verify rows on target
        tgt_cur = self.tgt.cursor()
        tgt_cur.execute("SELECT count(*) FROM proxy_test")
        assert tgt_cur.fetchone()[0] == 3

        r = self.migrate("cutover", input_text="y\n")
        assert r.returncode == 0, f"cutover failed:\n{r.stderr}"
