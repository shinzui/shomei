-- codd: in-txn

SET search_path TO shomei, pg_catalog;

CREATE TABLE IF NOT EXISTS shomei_password_credentials (
  credential_id uuid PRIMARY KEY,
  user_id       uuid NOT NULL REFERENCES shomei_users(user_id),
  email         text NOT NULL UNIQUE,
  password_hash text NOT NULL,
  created_at    timestamptz NOT NULL,
  updated_at    timestamptz NOT NULL
);
