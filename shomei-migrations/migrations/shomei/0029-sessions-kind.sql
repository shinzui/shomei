-- sessions-kind

SET LOCAL search_path = pg_catalog, pg_temp;

-- How the session was established: 'interactive' (a human proved a credential, or exchanged an
-- authorization code that an interactive session authorized), 'machine' (client_credentials), or
-- 'delegated' (impersonation or RFC 8693 on-behalf-of; the session's access token carries `act`).
--
-- Nullable with a default so that every row predating the column reads as 'interactive' -- the
-- only kind that existed before machine and delegated sessions were distinguishable -- and so a
-- binary built before this column keeps inserting after it is applied (its INSERT names no `kind`
-- and the default fills it). The interpreter always writes an explicit value and refuses an unknown
-- one on read, as it does for `status`.
--
-- The column exists so GET /oauth/authorize can refuse to mint an authorization code for anything
-- but an interactive session. A code becomes a brand-new, refreshable, fully privileged session;
-- a machine or delegated credential must not be able to obtain one (plan 51).
ALTER TABLE shomei.shomei_sessions
  ADD COLUMN IF NOT EXISTS kind text NULL DEFAULT 'interactive';
