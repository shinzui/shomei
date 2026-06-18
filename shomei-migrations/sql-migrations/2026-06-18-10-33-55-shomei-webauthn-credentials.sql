-- codd: in-txn

SET search_path TO shomei, pg_catalog;

CREATE TABLE IF NOT EXISTS shomei_webauthn_credentials (
  passkey_id    uuid PRIMARY KEY,
  user_id       uuid NOT NULL REFERENCES shomei_users(user_id),
  credential_id bytea NOT NULL UNIQUE,
  user_handle   bytea NOT NULL,
  public_key    bytea NOT NULL,
  sign_counter  bigint NOT NULL,
  transports    jsonb NOT NULL,
  label         text NULL,
  created_at    timestamptz NOT NULL,
  last_used_at  timestamptz NULL
);

CREATE INDEX IF NOT EXISTS shomei_webauthn_credentials_user_id_idx
  ON shomei_webauthn_credentials (user_id);
CREATE INDEX IF NOT EXISTS shomei_webauthn_credentials_user_handle_idx
  ON shomei_webauthn_credentials (user_handle);
