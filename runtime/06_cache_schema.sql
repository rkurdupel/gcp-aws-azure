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
