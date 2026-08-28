SET LOCAL search_path = pg_catalog, pg_temp;

ALTER TABLE shomei.shomei_users
  ADD COLUMN IF NOT EXISTS email_verified_at timestamptz NULL;
