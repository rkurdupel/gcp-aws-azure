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
