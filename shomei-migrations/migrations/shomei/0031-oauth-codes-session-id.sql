SET LOCAL search_path = pg_catalog, pg_temp;

-- The session the exchange of this code minted, stamped after consumption, so a second
-- presentation of a consumed code (RFC 6749 §4.1.2) can revoke what the first produced.
-- No foreign key: the sweeper deletes codes and sessions on independent schedules.
ALTER TABLE shomei.shomei_oauth_authorization_codes
  ADD COLUMN IF NOT EXISTS session_id uuid NULL;
