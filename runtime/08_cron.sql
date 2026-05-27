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
