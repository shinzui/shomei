-- add-authentication-generation

SET LOCAL search_path = pg_catalog, pg_temp;

-- Preserve enrolled factors and sessions; legacy pending flows restart after rollout.
ALTER TABLE shomei.shomei_users
  ADD COLUMN authentication_generation bigint NOT NULL DEFAULT 0
  CHECK (authentication_generation >= 0);
ALTER TABLE shomei.shomei_webauthn_pending_ceremonies
  ADD COLUMN authentication_generation bigint CHECK (authentication_generation >= 0),
  ADD COLUMN initiating_session_id uuid;
ALTER TABLE shomei.shomei_oauth_authorization_codes
  ADD COLUMN authentication_generation bigint CHECK (authentication_generation >= 0);
ALTER TABLE shomei.shomei_totp_credentials
  ADD COLUMN authentication_generation bigint CHECK (authentication_generation >= 0);
