-- codd: in-txn

SET search_path TO shomei, pg_catalog;

CREATE TABLE IF NOT EXISTS shomei_users (
  user_id      uuid PRIMARY KEY,
  email        text NOT NULL UNIQUE,
  display_name text NULL,
  status       text NOT NULL,
  created_at   timestamptz NOT NULL,
  updated_at   timestamptz NOT NULL
);
