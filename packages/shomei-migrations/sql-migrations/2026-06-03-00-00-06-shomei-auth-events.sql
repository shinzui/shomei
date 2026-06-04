-- codd: in-txn

SET search_path TO shomei, pg_catalog;

CREATE TABLE IF NOT EXISTS shomei_auth_events (
  event_id   uuid PRIMARY KEY,
  user_id    uuid NULL,
  session_id uuid NULL,
  event_type text NOT NULL,
  payload    jsonb NOT NULL,
  created_at timestamptz NOT NULL
);

CREATE INDEX IF NOT EXISTS shomei_auth_events_user_id_idx    ON shomei_auth_events (user_id);
CREATE INDEX IF NOT EXISTS shomei_auth_events_session_id_idx ON shomei_auth_events (session_id);
CREATE INDEX IF NOT EXISTS shomei_auth_events_event_type_idx ON shomei_auth_events (event_type);
CREATE INDEX IF NOT EXISTS shomei_auth_events_created_at_idx ON shomei_auth_events (created_at);
