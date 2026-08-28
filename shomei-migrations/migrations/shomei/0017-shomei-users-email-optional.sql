SET LOCAL search_path = pg_catalog, pg_temp;

-- Contract: email is now an optional attribute, not the principal.
ALTER TABLE shomei.shomei_users
  ALTER COLUMN email DROP NOT NULL;

-- The old UNIQUE on email was created inline by the CREATE TABLE; drop it and replace
-- with a partial unique index so NULL emails don't collide while real emails stay unique.
ALTER TABLE shomei.shomei_users
  DROP CONSTRAINT IF EXISTS shomei_users_email_key;

CREATE UNIQUE INDEX IF NOT EXISTS shomei_users_email_key
  ON shomei.shomei_users (email)
  WHERE email IS NOT NULL;
