-- sessions-authenticated-at

SET LOCAL search_path = pg_catalog, pg_temp;

-- When the session's last credential was proven (the auth_time claim, which a refresh must not
-- renew). NULL for rows that predate the column; readers fall back to created_at.
ALTER TABLE shomei.shomei_sessions
  ADD COLUMN IF NOT EXISTS authenticated_at timestamptz NULL;
