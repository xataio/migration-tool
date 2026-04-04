import os
import time
import uuid
import pytest


TABLES = ["users", "products", "orders", "order_items", "events", "audit_log"]
DUMP_RESTORE_TIMEOUT = int(os.environ.get("DUMP_RESTORE_TIMEOUT", 7200))


class TestMigration:
    """Full migration flow test — steps must run in order."""

    def test_full_migration_flow(self, src_conn, tgt_conn, migrate):
        # ── 1. Preflight ─────────────────────────────────────────────
        result = migrate("preflight")
        assert result.returncode == 0, f"preflight failed:\n{result.stderr}"

        # ── 2. Copy schema ───────────────────────────────────────────
        # Clean target schema in case of previous run leftovers
        tgt_cur = tgt_conn.cursor()
        tgt_cur.execute("DROP SCHEMA public CASCADE; CREATE SCHEMA public;")

        result = migrate("copy-schema")
        assert result.returncode == 0, f"copy-schema failed:\n{result.stderr}"

        # ── 3. Dump and restore ──────────────────────────────────────
        result = migrate("dump-and-restore", timeout=DUMP_RESTORE_TIMEOUT)
        assert result.returncode == 0, f"dump-and-restore failed:\n{result.stderr}"

        # ── 4. Wait for replication to catch up ──────────────────────
        self._wait_for_replication(src_conn, timeout=300)

        # ── 5. Test writes during replication ────────────────────────
        self._test_write_replication(src_conn, tgt_conn)

        # ── 6. Verify pre-cutover ────────────────────────────────────
        result = migrate("verify")
        assert result.returncode == 0, f"verify failed:\n{result.stderr}"
        assert "MISMATCH" not in result.stdout, (
            f"verify found mismatches:\n{result.stdout}"
        )

        # ── 7. Cutover ──────────────────────────────────────────────
        result = migrate("cutover", input_text="y\n")
        assert result.returncode == 0, f"cutover failed:\n{result.stderr}"

        # ── 8. Verify post-cutover ───────────────────────────────────
        self._verify_post_cutover(src_conn, tgt_conn, migrate)

    def _wait_for_replication(self, src_conn, timeout):
        """Poll pg_replication_slots until lag reaches 0."""
        slot_name = "test_migration_sub"
        deadline = time.time() + timeout
        cur = src_conn.cursor()

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
                pytest.fail(f"Replication slot '{slot_name}' not found")
            lag = row[0]
            if lag == 0:
                print(f"Replication caught up (lag=0)")
                return
            print(f"Replication lag: {lag} bytes, waiting...")
            time.sleep(5)

        pytest.fail(f"Replication did not catch up within {timeout}s (lag={lag})")

    def _test_write_replication(self, src_conn, tgt_conn):
        """Insert rows into SRC and verify they replicate to TGT."""
        src_cur = src_conn.cursor()
        tgt_cur = tgt_conn.cursor()

        # Insert a user with JSONB metadata
        test_email = f"test_{uuid.uuid4().hex[:8]}@migration-test.com"
        src_cur.execute(
            """
            INSERT INTO users (email, name, metadata)
            VALUES (%s, %s, %s)
            RETURNING id;
            """,
            (
                test_email,
                "Migration Test User",
                '{"test": true, "source": "replication_test"}',
            ),
        )
        user_id = src_cur.fetchone()[0]

        # Insert an event with inet, uuid, jsonb columns
        test_session = str(uuid.uuid4())
        src_cur.execute(
            """
            INSERT INTO events (user_id, event_type, payload, ip_address, session_id)
            VALUES (%s, %s, %s, %s, %s)
            RETURNING id;
            """,
            (
                user_id,
                "test_migration",
                '{"action": "write_test", "step": 5}',
                "192.168.1.100",
                test_session,
            ),
        )
        event_id = src_cur.fetchone()[0]

        # Poll TGT for the replicated rows
        deadline = time.time() + 60
        user_found = False
        event_found = False

        while time.time() < deadline:
            if not user_found:
                tgt_cur.execute(
                    "SELECT email, name, metadata FROM users WHERE id = %s",
                    (user_id,),
                )
                row = tgt_cur.fetchone()
                if row:
                    assert row[0] == test_email
                    assert row[1] == "Migration Test User"
                    assert row[2]["test"] is True
                    user_found = True
                    print(f"User {user_id} replicated successfully")

            if not event_found:
                tgt_cur.execute(
                    "SELECT event_type, payload, ip_address, session_id "
                    "FROM events WHERE id = %s",
                    (event_id,),
                )
                row = tgt_cur.fetchone()
                if row:
                    assert row[0] == "test_migration"
                    assert row[1]["action"] == "write_test"
                    assert str(row[2]) == "192.168.1.100"
                    assert str(row[3]) == test_session
                    event_found = True
                    print(f"Event {event_id} replicated successfully")

            if user_found and event_found:
                return

            time.sleep(2)

        failures = []
        if not user_found:
            failures.append(f"user {user_id}")
        if not event_found:
            failures.append(f"event {event_id}")
        pytest.fail(f"Rows not replicated within 60s: {', '.join(failures)}")

    def _verify_post_cutover(self, src_conn, tgt_conn, migrate):
        """Post-cutover verification: row counts, data types, sequences."""
        src_cur = src_conn.cursor()
        tgt_cur = tgt_conn.cursor()

        # Run migrate verify
        result = migrate("verify")
        assert result.returncode == 0, f"post-cutover verify failed:\n{result.stderr}"

        # Compare row counts on all tables
        for table in TABLES:
            src_cur.execute(f'SELECT count(*) FROM "{table}"')
            src_count = src_cur.fetchone()[0]
            tgt_cur.execute(f'SELECT count(*) FROM "{table}"')
            tgt_count = tgt_cur.fetchone()[0]
            assert src_count == tgt_count, (
                f"Row count mismatch on {table}: src={src_count} tgt={tgt_count}"
            )
            print(f"  {table}: {src_count} rows OK")

        # Spot-check JSONB round-trip (users.metadata)
        src_cur.execute(
            "SELECT metadata FROM users ORDER BY id LIMIT 1"
        )
        src_meta = src_cur.fetchone()[0]
        tgt_cur.execute(
            "SELECT metadata FROM users ORDER BY id LIMIT 1"
        )
        tgt_meta = tgt_cur.fetchone()[0]
        assert src_meta == tgt_meta, (
            f"JSONB mismatch on users.metadata: {src_meta} vs {tgt_meta}"
        )
        print("  users.metadata JSONB round-trip OK")

        # Spot-check array round-trip (products.tags)
        src_cur.execute(
            "SELECT tags FROM products WHERE tags IS NOT NULL ORDER BY id LIMIT 1"
        )
        src_row = src_cur.fetchone()
        tgt_cur.execute(
            "SELECT tags FROM products WHERE tags IS NOT NULL ORDER BY id LIMIT 1"
        )
        tgt_row = tgt_cur.fetchone()
        if src_row and tgt_row:
            assert src_row[0] == tgt_row[0], (
                f"Array mismatch on products.tags: {src_row[0]} vs {tgt_row[0]}"
            )
            print("  products.tags array round-trip OK")

        # Verify sequences synced — target should be within a small delta
        # of source. Exact match isn't guaranteed because test inserts
        # advance source sequences, and replication replays with explicit
        # IDs may not advance target sequences identically.
        tgt_cur.execute(
            "SELECT sequencename, last_value FROM pg_sequences "
            "WHERE schemaname = 'public' ORDER BY sequencename"
        )
        tgt_seqs = {row[0]: row[1] for row in tgt_cur.fetchall()}

        # Re-read source sequences for the comparison
        src_cur.execute(
            "SELECT sequencename, last_value FROM pg_sequences "
            "WHERE schemaname = 'public' ORDER BY sequencename"
        )
        src_seqs = {row[0]: row[1] for row in src_cur.fetchall()}

        for seq_name, src_val in src_seqs.items():
            tgt_val = tgt_seqs.get(seq_name)
            assert tgt_val is not None, f"Sequence {seq_name} missing on target"
            # Allow small delta — test inserts create a few-row difference
            delta = abs(src_val - tgt_val)
            assert delta <= 10, (
                f"Sequence {seq_name} too far off: src={src_val} tgt={tgt_val} delta={delta}"
            )
            print(f"  sequence {seq_name}: src={src_val} tgt={tgt_val} (delta={delta}) OK")
