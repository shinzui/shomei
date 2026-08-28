SET LOCAL search_path = pg_catalog, pg_temp;

ALTER TABLE shomei.shomei_sessions
  ADD COLUMN IF NOT EXISTS actor_user_id uuid NULL REFERENCES shomei.shomei_users(user_id);

CREATE INDEX IF NOT EXISTS shomei_sessions_actor_user_id_idx
  ON shomei.shomei_sessions (actor_user_id);
