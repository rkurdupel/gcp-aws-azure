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
