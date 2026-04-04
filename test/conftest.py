import os
import subprocess
import pytest
import psycopg2


MIGRATE_SH = os.path.join(os.path.dirname(__file__), "..", "migrate.sh")
SLOT_NAME = "test_migration_sub"
PUB_NAME = "test_migration_pub"


class ReconnectingConnection:
    """Thin wrapper around psycopg2 that reconnects on stale/dropped connections."""

    def __init__(self, dsn):
        self._dsn = dsn
        self._conn = None

    def _connect(self):
        if self._conn is not None:
            try:
                self._conn.close()
            except Exception:
                pass
        self._conn = psycopg2.connect(self._dsn)
        self._conn.autocommit = True

    def cursor(self):
        if self._conn is None or self._conn.closed:
            self._connect()
        try:
            cur = self._conn.cursor()
            cur.execute("SELECT 1")
            return cur
        except Exception:
            self._connect()
            return self._conn.cursor()

    def close(self):
        if self._conn is not None:
            try:
                self._conn.close()
            except Exception:
                pass


@pytest.fixture(scope="session")
def src_conn():
    conn = ReconnectingConnection(os.environ["SRC"])
    yield conn
    conn.close()


@pytest.fixture(scope="session")
def tgt_conn():
    conn = ReconnectingConnection(os.environ["TGT"])
    yield conn
    conn.close()


@pytest.fixture(scope="session")
def work_dir(tmp_path_factory):
    return tmp_path_factory.mktemp("migrate_work")


@pytest.fixture(scope="session")
def migrate(work_dir):
    """Return a callable that runs migrate.sh with the test environment."""

    def _run(subcommand, timeout=600, input_text=None):
        env = {
            **os.environ,
            "MIGRATE_SLOT": SLOT_NAME,
            "MIGRATE_PUB": PUB_NAME,
            "MIGRATE_WORK_DIR": str(work_dir),
            "MIGRATE_JOBS": "2",
        }
        result = subprocess.run(
            ["bash", MIGRATE_SH, subcommand],
            env=env,
            capture_output=True,
            text=True,
            timeout=timeout,
            input=input_text,
        )
        print(f"\n--- migrate.sh {subcommand} (rc={result.returncode}) ---")
        if result.stdout:
            print(result.stdout[-2000:])
        if result.stderr:
            print("STDERR:", result.stderr[-2000:])
        return result

    return _run


@pytest.fixture(scope="session", autouse=True)
def cleanup_on_exit(migrate):
    """Run cleanup after all tests, regardless of outcome."""
    yield
    try:
        migrate("cleanup")
    except Exception as e:
        print(f"Cleanup failed (may be expected): {e}")
