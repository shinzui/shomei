-- Measured against 10000 per-user sessions: ordered LIMIT avoids a full scan + top-N sort.
SET LOCAL search_path = pg_catalog, pg_temp;

CREATE INDEX IF NOT EXISTS shomei_sessions_user_created_id_idx
  ON shomei.shomei_sessions(user_id, created_at DESC, session_id DESC);
