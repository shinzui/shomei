-- Measured with 10000 expired rows and 10000 live rows on another principal.
SET LOCAL search_path = pg_catalog, pg_temp;

CREATE INDEX IF NOT EXISTS shomei_sessions_active_subject_idx
  ON shomei.shomei_sessions(user_id, expires_at)
  WHERE status = 'active' AND kind IN ('machine', 'delegated');
CREATE INDEX IF NOT EXISTS shomei_sessions_active_actor_idx
  ON shomei.shomei_sessions(actor_user_id, expires_at)
  WHERE status = 'active' AND kind IN ('machine', 'delegated');
