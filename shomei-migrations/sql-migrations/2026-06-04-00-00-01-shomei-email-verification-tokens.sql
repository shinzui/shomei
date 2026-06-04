-- codd: in-txn

SET search_path TO shomei, pg_catalog;

CREATE TABLE IF NOT EXISTS shomei_email_verification_tokens (
  verification_token_id uuid PRIMARY KEY,
  user_id               uuid NOT NULL REFERENCES shomei_users(user_id),
  token_hash            text NOT NULL UNIQUE,
  status                text NOT NULL,
  created_at            timestamptz NOT NULL,
  expires_at            timestamptz NOT NULL,
  consumed_at           timestamptz NULL,
  revoked_at            timestamptz NULL
);

CREATE INDEX IF NOT EXISTS shomei_email_verification_tokens_user_id_idx
  ON shomei_email_verification_tokens (user_id);
CREATE INDEX IF NOT EXISTS shomei_email_verification_tokens_status_idx
  ON shomei_email_verification_tokens (status);
