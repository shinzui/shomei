-- codd: in-txn

SET search_path TO shomei, pg_catalog;

-- Contract: email is now an optional attribute, not the principal.
ALTER TABLE shomei_password_credentials
  ALTER COLUMN email DROP NOT NULL;

-- The old UNIQUE on email was created inline by the CREATE TABLE; drop it and replace
-- with a partial unique index so NULL emails don't collide while real emails stay unique.
ALTER TABLE shomei_password_credentials
  DROP CONSTRAINT IF EXISTS shomei_password_credentials_email_key;

CREATE UNIQUE INDEX IF NOT EXISTS shomei_password_credentials_email_key
  ON shomei_password_credentials (email)
  WHERE email IS NOT NULL;
