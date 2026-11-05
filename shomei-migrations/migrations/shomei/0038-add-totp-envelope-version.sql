-- add-totp-envelope-version

SET LOCAL search_path = pg_catalog, pg_temp;

-- Existing rows are explicitly legacy; only the offline converter may read version 0.
ALTER TABLE shomei.shomei_totp_credentials
  ADD COLUMN IF NOT EXISTS envelope_version smallint NOT NULL DEFAULT 0
  CHECK (envelope_version IN (0, 1));

