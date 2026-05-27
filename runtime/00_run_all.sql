-- =============================================================================
-- runtime/00_run_all.sql
-- Master bootstrap script. Runs all runtime SQL files in order.
-- Use this for a fresh install or after a clean wipe.
--
-- Usage:
--   psql $DATABASE_URL -f runtime/00_run_all.sql
--
-- Requirements:
--   • The executing role must have CREATE EXTENSION privilege, 
--     or pgmq and pg_cron must already be installed by a superuser.
--   • Run as a role that owns (or can create objects in) the target database.
--   • shared_preload_libraries must include 'pg_cron' in postgresql.conf.
--     With the current Tembo pg16-pgmq base, pgmq is created as an extension
--     and is not a preload library.
--   • cron.database_name in postgresql.conf must point at THIS database —
--     the pg_cron launcher bgworker binds to exactly one DB, so jobs
--     registered anywhere else are inert. See docs/runtime.md.
--   • Before running, set the application role via the GUC,
--     e.g. ALTER DATABASE <db> SET runtime.app_role = 'cognitor_app';
--     otherwise [7/8] runs the REVOKE, skips the GRANT, and the proxy will
--     get permission-denied at runtime.
-- =============================================================================

\echo '>>> [1/8] runtime schema + pgmq + tables'
\i runtime/01_schema.sql

\echo '>>> [2/8] queue wrappers (enqueue / claim / ack / fail)'
\i runtime/02_wrappers.sql

\echo '>>> [3/8] LISTEN/NOTIFY trigger + queue_depth view'
\i runtime/03_notify.sql

\echo '>>> [4/8] advisory lock helpers'
\i runtime/04_advisory.sql

\echo '>>> [5/8] DLQ management functions'
\i runtime/05_dlq.sql

\echo '>>> [6/8] cache/session schema + pg_cron extension'
\i runtime/06_cache_schema.sql

\echo '>>> [7/8] cache/session wrappers'
\i runtime/07_cache_wrappers.sql

\echo '>>> [8/8] pg_cron schedules'
\i runtime/08_cron.sql

\echo '>>> runtime bootstrap complete.'
\echo '    Verify with: SELECT * FROM runtime.queue_depth;'
\echo '    Verify with: SELECT jobname, schedule, active FROM cron.job WHERE jobname LIKE ''runtime-%'';'
