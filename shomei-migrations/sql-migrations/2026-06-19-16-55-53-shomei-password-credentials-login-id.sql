-- codd: in-txn

SET search_path TO shomei, pg_catalog;

-- Expand: add the new principal column, nullable for now so old and new code coexist.
ALTER TABLE shomei_password_credentials
  ADD COLUMN IF NOT EXISTS login_id text NULL;

-- Backfill: existing rows had email as the principal; identifier defaults to email.
UPDATE shomei_password_credentials
  SET login_id = email
  WHERE login_id IS NULL;

-- Constrain: every credential must now have a login id, and it must be unique.
ALTER TABLE shomei_password_credentials
  ALTER COLUMN login_id SET NOT NULL;

CREATE UNIQUE INDEX IF NOT EXISTS shomei_password_credentials_login_id_key
  ON shomei_password_credentials (login_id);
