-- =============================================================================
-- runtime/tests/test_runtime.sql
-- Smoke tests / acceptance criteria for the runtime schema.
--
-- Run against a live PostgreSQL instance with the runtime schema applied:
--   psql $DATABASE_URL -f runtime/tests/test_runtime.sql
--
-- Each test uses a DO block that raises EXCEPTION on failure and NOTICE on pass.
-- =============================================================================

\echo '=== runtime queue acceptance tests ==='
-- ── Test 1: enqueue_event returns a msg_id ───────────────────────────────────
DO $$
DECLARE
    v_id BIGINT;
BEGIN
    SELECT runtime.enqueue_event('{"type":"market","slug":"test-1","yes_price":0.5}'::JSONB)
    INTO   v_id;

    IF v_id IS NULL OR v_id <= 0 THEN
        RAISE EXCEPTION 'FAIL test1: enqueue_event returned invalid msg_id: %', v_id;
    END IF;

    RAISE NOTICE 'PASS test1: enqueue_event → msg_id=%', v_id;
END;
$$;

-- ── Test 2: claim_events returns the enqueued message ────────────────────────
DO $$
DECLARE
    v_enqueue_id BIGINT;
    v_found_msg  JSONB;
    v_rec        RECORD;
BEGIN
    SELECT runtime.enqueue_event('{"type":"market","slug":"test-2","yes_price":0.6}'::JSONB)
    INTO   v_enqueue_id;

    -- Claim a batch (not just 1) in case other messages are already in the queue.
    -- Search for our specific msg_id among the claimed messages.
    FOR v_rec IN
        SELECT * FROM runtime.claim_events(50, 30)
    LOOP
        IF v_rec.msg_id = v_enqueue_id THEN
            v_found_msg := v_rec.message;
        ELSE
            -- Release all other messages we claimed (reset vt to 0).
            PERFORM pgmq.set_vt('events', v_rec.msg_id, 0);
        END IF;
    END LOOP;

    IF v_found_msg IS NULL THEN
        RAISE EXCEPTION 'FAIL test2: claim_events did not return enqueued msg_id=%', v_enqueue_id;
    END IF;

    IF (v_found_msg->>'slug') <> 'test-2' THEN
        RAISE EXCEPTION 'FAIL test2: payload slug mismatch, got %', v_found_msg->>'slug';
    END IF;

    -- cleanup
    PERFORM runtime.ack_event(v_enqueue_id);

    RAISE NOTICE 'PASS test2: claim_events returned msg_id=% with correct payload', v_enqueue_id;
END;
$$;

-- ── Test 3: ack_event removes message from queue ─────────────────────────────
DO $$
DECLARE
    v_id   BIGINT;
    v_rec  RECORD;
BEGIN
    SELECT runtime.enqueue_event('{"type":"market","slug":"test-3","yes_price":0.7}'::JSONB)
    INTO   v_id;

    -- Claim then ack. Use a loop to cleanly handle any other messages in queue.
    FOR v_rec IN 
        SELECT * FROM runtime.claim_events(50, 5)
    LOOP
        IF v_rec.msg_id <> v_id THEN
            PERFORM pgmq.set_vt('events', v_rec.msg_id, 0);
        END IF;
    END LOOP;
    
    PERFORM runtime.ack_event(v_id);

    -- Retry state should be gone.
    IF EXISTS (SELECT 1 FROM runtime.event_retry WHERE msg_id = v_id) THEN
        RAISE EXCEPTION 'FAIL test3: retry row still exists after ack for msg_id=%', v_id;
    END IF;

    RAISE NOTICE 'PASS test3: ack_event removed msg_id=% and its retry row', v_id;
END;
$$;

-- ── Test 4: fail_event increments retry counter ───────────────────────────────
DO $$
DECLARE
    v_id      BIGINT;
    v_count   INT;
BEGIN
    SELECT runtime.enqueue_event('{"type":"market","slug":"test-4","yes_price":0.4}'::JSONB)
    INTO   v_id;

    -- First failure
    PERFORM runtime.fail_event(v_id, 'simulated error', 3);

    SELECT attempt_count INTO v_count
    FROM   runtime.event_retry
    WHERE  msg_id = v_id;

    IF v_count <> 1 THEN
        RAISE EXCEPTION 'FAIL test4: expected attempt_count=1, got %', v_count;
    END IF;

    -- Cleanup (ack so the message doesn't linger)
    PERFORM pgmq.delete('events', v_id);
    DELETE FROM runtime.event_retry WHERE msg_id = v_id;

    RAISE NOTICE 'PASS test4: fail_event incremented attempt_count to 1 for msg_id=%', v_id;
END;
$$;

-- ── Test 5: fail_event promotes to DLQ after MAX_RETRIES ─────────────────────
DO $$
DECLARE
    v_id        BIGINT;
    v_audit_row runtime.dead_letter_audit;
BEGIN
    SELECT runtime.enqueue_event('{"type":"poison","slug":"test-5","yes_price":0.0}'::JSONB)
    INTO   v_id;

    -- Exhaust retries (max_tries = 2 for this test)
    PERFORM runtime.fail_event(v_id, 'err1', 2);
    PERFORM runtime.fail_event(v_id, 'err2', 2);

    -- Retry row should be gone from event_retry
    IF EXISTS (SELECT 1 FROM runtime.event_retry WHERE msg_id = v_id) THEN
        RAISE EXCEPTION 'FAIL test5: retry row still present after DLQ promotion';
    END IF;

    -- Audit row must exist with dlq_msg_id populated
    SELECT * INTO v_audit_row
    FROM   runtime.dead_letter_audit
    WHERE  original_msg_id = v_id;

    IF v_audit_row IS NULL THEN
        RAISE EXCEPTION 'FAIL test5: no audit row written for DLQ promotion';
    END IF;

    IF v_audit_row.dlq_msg_id IS NULL THEN
        RAISE EXCEPTION 'FAIL test5: dlq_msg_id is NULL — pgmq.send return not captured';
    END IF;

    -- dead_at must still be NOT NULL (it is declared NOT NULL in schema)
    IF v_audit_row.dead_at IS NULL THEN
        RAISE EXCEPTION 'FAIL test5: dead_at is NULL — NOT NULL constraint violated';
    END IF;

    -- replayed_at must be NULL at this point (message not yet replayed)
    IF v_audit_row.replayed_at IS NOT NULL THEN
        RAISE EXCEPTION 'FAIL test5: replayed_at is unexpectedly set before replay';
    END IF;

    RAISE NOTICE 'PASS test5: msg_id=% promoted to DLQ; dlq_msg_id=%; dead_at set; replayed_at NULL',
        v_id, v_audit_row.dlq_msg_id;

    -- Cleanup: use dlq_msg_id to delete from DLQ queue
    PERFORM pgmq.delete('events_dlq', v_audit_row.dlq_msg_id);
    DELETE FROM runtime.dead_letter_audit WHERE original_msg_id = v_id;
END;
$$;

-- ── Test 7: dlq_replay sets replayed_at and does not null dead_at ────────────
DO $$
DECLARE
    v_id             BIGINT;
    v_dlq_msg_id     BIGINT;
    v_audit_row      runtime.dead_letter_audit;
    v_replayed_msg   BIGINT;
BEGIN
    -- Promote to DLQ (2 failures with max_tries=2)
    SELECT runtime.enqueue_event('{"type":"market","slug":"test-7-replay","yes_price":0.1}'::JSONB)
    INTO   v_id;
    PERFORM runtime.fail_event(v_id, 'err-replay-1', 2);
    PERFORM runtime.fail_event(v_id, 'err-replay-2', 2);

    SELECT dlq_msg_id INTO v_dlq_msg_id
    FROM   runtime.dead_letter_audit
    WHERE  original_msg_id = v_id;

    IF v_dlq_msg_id IS NULL THEN
        RAISE EXCEPTION 'FAIL test7: dlq_msg_id not set, cannot test replay';
    END IF;

    -- Replay the DLQ message
    SELECT runtime.dlq_replay(v_dlq_msg_id) INTO v_replayed_msg;

    -- replayed_at must now be set
    SELECT * INTO v_audit_row
    FROM   runtime.dead_letter_audit
    WHERE  original_msg_id = v_id;

    IF v_audit_row.replayed_at IS NULL THEN
        RAISE EXCEPTION 'FAIL test7: replayed_at is still NULL after dlq_replay';
    END IF;

    -- dead_at must still be NOT NULL (this was the P1 bug: SET dead_at = NULL would fail here)
    IF v_audit_row.dead_at IS NULL THEN
        RAISE EXCEPTION 'FAIL test7: dead_at became NULL after replay — NOT NULL constraint violated';
    END IF;

    -- The replayed message must now be visible in the events queue
    IF v_replayed_msg IS NULL OR v_replayed_msg <= 0 THEN
        RAISE EXCEPTION 'FAIL test7: dlq_replay returned invalid new msg_id: %', v_replayed_msg;
    END IF;

    RAISE NOTICE 'PASS test7: dlq_replay set replayed_at=%; dead_at preserved; new events msg_id=%',
        v_audit_row.replayed_at, v_replayed_msg;

    -- Cleanup
    PERFORM pgmq.delete('events', v_replayed_msg);
    DELETE FROM runtime.dead_letter_audit WHERE original_msg_id = v_id;
END;
$$;

-- ── Test 6: advisory_try_lock / advisory_unlock ───────────────────────────────
DO $$
DECLARE
    v_got   BOOLEAN;
    v_rel   BOOLEAN;
BEGIN
    v_got := runtime.advisory_try_lock(99);
    IF NOT v_got THEN
        RAISE EXCEPTION 'FAIL test6: advisory_try_lock(99) returned false on first call';
    END IF;

    v_rel := runtime.advisory_unlock(99);
    IF NOT v_rel THEN
        RAISE EXCEPTION 'FAIL test6: advisory_unlock(99) returned false';
    END IF;

    RAISE NOTICE 'PASS test6: advisory_try_lock + advisory_unlock work correctly';
END;
$$;

\echo '=== runtime cache/session acceptance tests ==='

-- ── Test 8: cache_set + cache_get round-trip ────────────────────────────────
DO $$
DECLARE
    v_got JSONB;
BEGIN
    PERFORM runtime.cache_set('t1', '{"x":1}'::JSONB, '1 hour');
    SELECT runtime.cache_get('t1') INTO v_got;

    IF v_got IS NULL OR v_got <> '{"x":1}'::JSONB THEN
        RAISE EXCEPTION 'FAIL test8: cache_get returned %, want {"x":1}', v_got;
    END IF;

    RAISE NOTICE 'PASS test8: cache_set + cache_get round-trip';
END;
$$;

-- ── Test 9: cache_delete hit/miss semantics ─────────────────────────────────
DO $$
DECLARE
    v_hit  BOOLEAN;
    v_miss BOOLEAN;
BEGIN
    v_hit  := runtime.cache_delete('t1');
    v_miss := runtime.cache_delete('t1');

    IF v_hit IS NOT TRUE THEN
        RAISE EXCEPTION 'FAIL test9: delete on existing key returned %, want true', v_hit;
    END IF;

    IF v_miss IS NOT FALSE THEN
        RAISE EXCEPTION 'FAIL test9: delete on absent key returned %, want false', v_miss;
    END IF;

    RAISE NOTICE 'PASS test9: cache_delete hit=true / miss=false';
END;
$$;

-- ── Test 10: cache_get filters expired rows pre-reap ────────────────────────
DO $$
DECLARE
    v_got JSONB;
BEGIN
    PERFORM runtime.cache_set('t3', '{"x":3}'::JSONB, '10 milliseconds');
    PERFORM pg_sleep(0.05);

    SELECT runtime.cache_get('t3') INTO v_got;
    IF v_got IS NOT NULL THEN
        RAISE EXCEPTION 'FAIL test10: cache_get returned % for expired row, want NULL', v_got;
    END IF;

    -- Row is still physically present — reap lives in test 11.
    IF (SELECT COUNT(*) FROM runtime.cache WHERE key = 't3') <> 1 THEN
        RAISE EXCEPTION 'FAIL test10: expired row missing from physical storage';
    END IF;

    RAISE NOTICE 'PASS test10: cache_get hides rows past expires_at';
END;
$$;

-- ── Test 11: cache_reap removes expired rows ────────────────────────────────
DO $$
DECLARE
    v_reaped INT;
    v_left   INT;
BEGIN
    v_reaped := runtime.cache_reap();

    IF v_reaped < 1 THEN
        RAISE EXCEPTION 'FAIL test11: cache_reap returned %, want >= 1', v_reaped;
    END IF;

    SELECT COUNT(*) INTO v_left FROM runtime.cache WHERE key = 't3';
    IF v_left <> 0 THEN
        RAISE EXCEPTION 'FAIL test11: runtime.cache still has % row(s) for t3 after reap', v_left;
    END IF;

    RAISE NOTICE 'PASS test11: cache_reap deleted % expired row(s)', v_reaped;
END;
$$;

-- ── Test 12: session round-trip (set/get/delete) ────────────────────────────
DO $$
DECLARE
    v_got     JSONB;
    v_deleted BOOLEAN;
BEGIN
    PERFORM runtime.session_set('sid-abc', '{"uid":42}'::JSONB, '1 hour');

    SELECT runtime.session_get('sid-abc') INTO v_got;
    IF v_got IS NULL OR v_got <> '{"uid":42}'::JSONB THEN
        RAISE EXCEPTION 'FAIL test12: session_get returned %, want {"uid":42}', v_got;
    END IF;

    v_deleted := runtime.session_delete('sid-abc');
    IF v_deleted IS NOT TRUE THEN
        RAISE EXCEPTION 'FAIL test12: session_delete returned %, want true', v_deleted;
    END IF;

    RAISE NOTICE 'PASS test12: session_set + session_get + session_delete round-trip';
END;
$$;

-- ── Test 13: cache and session tables are UNLOGGED ──────────────────────────
DO $$
DECLARE
    v_cache_persistence   CHAR;
    v_session_persistence CHAR;
BEGIN
    -- relpersistence: 'u' = unlogged, 'p' = permanent, 't' = temp
    SELECT c.relpersistence
    INTO   v_cache_persistence
    FROM   pg_class     c
    JOIN   pg_namespace n ON n.oid = c.relnamespace
    WHERE  n.nspname = 'runtime' AND c.relname = 'cache';

    SELECT c.relpersistence
    INTO   v_session_persistence
    FROM   pg_class     c
    JOIN   pg_namespace n ON n.oid = c.relnamespace
    WHERE  n.nspname = 'runtime' AND c.relname = 'session';

    IF v_cache_persistence <> 'u' THEN
        RAISE EXCEPTION 'FAIL test13: runtime.cache relpersistence = %, want u (UNLOGGED)',
                        v_cache_persistence;
    END IF;

    IF v_session_persistence <> 'u' THEN
        RAISE EXCEPTION 'FAIL test13: runtime.session relpersistence = %, want u (UNLOGGED)',
                        v_session_persistence;
    END IF;

    RAISE NOTICE 'PASS test13: runtime.cache and runtime.session are UNLOGGED';
END;
$$;

-- ── Test 14: pg_cron jobs registered ────────────────────────────────────────
-- Expect 3 active runtime-* cron jobs after bootstrap:
-- runtime-cache-reap, runtime-session-reap, runtime-dlq-reap.
DO $$
DECLARE
    v_count INT;
BEGIN
    SELECT COUNT(*)
    INTO   v_count
    FROM   cron.job
    WHERE  jobname IN (
               'runtime-cache-reap',
               'runtime-session-reap',
               'runtime-dlq-reap'
           )
      AND  active;

    IF v_count < 3 THEN
        RAISE EXCEPTION 'FAIL test14: expected 3 active runtime-* cron jobs, got %', v_count;
    END IF;

    RAISE NOTICE 'PASS test14: % runtime-* cron jobs are scheduled and active', v_count;
END;
$$;

-- ── Test 15: runtime-cache-reap fires end-to-end ────────────────────────────
-- Test 14 only proves jobs are registered in cron.job. That is not enough:
-- pg_cron's launcher bgworker binds to `cron.database_name`, and if that GUC
-- points at a different DB from the one holding the `runtime` schema the jobs
-- are registered but never execute. This test inserts an already-expired
-- sentinel row and waits up to ~90s for the reaper to physically delete it,
-- which exercises the full launcher → scheduler → cache_reap() → DELETE path.
DO $$
DECLARE
    v_key       TEXT := '__smoke_reap_' || gen_random_uuid()::TEXT;
    v_deadline  TIMESTAMPTZ := clock_timestamp() + INTERVAL '90 seconds';
    v_gone      BOOLEAN := FALSE;
    v_elapsed   INTERVAL;
    v_started   TIMESTAMPTZ := clock_timestamp();
BEGIN
    INSERT INTO runtime.cache (key, value, expires_at)
    VALUES (v_key, '{"smoke":true}'::JSONB, NOW() - INTERVAL '1 minute');

    IF NOT EXISTS (SELECT 1 FROM runtime.cache WHERE key = v_key) THEN
        RAISE EXCEPTION 'FAIL test15: sentinel row % not present after INSERT', v_key;
    END IF;

    WHILE clock_timestamp() < v_deadline LOOP
        PERFORM pg_sleep(5);
        IF NOT EXISTS (SELECT 1 FROM runtime.cache WHERE key = v_key) THEN
            v_gone := TRUE;
            EXIT;
        END IF;
    END LOOP;

    v_elapsed := clock_timestamp() - v_started;

    IF NOT v_gone THEN
        -- Clean up before failing so a re-run of the suite is not polluted.
        DELETE FROM runtime.cache WHERE key = v_key;
        RAISE EXCEPTION
            'FAIL test15: runtime-cache-reap did not remove sentinel % within %; '
            'check that cron.database_name points at the DB holding the runtime schema',
            v_key, v_elapsed;
    END IF;

    RAISE NOTICE 'PASS test15: runtime-cache-reap fired end-to-end in %', v_elapsed;
END;
$$;

\echo '=== all tests passed ==='
