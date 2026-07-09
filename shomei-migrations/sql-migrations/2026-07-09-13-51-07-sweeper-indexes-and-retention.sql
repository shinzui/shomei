-- codd: in-txn

SET search_path TO shomei, pg_catalog;

-- Sweep-supporting indexes (EP-2 of the operational-hardening MasterPlan,
-- docs/plans/34-expired-data-sweeper-retention-windows-and-supporting-indexes.md).
-- The background sweeper deletes by expiry cutoffs; without these it would seq-scan the
-- very tables it exists to keep small.

-- Sessions are swept on "dead past a grace period", which is
--   expires_at <= cutoff OR (status = 'revoked' AND revoked_at <= cutoff)
-- A single index cannot serve an OR, so index each branch and let the planner BitmapOr
-- them. The revoked branch is partial because only revoked rows carry a revoked_at.
CREATE INDEX IF NOT EXISTS shomei_sessions_expires_at_idx
  ON shomei_sessions (expires_at);
CREATE INDEX IF NOT EXISTS shomei_sessions_revoked_at_idx
  ON shomei_sessions (revoked_at)
  WHERE status = 'revoked';

CREATE INDEX IF NOT EXISTS shomei_email_verification_tokens_expires_at_idx
  ON shomei_email_verification_tokens (expires_at);
CREATE INDEX IF NOT EXISTS shomei_password_reset_tokens_expires_at_idx
  ON shomei_password_reset_tokens (expires_at);

-- The login-attempt sweep predicate is age-only (occurred_at <= cutoff), which the existing
-- partial indexes cannot serve: they lead on account_key / client_ip.
CREATE INDEX IF NOT EXISTS shomei_login_attempts_occurred_at_idx
  ON shomei_login_attempts (occurred_at);

-- Audit keyset pagination: ORDER BY created_at DESC, event_id DESC with a
-- (created_at, event_id) < ($cursor) row-comparison predicate wants exactly this composite.
-- It also serves the auth-event retention sweep's created_at <= cutoff range predicate.
CREATE INDEX IF NOT EXISTS shomei_auth_events_created_event_idx
  ON shomei_auth_events (created_at DESC, event_id DESC);

-- Dead single-column status indexes: each status column holds 3-4 distinct values and no
-- query filters by status alone (every status predicate in shomei-postgres/src is paired
-- with an id equality that a primary-key, unique, or foreign-key index already serves).
-- They are pure write amplification on the hottest write paths.
DROP INDEX IF EXISTS shomei_sessions_status_idx;
DROP INDEX IF EXISTS shomei_refresh_tokens_status_idx;
DROP INDEX IF EXISTS shomei_email_verification_tokens_status_idx;
DROP INDEX IF EXISTS shomei_password_reset_tokens_status_idx;

-- Superseded by shomei_auth_events_created_event_idx, whose leading column is created_at.
DROP INDEX IF EXISTS shomei_auth_events_created_at_idx;
