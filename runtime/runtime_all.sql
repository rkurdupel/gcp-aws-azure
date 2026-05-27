-- =============================================================================
-- runtime/01_schema.sql
-- Bootstrap the `runtime` schema and enable pgmq.
--
-- Run once as a superuser (or a role with CREATE EXTENSION privilege):
--   psql $DATABASE_URL -f runtime/01_schema.sql
--
-- Idempotent: safe to re-run on upgrades.
-- =============================================================================

-- ── Schema ────────────────────────────────────────────────────────────────────
CREATE SCHEMA IF NOT EXISTS runtime;

COMMENT ON SCHEMA runtime IS
  'Runtime event queue layer (pgmq-backed). '
  'Owns the event queues, wrappers, dead-letter table, and advisory-lock helpers.';

-- ── pgmq extension ────────────────────────────────────────────────────────────
-- pgmq must be installed in the database BEFORE this script is run.
-- On Postgres 15+: CREATE EXTENSION pgmq;
-- Supabase / managed: already shipped; just call pgmq.create().
CREATE EXTENSION IF NOT EXISTS pgmq;

-- ── Queues ────────────────────────────────────────────────────────────────────
-- pgmq.create() is idempotent — calling it on an existing queue is a no-op.

-- Primary event queue: all normalised market / price events land here first.
SELECT pgmq.create('events');

-- Dead-letter queue: events that exceed MAX_DELIVERY_ATTEMPTS are moved here.
-- We use a separate named queue (not pgmq archive) so that DLQ rows are
-- queryable with the same pgmq API and can be replayed or inspected easily.
SELECT pgmq.create('events_dlq');

-- ── Retry metadata table ──────────────────────────────────────────────────────
-- pgmq tracks `read_ct` (read count) on every message automatically.
-- We store per-message retry state here so that fail_event() can decide
-- whether to re-enqueue or DLQ without mutating pgmq internals.

CREATE TABLE IF NOT EXISTS runtime.event_retry (
    msg_id          BIGINT      PRIMARY KEY,   -- pgmq message id in 'events' queue
    queue_name      TEXT        NOT NULL DEFAULT 'events',
    attempt_count   INT         NOT NULL DEFAULT 0,
    last_error      TEXT,
    last_failed_at  TIMESTAMPTZ,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

COMMENT ON TABLE runtime.event_retry IS
  'Per-message delivery attempt counter used by runtime.fail_event() '
  'to gate promotion to the dead-letter queue.';

-- ── DLQ audit table ───────────────────────────────────────────────────────────
-- When a message is moved to events_dlq we also write a row here so that
-- the Python consumer / ops tooling can query poisoned events without having
-- to page through pgmq directly.

CREATE TABLE IF NOT EXISTS runtime.dead_letter_audit (
    id              BIGSERIAL   PRIMARY KEY,
    original_msg_id BIGINT      NOT NULL,   -- msg_id in the original 'events' queue
    dlq_msg_id      BIGINT,                 -- msg_id assigned in 'events_dlq' (NULL = unknown)
    queue_name      TEXT        NOT NULL DEFAULT 'events',
    payload         JSONB       NOT NULL,
    last_error      TEXT,
    attempt_count   INT         NOT NULL,
    dead_at         TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    replayed_at     TIMESTAMPTZ             -- set by dlq_replay/dlq_replay_all; NULL = not yet replayed
);

-- ── Upgrade path ──────────────────────────────────────────────────────────────
-- CREATE TABLE IF NOT EXISTS only creates the table on a fresh install.
-- ALTER TABLE ADD COLUMN IF NOT EXISTS handles existing deployments that already
-- have dead_letter_audit but are missing columns added in later revisions.
-- These statements are idempotent and safe to re-run.
ALTER TABLE runtime.dead_letter_audit
    ADD COLUMN IF NOT EXISTS replayed_at TIMESTAMPTZ;   -- NULL = not yet replayed/discarded

ALTER TABLE runtime.dead_letter_audit
    ADD COLUMN IF NOT EXISTS dlq_msg_id BIGINT;          -- msg_id in events_dlq queue

CREATE INDEX IF NOT EXISTS idx_dlq_audit_dead_at
    ON runtime.dead_letter_audit (dead_at DESC);

-- Partial index: fast lookup of rows still requiring ops attention.
-- Covers both un-replayed AND un-discarded rows (replayed_at IS NULL for both).
CREATE INDEX IF NOT EXISTS idx_dlq_audit_unreplayed
    ON runtime.dead_letter_audit (dead_at DESC)
    WHERE replayed_at IS NULL;

COMMENT ON TABLE runtime.dead_letter_audit IS
  'Audit log of events that exhausted all retries and were moved to events_dlq. '
  'dead_at is always set (NOT NULL). '
  'replayed_at is set by dlq_replay() and dlq_replay_all() on re-enqueue. '
  'dlq_discard() also sets replayed_at (= discard timestamp) so ops queries '
  'using WHERE replayed_at IS NULL exclude both replayed and discarded rows.';
-- =============================================================================
-- runtime/02_wrappers.sql
-- High-level PL/pgSQL wrappers around raw pgmq calls.
--
-- Functions:
--   runtime.enqueue_event(payload JSONB)          → BIGINT  (msg_id)
--   runtime.claim_events(n INT, vt INT)           → SETOF pgmq.message_record
--   runtime.ack_event(msg_id BIGINT)              → VOID
--   runtime.fail_event(msg_id BIGINT, err TEXT)   → VOID
--
-- All wrappers are SECURITY DEFINER so application roles only need EXECUTE on
-- the wrapper, not direct access to pgmq internals.
--
-- Run after 01_schema.sql.
-- =============================================================================

-- ── enqueue_event ─────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION runtime.enqueue_event(
    p_payload JSONB
)
RETURNS BIGINT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = runtime, public
AS $$
DECLARE
    v_msg_id BIGINT;
BEGIN
    -- pgmq.send returns the assigned message id.
    SELECT pgmq.send('events', p_payload)
    INTO   v_msg_id;

    -- Initialise retry counter for this message.
    INSERT INTO runtime.event_retry (msg_id, queue_name)
    VALUES (v_msg_id, 'events')
    ON CONFLICT (msg_id) DO NOTHING;

    -- NOTE: pg_notify is intentionally NOT called here.
    -- The trigger trg_runtime_events_notify (03_notify.sql) fires on every
    -- INSERT into the pgmq table — including direct pgmq.send() calls that
    -- bypass this wrapper. Calling pg_notify here too would cause double
    -- notifications for every enqueue_event() call.

    RETURN v_msg_id;
END;
$$;

COMMENT ON FUNCTION runtime.enqueue_event(JSONB) IS
  'Push a JSON payload onto the events queue and notify waiting consumers. '
  'Returns the pgmq message id.';

-- ── claim_events ─────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION runtime.claim_events(
    p_n  INT     DEFAULT 1,    -- number of messages to claim in one call
    p_vt INT     DEFAULT 30    -- visibility timeout in seconds
)
RETURNS SETOF pgmq.message_record
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = runtime, public
AS $$
BEGIN
    -- pgmq.read hides claimed messages from other consumers for p_vt seconds.
    -- If the consumer crashes without calling ack_event() the message becomes
    -- visible again after the timeout (at-least-once delivery).
    RETURN QUERY
        SELECT * FROM pgmq.read('events', p_vt, p_n);
END;
$$;

COMMENT ON FUNCTION runtime.claim_events(INT, INT) IS
  'Claim up to p_n events from the queue with a p_vt-second visibility window. '
  'Un-acked messages re-appear automatically after vt expires.';

-- ── ack_event ────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION runtime.ack_event(
    p_msg_id BIGINT
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = runtime, public
AS $$
BEGIN
    -- Permanently remove the message from the queue.
    PERFORM pgmq.delete('events', p_msg_id);

    -- Clean up retry state — no longer needed.
    DELETE FROM runtime.event_retry WHERE msg_id = p_msg_id;
END;
$$;

COMMENT ON FUNCTION runtime.ack_event(BIGINT) IS
  'Acknowledge successful processing: deletes the message and its retry record.';

-- ── fail_event ───────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION runtime.fail_event(
    p_msg_id    BIGINT,
    p_error     TEXT    DEFAULT NULL,
    p_max_tries INT     DEFAULT 3
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = runtime, public
AS $$
DECLARE
    v_attempts   INT;
    v_payload    JSONB;
    v_dlq_msg_id BIGINT;
BEGIN
    -- ── 1. Increment attempt counter ─────────────────────────────────────────
    UPDATE runtime.event_retry
    SET    attempt_count  = attempt_count + 1,
           last_error     = p_error,
           last_failed_at = NOW()
    WHERE  msg_id = p_msg_id
    RETURNING attempt_count INTO v_attempts;

    IF NOT FOUND THEN
        -- Safety net: retry row was missing (e.g. message pre-dated this schema).
        INSERT INTO runtime.event_retry (msg_id, attempt_count, last_error, last_failed_at)
        VALUES (p_msg_id, 1, p_error, NOW())
        RETURNING attempt_count INTO v_attempts;
    END IF;

    -- ── 2. Decide: retry or DLQ ──────────────────────────────────────────────
    IF v_attempts < p_max_tries THEN
        -- Release the visibility lock so the message becomes claimable again
        -- after an exponential back-off (2^attempt * 5 s, capped at 120 s).
        PERFORM pgmq.set_vt(
            'events',
            p_msg_id,
            LEAST(120, (5 * (2 ^ v_attempts))::INT)
        );
        RAISE NOTICE 'runtime.fail_event: msg_id=% attempt=%/% — will retry in ~%s',
            p_msg_id, v_attempts, p_max_tries,
            LEAST(120, (5 * (2 ^ v_attempts))::INT);
    ELSE
        -- ── 3. Promote to DLQ ────────────────────────────────────────────────
        -- Read the raw payload from the pgmq internal table.
        -- pgmq stores queue 'events' in pgmq.q_events (schema-qualified install)
        -- or public.q_events (schema-less install). Try both defensively.
        BEGIN
            EXECUTE '
                SELECT message FROM pgmq.q_events WHERE msg_id = $1
            ' INTO v_payload USING p_msg_id;
        EXCEPTION WHEN undefined_table THEN
            BEGIN
                EXECUTE '
                    SELECT message FROM public.q_events WHERE msg_id = $1
                ' INTO v_payload USING p_msg_id;
            EXCEPTION WHEN undefined_table THEN
                v_payload := NULL;
            END;
        END;

        IF v_payload IS NULL THEN
            -- Message may have already expired or been deleted.
            v_payload := jsonb_build_object(
                '_dlq_warning', 'original payload not found at DLQ promotion time',
                '_msg_id',      p_msg_id,
                '_error',       p_error
            );
        END IF;

        -- Move message to DLQ queue; capture the new dlq msg_id for the audit row.
        SELECT pgmq.send('events_dlq', v_payload) INTO v_dlq_msg_id;

        -- Write audit row with both the original and DLQ msg ids.
        INSERT INTO runtime.dead_letter_audit
            (original_msg_id, dlq_msg_id, queue_name, payload, last_error, attempt_count)
        VALUES
            (p_msg_id, v_dlq_msg_id, 'events', v_payload, p_error, v_attempts);

        -- Remove from primary queue and retry table.
        PERFORM pgmq.delete('events', p_msg_id);
        DELETE FROM runtime.event_retry WHERE msg_id = p_msg_id;

        RAISE WARNING 'runtime.fail_event: msg_id=% moved to events_dlq after % attempts. error: %',
            p_msg_id, v_attempts, p_error;
    END IF;
END;
$$;

COMMENT ON FUNCTION runtime.fail_event(BIGINT, TEXT, INT) IS
  'Record a processing failure. Re-schedules the message with exponential back-off '
  'until p_max_tries is reached, then promotes to events_dlq.';
-- =============================================================================
-- runtime/03_notify.sql
-- LISTEN / NOTIFY helpers so consumers can block efficiently instead of
-- hot-polling the queue table every N milliseconds.
--
-- Channel contract:
--   Channel name : runtime_events
--   Payload      : the pgmq msg_id (TEXT) that was just enqueued
--
-- Consumer workflow:
--   1. LISTEN runtime_events;
--   2. Wait (pg_notify wakes the connection)
--   3. Call runtime.claim_events() to fetch the batch
--   4. Process, then LISTEN again
--
-- The trigger fires inside the same transaction as enqueue_event(), so a
-- notification is guaranteed to arrive AFTER the row is committed and visible.
--
-- Run after 02_wrappers.sql.
-- =============================================================================

-- ── Trigger function ──────────────────────────────────────────────────────────
-- This fires on every INSERT into pgmq's internal queue table for 'events'.
-- We do NOT put the NOTIFY inside enqueue_event() alone, because pgmq.send()
-- can also be called directly. The trigger makes the notification unconditional.

CREATE OR REPLACE FUNCTION runtime.notify_on_event_enqueue()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = runtime, public
AS $$
BEGIN
    -- NEW.msg_id is the pgmq message id assigned on INSERT.
    PERFORM pg_notify('runtime_events', NEW.msg_id::TEXT);
    RETURN NEW;
END;
$$;

COMMENT ON FUNCTION runtime.notify_on_event_enqueue() IS
  'Trigger function: fires pg_notify(''runtime_events'', msg_id) on every new '
  'row inserted into the events queue table. Allows consumers to LISTEN instead '
  'of hot-polling.';

-- ── Attach trigger to pgmq internal table ────────────────────────────────────
-- pgmq stores the events queue in public.q_events (Postgres-native install) or
-- pgmq.q_events (schema-qualified install). We try both; one will succeed.

DO $$
BEGIN
    -- Attempt 1: schema-less install (public.q_events)
    IF to_regclass('public.q_events') IS NOT NULL THEN
        DROP TRIGGER IF EXISTS trg_runtime_events_notify ON public.q_events;
        CREATE TRIGGER trg_runtime_events_notify
            AFTER INSERT ON public.q_events
            FOR EACH ROW
            EXECUTE FUNCTION runtime.notify_on_event_enqueue();
        RAISE NOTICE 'Attached notify trigger to public.q_events';

    -- Attempt 2: schema-qualified install (pgmq.q_events)
    ELSIF to_regclass('pgmq.q_events') IS NOT NULL THEN
        DROP TRIGGER IF EXISTS trg_runtime_events_notify ON pgmq.q_events;
        CREATE TRIGGER trg_runtime_events_notify
            AFTER INSERT ON pgmq.q_events
            FOR EACH ROW
            EXECUTE FUNCTION runtime.notify_on_event_enqueue();
        RAISE NOTICE 'Attached notify trigger to pgmq.q_events';

    ELSE
        RAISE WARNING
          'Could not locate q_events table. '
          'Run runtime/03_notify.sql AFTER pgmq.create(''events'') has been called.';
    END IF;
END;
$$;

-- ── Convenience view: pending event count ────────────────────────────────────
-- Shows how many messages are currently visible (not hidden by a VT window).
-- Useful for monitoring dashboards and alerting.

CREATE OR REPLACE VIEW runtime.queue_depth AS
SELECT
    queue_name,
    queue_visible_length AS msg_count,
    newest_msg_age_sec,
    oldest_msg_age_sec,
    total_messages
FROM pgmq.metrics_all()
WHERE queue_name IN ('events', 'events_dlq');

COMMENT ON VIEW runtime.queue_depth IS
  'Live queue depth and age metrics for events and events_dlq.';
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
-- =============================================================================
-- runtime/05_dlq.sql
-- Dead-letter queue management: replay, inspect, purge.
--
-- Functions:
--   runtime.dlq_pending(limit INT)          → SETOF pgmq.message_record
--   runtime.dlq_replay(dlq_msg_id BIGINT)   → BIGINT (new msg_id in events)
--   runtime.dlq_discard(dlq_msg_id BIGINT)  → VOID
--   runtime.dlq_replay_all()                → INT    (count replayed)
--   runtime.dlq_reap_expired(older_than INTERVAL) → INT (count purged)
--
-- Run after 04_advisory.sql.
-- =============================================================================

-- ── dlq_pending ──────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION runtime.dlq_pending(
    p_limit INT DEFAULT 50,
    p_vt    INT DEFAULT 0      -- 0 = read without hiding (inspect only)
)
RETURNS SETOF pgmq.message_record
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = runtime, public
AS $$
BEGIN
    RETURN QUERY
        SELECT * FROM pgmq.read('events_dlq', p_vt, p_limit);
END;
$$;

COMMENT ON FUNCTION runtime.dlq_pending(INT, INT) IS
  'List up to p_limit messages currently sitting in the dead-letter queue. '
  'Pass p_vt > 0 to claim them (hide from other readers).';

-- ── dlq_replay ───────────────────────────────────────────────────────────────
-- Move a single DLQ message back to the main events queue for reprocessing.
-- Resets the attempt counter so the full p_max_tries budget is available.

CREATE OR REPLACE FUNCTION runtime.dlq_replay(
    p_dlq_msg_id BIGINT
)
RETURNS BIGINT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = runtime, public
AS $$
DECLARE
    v_payload    JSONB;
    v_new_msg_id BIGINT;
BEGIN
    -- Read payload directly from the pgmq internal DLQ table.
    -- pgmq stores 'events_dlq' in pgmq.q_events_dlq or public.q_events_dlq
    -- depending on the install layout. Try both defensively.
    BEGIN
        EXECUTE '
            SELECT message FROM pgmq.q_events_dlq WHERE msg_id = $1
        ' INTO v_payload USING p_dlq_msg_id;
    EXCEPTION WHEN undefined_table THEN
        BEGIN
            EXECUTE '
                SELECT message FROM public.q_events_dlq WHERE msg_id = $1
            ' INTO v_payload USING p_dlq_msg_id;
        EXCEPTION WHEN undefined_table THEN
            v_payload := NULL;
        END;
    END;

    IF v_payload IS NULL THEN
        RAISE EXCEPTION 'DLQ message % not found in events_dlq', p_dlq_msg_id;
    END IF;

    -- Re-enqueue via the wrapper (resets retry counter + triggers NOTIFY).
    v_new_msg_id := runtime.enqueue_event(v_payload);

    -- Delete from DLQ queue using the DLQ msg_id.
    PERFORM pgmq.delete('events_dlq', p_dlq_msg_id);

    -- Mark audit row as replayed.
    -- We set replayed_at instead of nulling dead_at:
    --   dead_at is NOT NULL (records when the message died — immutable fact).
    --   replayed_at is nullable and records when it was re-enqueued.
    UPDATE runtime.dead_letter_audit
    SET    replayed_at = NOW()
    WHERE  dlq_msg_id  = p_dlq_msg_id
      AND  replayed_at IS NULL;

    RAISE NOTICE 'runtime.dlq_replay: dlq_msg_id=% re-enqueued as events msg_id=%',
        p_dlq_msg_id, v_new_msg_id;

    RETURN v_new_msg_id;
END;
$$;

COMMENT ON FUNCTION runtime.dlq_replay(BIGINT) IS
  'Move a single dead-letter message back to the events queue. '
  'Resets the retry counter. Returns the new msg_id.';

-- ── dlq_discard ──────────────────────────────────────────────────────────────
-- Permanently delete a DLQ message that cannot or should not be replayed.

CREATE OR REPLACE FUNCTION runtime.dlq_discard(
    p_dlq_msg_id BIGINT
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = runtime, public
AS $$
BEGIN
    -- p_dlq_msg_id is the msg_id in the events_dlq queue (= dead_letter_audit.dlq_msg_id).
    PERFORM pgmq.delete('events_dlq', p_dlq_msg_id);
    -- Keep the audit row but mark it discarded and no longer active.
    UPDATE runtime.dead_letter_audit
    SET    last_error = COALESCE(last_error, '') || ' [DISCARDED]',
           replayed_at = NOW()
    WHERE  dlq_msg_id = p_dlq_msg_id;
END;
$$;

COMMENT ON FUNCTION runtime.dlq_discard(BIGINT) IS
  'Permanently remove a DLQ message. Audit row is retained but marked [DISCARDED].';

-- ── dlq_replay_all ────────────────────────────────────────────────────────────
-- Replay every message currently in the DLQ.
-- Acquires the dlq-reaper advisory lock (key=3) so only one replica runs this.

CREATE OR REPLACE FUNCTION runtime.dlq_replay_all()
RETURNS INT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = runtime, public
AS $$
DECLARE
    v_locked  BOOLEAN;
    v_msg     pgmq.message_record;
    v_count   INT := 0;
BEGIN
    -- Acquire advisory lock to prevent concurrent replay runs.
    v_locked := runtime.advisory_try_lock(3);
    IF NOT v_locked THEN
        RAISE NOTICE 'runtime.dlq_replay_all: another session holds the DLQ reaper lock; skipping.';
        RETURN 0;
    END IF;

    BEGIN
        FOR v_msg IN
            SELECT * FROM pgmq.read('events_dlq', 60, 1000)
        LOOP
            -- Re-enqueue and delete from DLQ.
            PERFORM runtime.enqueue_event(v_msg.message);
            PERFORM pgmq.delete('events_dlq', v_msg.msg_id);

            -- Update audit row so ops queries no longer see this as an active dead letter.
            UPDATE runtime.dead_letter_audit
            SET    replayed_at = NOW()
            WHERE  dlq_msg_id  = v_msg.msg_id
              AND  replayed_at IS NULL;

            v_count := v_count + 1;
        END LOOP;
    EXCEPTION WHEN OTHERS THEN
        PERFORM runtime.advisory_unlock(3);
        RAISE;
    END;

    PERFORM runtime.advisory_unlock(3);
    RAISE NOTICE 'runtime.dlq_replay_all: replayed % messages', v_count;
    RETURN v_count;
END;
$$;

COMMENT ON FUNCTION runtime.dlq_replay_all() IS
  'Replay every pending DLQ message back to the events queue. '
  'Protected by advisory lock key=3 (dlq-reaper). Returns count replayed.';

-- ── dlq_reap_expired ─────────────────────────────────────────────────────────
-- Purge DLQ audit rows (and their matching DLQ queue messages) that are older
-- than the given interval. Useful for scheduled cleanup jobs.

CREATE OR REPLACE FUNCTION runtime.dlq_reap_expired(
    p_older_than INTERVAL DEFAULT INTERVAL '30 days'
)
RETURNS INT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = runtime, public
AS $$
DECLARE
    v_row    runtime.dead_letter_audit;
    v_count  INT := 0;
BEGIN
    FOR v_row IN
        SELECT *
        FROM   runtime.dead_letter_audit
        WHERE  dead_at < NOW() - p_older_than
    LOOP
        -- For un-replayed rows, also remove the message from the DLQ queue.
        -- Replayed rows have already had their DLQ entry deleted by dlq_replay;
        -- attempting pgmq.delete again is harmless but unnecessary.
        IF v_row.replayed_at IS NULL AND v_row.dlq_msg_id IS NOT NULL THEN
            BEGIN
                PERFORM pgmq.delete('events_dlq', v_row.dlq_msg_id);
            EXCEPTION WHEN OTHERS THEN
                NULL;  -- message may already be gone; continue
            END;
        END IF;

        DELETE FROM runtime.dead_letter_audit WHERE id = v_row.id;
        v_count := v_count + 1;
    END LOOP;

    RETURN v_count;
END;
$$;

COMMENT ON FUNCTION runtime.dlq_reap_expired(INTERVAL) IS
  'Purge DLQ audit rows and queue entries older than p_older_than. '
  'Safe to run as a cron job. Returns the number of records deleted.';
-- =============================================================================
-- runtime/06_cache_schema.sql
-- UNLOGGED cache + session tables and the pg_cron extension.
--
-- Purpose:
--   • runtime.cache   — generic TTL key/value store for future callers that
--                       need a shared, crash-truncated cache. NOT a drop-in
--                       replacement for the proxy's whales/prices caches:
--                       those live in sync.RWMutex-guarded memory in
--                       proxy/main.go today, and moving them into Postgres
--                       is out of scope for #18.
--   • runtime.session — replaces the proxy's only current Redis use, the
--                       `session:{sid}` KV written by /state (see
--                       proxy/main.go handleGetState / handlePostState).
--
-- UNLOGGED is deliberate — cache rows should disappear on crash (same
-- semantics as Redis without AOF). Durable rows belong elsewhere.
--
-- Run once as a superuser (or a role with CREATE EXTENSION privilege):
--   psql $DATABASE_URL -f runtime/06_cache_schema.sql
--
-- Idempotent: safe to re-run on upgrades.
-- =============================================================================

-- ── Schema ────────────────────────────────────────────────────────────────────
-- Idempotent; shared with the queue bootstrap (01_schema.sql).
CREATE SCHEMA IF NOT EXISTS runtime;

-- ── pg_cron extension ─────────────────────────────────────────────────────────
-- Required by 08_cron.sql. The extension must be preloaded via
--   shared_preload_libraries = 'pg_cron,pgmq'
-- in postgresql.conf (see ADR §9). CREATE EXTENSION only registers it.
CREATE EXTENSION IF NOT EXISTS pg_cron;

-- ── runtime.cache ─────────────────────────────────────────────────────────────
-- Generic TTL key/value store. Reads filter on expires_at so stale rows are
-- invisible even before runtime.cache_reap() runs.
CREATE UNLOGGED TABLE IF NOT EXISTS runtime.cache (
    key        TEXT        PRIMARY KEY,
    value      JSONB       NOT NULL,
    expires_at TIMESTAMPTZ NOT NULL,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_cache_expires_at
    ON runtime.cache (expires_at);

COMMENT ON TABLE runtime.cache IS
  'UNLOGGED key/value cache with per-row TTL. Crash-truncated by design.';

-- ── runtime.session ───────────────────────────────────────────────────────────
-- Proxy session state — replaces Redis session:{sid} keys.
-- UNLOGGED mirrors today's behaviour (sessions die on node restart). Promote
-- to LOGGED later if session durability becomes a requirement.
CREATE UNLOGGED TABLE IF NOT EXISTS runtime.session (
    sid        TEXT        PRIMARY KEY,
    data       JSONB       NOT NULL,
    expires_at TIMESTAMPTZ NOT NULL,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_session_expires_at
    ON runtime.session (expires_at);

COMMENT ON TABLE runtime.session IS
  'UNLOGGED session KV. Replaces Redis session:{sid}. Crash-truncated.';
-- =============================================================================
-- runtime/07_cache_wrappers.sql
-- High-level PL/pgSQL wrappers around runtime.cache and runtime.session.
--
-- Functions:
--   runtime.cache_set   (key, value, ttl)   → VOID
--   runtime.cache_get   (key)               → JSONB   (NULL if missing/expired)
--   runtime.cache_delete(key)               → BOOLEAN (true on hit)
--   runtime.cache_reap  ()                  → INT     (rows deleted)
--
--   runtime.session_set   (sid, data, ttl)  → VOID
--   runtime.session_get   (sid)             → JSONB
--   runtime.session_delete(sid)             → BOOLEAN
--   runtime.session_reap  ()                → INT
--
-- All wrappers are SECURITY DEFINER so application roles only need EXECUTE on
-- the wrapper, not direct access to the underlying tables.
--
-- Run after 06_cache_schema.sql.
-- =============================================================================

-- ── cache_set ────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION runtime.cache_set(
    p_key   TEXT,
    p_value JSONB,
    p_ttl   INTERVAL
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = runtime, public
AS $$
BEGIN
    INSERT INTO runtime.cache (key, value, expires_at, updated_at)
    VALUES (p_key, p_value, NOW() + p_ttl, NOW())
    ON CONFLICT (key) DO UPDATE
        SET value      = EXCLUDED.value,
            expires_at = EXCLUDED.expires_at,
            updated_at = EXCLUDED.updated_at;
END;
$$;

COMMENT ON FUNCTION runtime.cache_set(TEXT, JSONB, INTERVAL) IS
  'UPSERT a cache entry with a relative TTL (INTERVAL).';

-- ── cache_get ────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION runtime.cache_get(
    p_key TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = runtime, public
AS $$
DECLARE
    v_value JSONB;
BEGIN
    -- Filter on expires_at so expired rows are invisible even before the
    -- reaper deletes them physically.
    SELECT value
    INTO   v_value
    FROM   runtime.cache
    WHERE  key        = p_key
      AND  expires_at > NOW();

    RETURN v_value;
END;
$$;

COMMENT ON FUNCTION runtime.cache_get(TEXT) IS
  'Return cache value or NULL if missing or past expires_at.';

-- ── cache_delete ─────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION runtime.cache_delete(
    p_key TEXT
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = runtime, public
AS $$
DECLARE
    v_rows INT;
BEGIN
    DELETE FROM runtime.cache WHERE key = p_key;
    GET DIAGNOSTICS v_rows = ROW_COUNT;
    RETURN v_rows > 0;
END;
$$;

COMMENT ON FUNCTION runtime.cache_delete(TEXT) IS
  'Remove a cache entry. Returns true if a row was deleted, false otherwise.';

-- ── cache_reap ───────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION runtime.cache_reap()
RETURNS INT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = runtime, public
AS $$
DECLARE
    v_rows INT;
BEGIN
    -- Use <= to match cache_get's strict `expires_at > NOW()`: a row with
    -- expires_at exactly equal to NOW() is invisible to readers and should
    -- be reaped in the same tick.
    DELETE FROM runtime.cache WHERE expires_at <= NOW();
    GET DIAGNOSTICS v_rows = ROW_COUNT;
    RETURN v_rows;
END;
$$;

COMMENT ON FUNCTION runtime.cache_reap() IS
  'Delete expired rows from runtime.cache. Scheduled by 08_cron.sql.';

-- ── session_set ──────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION runtime.session_set(
    p_sid  TEXT,
    p_data JSONB,
    p_ttl  INTERVAL
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = runtime, public
AS $$
BEGIN
    INSERT INTO runtime.session (sid, data, expires_at, updated_at)
    VALUES (p_sid, p_data, NOW() + p_ttl, NOW())
    ON CONFLICT (sid) DO UPDATE
        SET data       = EXCLUDED.data,
            expires_at = EXCLUDED.expires_at,
            updated_at = EXCLUDED.updated_at;
END;
$$;

COMMENT ON FUNCTION runtime.session_set(TEXT, JSONB, INTERVAL) IS
  'UPSERT a session row with a relative TTL (INTERVAL).';

-- ── session_get ──────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION runtime.session_get(
    p_sid TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = runtime, public
AS $$
DECLARE
    v_data JSONB;
BEGIN
    SELECT data
    INTO   v_data
    FROM   runtime.session
    WHERE  sid        = p_sid
      AND  expires_at > NOW();

    RETURN v_data;
END;
$$;

COMMENT ON FUNCTION runtime.session_get(TEXT) IS
  'Return session data or NULL if missing or past expires_at.';

-- ── session_delete ───────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION runtime.session_delete(
    p_sid TEXT
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = runtime, public
AS $$
DECLARE
    v_rows INT;
BEGIN
    DELETE FROM runtime.session WHERE sid = p_sid;
    GET DIAGNOSTICS v_rows = ROW_COUNT;
    RETURN v_rows > 0;
END;
$$;

COMMENT ON FUNCTION runtime.session_delete(TEXT) IS
  'Remove a session row. Returns true if a row was deleted, false otherwise.';

-- ── session_reap ─────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION runtime.session_reap()
RETURNS INT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = runtime, public
AS $$
DECLARE
    v_rows INT;
BEGIN
    DELETE FROM runtime.session WHERE expires_at <= NOW();
    GET DIAGNOSTICS v_rows = ROW_COUNT;
    RETURN v_rows;
END;
$$;

COMMENT ON FUNCTION runtime.session_reap() IS
  'Delete expired rows from runtime.session. Scheduled by 08_cron.sql.';

-- ── Privilege hardening ──────────────────────────────────────────────────────
-- SECURITY DEFINER means these functions run with the owner's rights, so we
-- must not leave the default `GRANT EXECUTE … TO PUBLIC` in place — any role
-- with CONNECT on this DB could otherwise invoke session_delete / cache_set
-- etc. as the owner.
--
-- `runtime.app_role` is a GUC the caller sets before running this file, e.g.
--   psql -v ON_ERROR_STOP=1 \
--        -c "SET runtime.app_role = 'cognitor_app'" \
--        -f runtime/07_cache_wrappers.sql
-- or persistently via `ALTER DATABASE <db> SET runtime.app_role = '<role>';`.
-- If unset, the DO block short-circuits and only the REVOKE runs (fail-closed
-- default; grant explicitly later).
REVOKE EXECUTE ON FUNCTION
    runtime.cache_set   (TEXT, JSONB, INTERVAL),
    runtime.cache_get   (TEXT),
    runtime.cache_delete(TEXT),
    runtime.cache_reap  (),
    runtime.session_set   (TEXT, JSONB, INTERVAL),
    runtime.session_get   (TEXT),
    runtime.session_delete(TEXT),
    runtime.session_reap  ()
FROM PUBLIC;

DO $$
DECLARE
    v_role TEXT := current_setting('runtime.app_role', true);
BEGIN
    IF v_role IS NULL OR v_role = '' THEN
        RAISE NOTICE
          'runtime.app_role not set — skipping GRANT EXECUTE. '
          'Re-run with: SET runtime.app_role = ''<role>''; '
          '\i runtime/07_cache_wrappers.sql (or set persistently via '
          'ALTER DATABASE <db> SET runtime.app_role = ''<role>'';).';
        RETURN;
    END IF;

    EXECUTE format(
      'GRANT EXECUTE ON FUNCTION '
      'runtime.cache_set(TEXT, JSONB, INTERVAL), '
      'runtime.cache_get(TEXT), '
      'runtime.cache_delete(TEXT), '
      'runtime.cache_reap(), '
      'runtime.session_set(TEXT, JSONB, INTERVAL), '
      'runtime.session_get(TEXT), '
      'runtime.session_delete(TEXT), '
      'runtime.session_reap() '
      'TO %I', v_role);
END;
$$;
-- =============================================================================
-- runtime/08_cron.sql
-- pg_cron schedules for the runtime layer.
--
-- Jobs:
--   runtime-cache-reap    — every minute
--   runtime-session-reap  — every 5 minutes
--   runtime-dlq-reap      — daily at 03:00 UTC
--
-- Idempotent: each job is unscheduled (if present) before being rescheduled,
-- so re-running this file never duplicates jobs.
--
-- Database targeting: pg_cron runs a single launcher bgworker that binds to
-- the database named by `cron.database_name` (default: 'postgres'). The
-- extension, and therefore `cron.job`, must live in that database — nothing
-- fires otherwise. `cron.schedule_in_database(..., current_database())` only
-- pins the *execution* DB of each job body; it does NOT remove the need to
-- point the launcher at the DB where pg_cron is installed. In this project
-- that DB is `cognitor`, so `cron.database_name = 'cognitor'` is required,
-- not optional. See docs/runtime.md for the full postgresql.conf block.
--
-- Ordering note: runtime-dlq-reap references runtime.dlq_reap_expired(), which
-- is defined in 05_dlq.sql (queue branch). pg_cron stores the command body as
-- text and does not resolve it at schedule time, so this script still succeeds
-- when the queue files have not been loaded yet — but the first 03:00 run
-- would fail. Load 05_dlq.sql before relying on this schedule in a merged
-- deployment.
--
-- Run after 07_cache_wrappers.sql.
-- =============================================================================

-- ── runtime-cache-reap ───────────────────────────────────────────────────────
DO $$
BEGIN
    PERFORM cron.unschedule(jobid)
    FROM    cron.job
    WHERE   jobname = 'runtime-cache-reap';
END;
$$;

SELECT cron.schedule_in_database(
    'runtime-cache-reap',
    '* * * * *',
    $$SELECT runtime.cache_reap()$$,
    current_database()
);

-- ── runtime-session-reap ─────────────────────────────────────────────────────
DO $$
BEGIN
    PERFORM cron.unschedule(jobid)
    FROM    cron.job
    WHERE   jobname = 'runtime-session-reap';
END;
$$;

SELECT cron.schedule_in_database(
    'runtime-session-reap',
    '*/5 * * * *',
    $$SELECT runtime.session_reap()$$,
    current_database()
);

-- ── runtime-dlq-reap ─────────────────────────────────────────────────────────
-- Requires runtime.dlq_reap_expired() from 05_dlq.sql (queue branch).
DO $$
BEGIN
    PERFORM cron.unschedule(jobid)
    FROM    cron.job
    WHERE   jobname = 'runtime-dlq-reap';
END;
$$;

SELECT cron.schedule_in_database(
    'runtime-dlq-reap',
    '0 3 * * *',
    $$SELECT runtime.dlq_reap_expired('30 days')$$,
    current_database()
);
