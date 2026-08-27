-- sessions-authenticated-at

SET search_path TO shomei, pg_catalog;

-- When the session's last credential was proven (the auth_time claim, which a refresh must not
-- renew). NULL for rows that predate the column; readers fall back to created_at.
ALTER TABLE shomei_sessions
  ADD COLUMN IF NOT EXISTS authenticated_at timestamptz NULL;
