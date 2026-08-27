SET search_path TO shomei, pg_catalog;

-- The scopes the authorization-code grant granted this session, re-applied to every access
-- token refresh mints for it. Empty for every session no OAuth client minted and for every
-- row that predates the column: those sessions never had a granted set to lose.
ALTER TABLE shomei_sessions
  ADD COLUMN IF NOT EXISTS granted_scopes text[] NOT NULL DEFAULT '{}';
