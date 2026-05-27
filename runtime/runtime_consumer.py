#!/usr/bin/env python3
"""
runtime_consumer.py — pgmq-backed event consumer for the runtime queue.

Replaces the RabbitMQ consumer for the feature/postgres-runtime-queue branch.
Reads from the `events` pgmq queue via runtime.claim_events() and persists
market / price snapshots into PostgreSQL, exactly like the original RabbitMQ
consumer but with:

  • LISTEN/NOTIFY wake-up instead of hot-polling
  • Exponential back-off retries via runtime.fail_event()
  • Dead-letter promotion after MAX_RETRIES failures
  • Advisory lock so only one consumer replica drains the queue concurrently

Usage:
    DATABASE_URL=postgres://... python runtime_consumer.py

Environment variables:
    DATABASE_URL        required — psycopg2-compatible connection string
    BATCH_SIZE          optional — messages claimed per loop (default 10)
    VT_SECONDS          optional — visibility timeout in seconds (default 30)
    MAX_RETRIES         optional — failures before DLQ promotion (default 3)
    LISTEN_TIMEOUT      optional — seconds to wait on NOTIFY before poll fallback (default 5)
"""
import json
import logging
import os
import select
import signal
import time

import psycopg2
import psycopg2.extensions

# ── Logging ───────────────────────────────────────────────────────────────────
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)-8s %(name)s %(message)s",
)
log = logging.getLogger("runtime_consumer")

# ── Config ────────────────────────────────────────────────────────────────────
DATABASE_URL   = os.environ["DATABASE_URL"]
BATCH_SIZE     = int(os.environ.get("BATCH_SIZE",     "10"))
VT_SECONDS     = int(os.environ.get("VT_SECONDS",     "30"))
MAX_RETRIES    = int(os.environ.get("MAX_RETRIES",    "3"))
LISTEN_TIMEOUT = int(os.environ.get("LISTEN_TIMEOUT", "5"))   # seconds

# Advisory lock key for single-consumer section (see 04_advisory.sql)
CONSUMER_LOCK_KEY = 1

# ── SQL ───────────────────────────────────────────────────────────────────────
SQL_TRY_LOCK  = "SELECT runtime.advisory_try_lock(%s)"
SQL_UNLOCK    = "SELECT runtime.advisory_unlock(%s)"
SQL_CLAIM     = "SELECT * FROM runtime.claim_events(%s, %s)"
SQL_ACK       = "SELECT runtime.ack_event(%s)"
SQL_FAIL      = "SELECT runtime.fail_event(%s, %s, %s)"
SQL_LISTEN    = "LISTEN runtime_events"

INSERT_MARKET = """
    INSERT INTO market_snapshots
        (question, slug, yes_price, no_price, volume_24h, category, end_date, fetched_at)
    VALUES
        (%(question)s, %(slug)s, %(yes_price)s, %(no_price)s,
         %(volume_24h)s, %(category)s, %(end_date)s, %(fetched_at)s)
    ON CONFLICT (slug, fetched_at) DO NOTHING
"""

INSERT_PRICE = """
    INSERT INTO price_snapshots
        (coin, price_usd, change_24h, fetched_at)
    VALUES
        (%(coin)s, %(price_usd)s, %(change_24h)s, %(fetched_at)s)
    ON CONFLICT (coin, fetched_at) DO NOTHING
"""

# ── Graceful shutdown ─────────────────────────────────────────────────────────
_shutdown = False


def _handle_signal(signum, frame):
    global _shutdown
    log.info("Signal %s received — shutting down gracefully", signum)
    _shutdown = True


signal.signal(signal.SIGINT,  _handle_signal)
signal.signal(signal.SIGTERM, _handle_signal)


# ── DB helpers ────────────────────────────────────────────────────────────────

def connect_db() -> psycopg2.extensions.connection:
    """Connect to PostgreSQL, retrying until available."""
    while not _shutdown:
        try:
            conn = psycopg2.connect(DATABASE_URL)
            # autocommit = True is the preferred way in psycopg2 ≥2.4.2.
            # set_isolation_level(ISOLATION_LEVEL_AUTOCOMMIT) is deprecated.
            conn.autocommit = True
            log.info("Connected to PostgreSQL")
            return conn
        except Exception as exc:
            log.error("PostgreSQL unavailable: %s — retrying in 5s", exc)
            time.sleep(5)
    raise SystemExit(0)


def reconnect_db(old_conn: psycopg2.extensions.connection) -> psycopg2.extensions.connection:
    """Close old connection and reconnect. Called on OperationalError / InterfaceError."""
    try:
        old_conn.close()
    except Exception:
        pass
    log.warning("Reconnecting to PostgreSQL...")
    return connect_db()


def setup_listen(conn: psycopg2.extensions.connection) -> None:
    """Issue LISTEN so this connection receives runtime_events notifications."""
    with conn.cursor() as cur:
        cur.execute(SQL_LISTEN)
    log.info("LISTEN runtime_events registered")


def try_acquire_consumer_lock(conn: psycopg2.extensions.connection) -> bool:
    """Return True if we successfully acquired the single-consumer advisory lock."""
    with conn.cursor() as cur:
        cur.execute(SQL_TRY_LOCK, (CONSUMER_LOCK_KEY,))
        return cur.fetchone()[0]


def release_consumer_lock(conn: psycopg2.extensions.connection) -> None:
    try:
        with conn.cursor() as cur:
            cur.execute(SQL_UNLOCK, (CONSUMER_LOCK_KEY,))
    except Exception:
        pass


# ── Message routing ───────────────────────────────────────────────────────────

def process_message(conn: psycopg2.extensions.connection,
                    msg_id: int,
                    payload: dict) -> None:
    """
    Route the payload to the correct INSERT statement and acknowledge.
    Raises on failure so the caller can call fail_event().
    """
    msg_type = payload.get("type", "market")

    if msg_type == "price":
        row = {
            "coin":       payload["coin"],
            "price_usd":  payload["price_usd"],
            "change_24h": payload.get("change_24h"),
            "fetched_at": payload.get("fetched_at"),
        }
        with conn.cursor() as cur:
            cur.execute(INSERT_PRICE, row)
        log.info("Stored price: %s $%.2f", row["coin"], row["price_usd"] or 0)

    else:  # "market" or legacy (no type)
        row = {
            "question":  payload.get("question"),
            "slug":      payload["slug"],
            "yes_price": payload["yes_price"],
            "no_price":  payload.get("no_price"),
            "volume_24h":payload.get("volume_24h"),
            "category":  payload.get("category"),
            "end_date":  payload.get("end_date") or None,
            "fetched_at":payload.get("fetched_at"),
        }
        with conn.cursor() as cur:
            cur.execute(INSERT_MARKET, row)
        log.info("Stored market snapshot: %s", row["slug"])

    # Ack — removes message from queue.
    with conn.cursor() as cur:
        cur.execute(SQL_ACK, (msg_id,))


def handle_failure(conn: psycopg2.extensions.connection,
                   msg_id: int,
                   error: str) -> None:
    """Increment retry counter; promote to DLQ if MAX_RETRIES exhausted."""
    try:
        with conn.cursor() as cur:
            cur.execute(SQL_FAIL, (msg_id, error, MAX_RETRIES))
    except Exception as exc:
        log.error("fail_event(%s) itself failed: %s", msg_id, exc)


# ── Main consume loop ─────────────────────────────────────────────────────────

def drain_batch(conn: psycopg2.extensions.connection) -> int:
    """
    Claim up to BATCH_SIZE messages, process each, return count processed.
    Uses AUTOCOMMIT so each ack/fail is immediately visible.
    Raises psycopg2.OperationalError / InterfaceError on DB connection loss
    so the caller can reconnect and re-try.
    """
    processed = 0
    with conn.cursor() as cur:
        cur.execute(SQL_CLAIM, (BATCH_SIZE, VT_SECONDS))
        rows = cur.fetchall()
        # pgmq.message_record columns: msg_id, read_ct, enqueued_at, vt, message
        col_names = [desc[0] for desc in cur.description]

    for row in rows:
        record = dict(zip(col_names, row))
        msg_id  = record["msg_id"]
        payload = record["message"]   # already a dict (psycopg2 JSONB → dict)

        if isinstance(payload, str):
            try:
                payload = json.loads(payload)
            except json.JSONDecodeError as exc:
                log.error("msg_id=%s malformed JSON — moving to DLQ: %s", msg_id, exc)
                handle_failure(conn, msg_id, f"JSONDecodeError: {exc}")
                continue

        try:
            process_message(conn, msg_id, payload)
            processed += 1
        except (psycopg2.OperationalError, psycopg2.InterfaceError):
            # Connection dropped mid-message; re-raise so main() reconnects.
            raise
        except Exception as exc:
            log.error("msg_id=%s processing failed: %s", msg_id, exc)
            handle_failure(conn, msg_id, str(exc))

    return processed


def wait_for_notify(conn: psycopg2.extensions.connection) -> None:
    """
    Block on the PostgreSQL connection socket until a NOTIFY arrives or
    LISTEN_TIMEOUT seconds elapse. This replaces hot-polling.
    """
    if select.select([conn], [], [], LISTEN_TIMEOUT)[0]:
        conn.poll()   # flush pg_notify payloads into conn.notifies
        while conn.notifies:
            n = conn.notifies.pop(0)
            log.debug("NOTIFY runtime_events: msg_id=%s", n.payload)


def main() -> None:
    conn = connect_db()
    setup_listen(conn)

    # Acquire single-consumer advisory lock.
    if not try_acquire_consumer_lock(conn):
        log.warning(
            "Another consumer already holds the advisory lock. "
            "Exiting — let the scheduler restart this replica when the lock is free."
        )
        conn.close()
        return

    log.info(
        "Consumer started. batch=%d vt=%ds max_retries=%d listen_timeout=%ds",
        BATCH_SIZE, VT_SECONDS, MAX_RETRIES, LISTEN_TIMEOUT,
    )

    try:
        while not _shutdown:
            try:
                # --- Drain whatever is already in the queue ---
                while not _shutdown:
                    n = drain_batch(conn)
                    if n < BATCH_SIZE:
                        break   # queue is drained; block on NOTIFY

                if _shutdown:
                    break

                # --- Block until a new event arrives or timeout ---
                wait_for_notify(conn)

            except (psycopg2.OperationalError, psycopg2.InterfaceError) as exc:
                log.error("DB connection lost: %s — reconnecting", exc)
                conn = reconnect_db(conn)
                setup_listen(conn)
                # Advisory lock is session-scoped — we must re-acquire it.
                if not try_acquire_consumer_lock(conn):
                    log.warning("Could not re-acquire advisory lock after reconnect — exiting.")
                    break
                log.info("Reconnected and re-acquired advisory lock.")

    finally:
        release_consumer_lock(conn)
        conn.close()
        log.info("Consumer shut down cleanly.")


if __name__ == "__main__":
    main()
