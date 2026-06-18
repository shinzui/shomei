-- codd: in-txn

SET search_path TO shomei, pg_catalog;

ALTER TABLE shomei_users
  ADD COLUMN IF NOT EXISTS email_verified_at timestamptz NULL;
