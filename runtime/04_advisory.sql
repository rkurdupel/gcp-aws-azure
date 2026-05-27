-- =============================================================================
-- runtime/04_advisory.sql
-- PostgreSQL advisory lock helpers for single-consumer critical sections.
--
-- Advisory locks are session-scoped, lightweight, and do NOT interact with
-- MVCC. They are the right tool for:
--   • Ensuring only one consumer processes a specific event type at a time
--   • Leader-election among multiple consumer replicas
--   • Preventing concurrent schema migrations
--
-- Lock namespace:
--   We use a fixed application-level "key space" (runtime.LOCK_NAMESPACE) so
--   our locks never collide with other apps using advisory locks in the same DB.
--
-- All locks are NON-BLOCKING by default (advisory_try_lock returns FALSE if the
-- lock is already held). Use advisory_lock() for blocking acquisition.
--
-- Run after 03_notify.sql.
-- =============================================================================

-- ── Lock namespace ────────────────────────────────────────────────────────────
-- We reserve a fixed int4 prefix (first argument to pg_try_advisory_lock).
-- 0x52554E54 = ASCII "RUNT" — easy to spot in pg_locks.

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_namespace WHERE nspname = 'runtime'
    ) THEN
        CREATE SCHEMA runtime;
    END IF;
END;
$$;

CREATE TABLE IF NOT EXISTS runtime.advisory_lock_keys (
    lock_key    INT         PRIMARY KEY,
    description TEXT        NOT NULL
);

INSERT INTO runtime.advisory_lock_keys (lock_key, description) VALUES
    (1, 'single-consumer-events   — at most one replica drains the events queue'),
    (2, 'schema-migration          — prevents concurrent DDL migrations'),
    (3, 'dlq-reaper                — single process replays / expires DLQ items')
ON CONFLICT (lock_key) DO UPDATE
    SET description = EXCLUDED.description;

COMMENT ON TABLE runtime.advisory_lock_keys IS
  'Registry of advisory lock ids used in the runtime schema. '
  'All locks share the fixed namespace key 0x52554E54 (1415865428).';

-- ── Namespace constant ────────────────────────────────────────────────────────
-- Callers retrieve the namespace via this function.

CREATE OR REPLACE FUNCTION runtime.lock_namespace()
RETURNS INT
LANGUAGE sql
IMMUTABLE
PARALLEL SAFE
AS $$
    SELECT 1415865428;   -- 0x52554E54
$$;

-- ── try_lock (non-blocking) ───────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION runtime.advisory_try_lock(
    p_key INT
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = runtime, public
AS $$
BEGIN
    RETURN pg_try_advisory_lock(runtime.lock_namespace(), p_key);
END;
$$;

COMMENT ON FUNCTION runtime.advisory_try_lock(INT) IS
  'Non-blocking advisory lock. Returns TRUE if acquired, FALSE if already held '
  'by another session. Lock is released on session exit or explicit unlock.';

-- ── lock (blocking) ───────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION runtime.advisory_lock(
    p_key INT
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = runtime, public
AS $$
BEGIN
    PERFORM pg_advisory_lock(runtime.lock_namespace(), p_key);
END;
$$;

COMMENT ON FUNCTION runtime.advisory_lock(INT) IS
  'Blocking advisory lock. Waits until the lock is available. '
  'Use with caution — can deadlock if lock order is not controlled.';

-- ── unlock ────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION runtime.advisory_unlock(
    p_key INT
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = runtime, public
AS $$
BEGIN
    RETURN pg_advisory_unlock(runtime.lock_namespace(), p_key);
END;
$$;

COMMENT ON FUNCTION runtime.advisory_unlock(INT) IS
  'Release a previously acquired advisory lock. Returns TRUE on success.';

-- ── unlock_all ────────────────────────────────────────────────────────────────
-- Useful in consumer teardown / signal handlers.

CREATE OR REPLACE FUNCTION runtime.advisory_unlock_all()
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = runtime, public
AS $$
BEGIN
    PERFORM pg_advisory_unlock_all();
END;
$$;

COMMENT ON FUNCTION runtime.advisory_unlock_all() IS
  'Release all advisory locks held by the current session.';

-- ── Monitoring view ───────────────────────────────────────────────────────────
-- Shows which sessions currently hold runtime advisory locks.

CREATE OR REPLACE VIEW runtime.active_locks AS
SELECT
    l.pid,
    a.usename,
    a.application_name,
    a.client_addr,
    a.state,
    k.description  AS lock_name,
    l.granted
FROM pg_locks         l
JOIN pg_stat_activity a ON a.pid = l.pid
LEFT JOIN runtime.advisory_lock_keys k
    ON  l.classid = runtime.lock_namespace()::OID
    AND l.objid   = k.lock_key::OID
WHERE l.locktype  = 'advisory'
  AND l.classid   = runtime.lock_namespace()::OID;

COMMENT ON VIEW runtime.active_locks IS
  'Active advisory locks held by live sessions, annotated with lock names.';
