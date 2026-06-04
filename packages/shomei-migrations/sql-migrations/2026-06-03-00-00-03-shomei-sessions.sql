-- codd: in-txn

SET search_path TO shomei, pg_catalog;

CREATE TABLE IF NOT EXISTS shomei_sessions (
  session_id uuid PRIMARY KEY,
  user_id    uuid NOT NULL REFERENCES shomei_users(user_id),
  status     text NOT NULL,
  created_at timestamptz NOT NULL,
  expires_at timestamptz NOT NULL,
  revoked_at timestamptz NULL
);

CREATE INDEX IF NOT EXISTS shomei_sessions_user_id_idx ON shomei_sessions (user_id);
CREATE INDEX IF NOT EXISTS shomei_sessions_status_idx  ON shomei_sessions (status);
