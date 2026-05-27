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
