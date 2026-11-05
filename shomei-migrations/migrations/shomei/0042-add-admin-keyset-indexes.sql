-- add-admin-keyset-indexes

SET LOCAL search_path = pg_catalog, pg_temp;

-- 10k-user and 11k-event EXPLAIN evidence: docs/review-remediation/admin-query-plans.txt.
CREATE INDEX IF NOT EXISTS shomei_users_created_id_idx
  ON shomei.shomei_users (created_at DESC, user_id DESC);
CREATE INDEX IF NOT EXISTS shomei_users_status_created_id_idx
  ON shomei.shomei_users (status, created_at DESC, user_id DESC);
CREATE INDEX IF NOT EXISTS shomei_auth_events_user_created_id_idx
  ON shomei.shomei_auth_events (user_id, created_at DESC, event_id DESC);
