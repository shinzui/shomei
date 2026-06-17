-- codd: in-txn

SET search_path TO shomei, pg_catalog;

ALTER TABLE shomei_sessions
  ADD COLUMN IF NOT EXISTS actor_user_id uuid NULL REFERENCES shomei_users(user_id);

CREATE INDEX IF NOT EXISTS shomei_sessions_actor_user_id_idx
  ON shomei_sessions (actor_user_id);
