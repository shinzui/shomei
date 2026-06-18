-- codd: in-txn

SET search_path TO shomei, pg_catalog;

CREATE TABLE IF NOT EXISTS shomei_webauthn_pending_ceremonies (
  ceremony_id  uuid PRIMARY KEY,
  user_id      uuid NULL REFERENCES shomei_users(user_id),
  kind         text NOT NULL,
  options_blob bytea NOT NULL,
  created_at   timestamptz NOT NULL,
  expires_at   timestamptz NOT NULL
);

CREATE INDEX IF NOT EXISTS shomei_webauthn_pending_ceremonies_expires_at_idx
  ON shomei_webauthn_pending_ceremonies (expires_at);
