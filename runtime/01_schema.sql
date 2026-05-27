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
