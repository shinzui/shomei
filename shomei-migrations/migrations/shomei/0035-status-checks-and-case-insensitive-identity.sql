SET search_path TO shomei, pg_catalog;

-- Persisted text is part of the domain boundary. Replacing named constraints keeps this
-- migration deterministic for development databases that may have received an earlier draft.
ALTER TABLE shomei_users
  DROP CONSTRAINT IF EXISTS shomei_users_status_check;
ALTER TABLE shomei_users
  ADD CONSTRAINT shomei_users_status_check
  CHECK (status IN ('active', 'suspended', 'deleted'));

ALTER TABLE shomei_sessions
  DROP CONSTRAINT IF EXISTS shomei_sessions_status_check;
ALTER TABLE shomei_sessions
  ADD CONSTRAINT shomei_sessions_status_check
  CHECK (status IN ('active', 'revoked', 'expired'));

ALTER TABLE shomei_refresh_tokens
  DROP CONSTRAINT IF EXISTS shomei_refresh_tokens_status_check;
ALTER TABLE shomei_refresh_tokens
  ADD CONSTRAINT shomei_refresh_tokens_status_check
  CHECK (status IN ('active', 'used', 'revoked', 'expired'));

ALTER TABLE shomei_signing_keys
  DROP CONSTRAINT IF EXISTS shomei_signing_keys_status_check;
ALTER TABLE shomei_signing_keys
  ADD CONSTRAINT shomei_signing_keys_status_check
  CHECK (status IN ('pending', 'active', 'retired', 'revoked'));

ALTER TABLE shomei_email_verification_tokens
  DROP CONSTRAINT IF EXISTS shomei_email_verification_tokens_status_check;
ALTER TABLE shomei_email_verification_tokens
  ADD CONSTRAINT shomei_email_verification_tokens_status_check
  CHECK (status IN ('active', 'consumed', 'revoked', 'expired'));

ALTER TABLE shomei_password_reset_tokens
  DROP CONSTRAINT IF EXISTS shomei_password_reset_tokens_status_check;
ALTER TABLE shomei_password_reset_tokens
  ADD CONSTRAINT shomei_password_reset_tokens_status_check
  CHECK (status IN ('active', 'consumed', 'revoked', 'expired'));

ALTER TABLE shomei_login_attempts
  DROP CONSTRAINT IF EXISTS shomei_login_attempts_outcome_check;
ALTER TABLE shomei_login_attempts
  ADD CONSTRAINT shomei_login_attempts_outcome_check
  CHECK (outcome IN ('success', 'failure'));

ALTER TABLE shomei_webauthn_pending_ceremonies
  DROP CONSTRAINT IF EXISTS shomei_webauthn_pending_ceremonies_kind_check;
ALTER TABLE shomei_webauthn_pending_ceremonies
  ADD CONSTRAINT shomei_webauthn_pending_ceremonies_kind_check
  CHECK (kind IN ('registration', 'authentication'));

ALTER TABLE shomei_service_accounts
  DROP CONSTRAINT IF EXISTS shomei_service_accounts_status_check;
ALTER TABLE shomei_service_accounts
  ADD CONSTRAINT shomei_service_accounts_status_check
  CHECK (status IN ('active', 'revoked'));

ALTER TABLE shomei_oauth_clients
  DROP CONSTRAINT IF EXISTS shomei_oauth_clients_status_check;
ALTER TABLE shomei_oauth_clients
  ADD CONSTRAINT shomei_oauth_clients_status_check
  CHECK (status IN ('active', 'revoked'));

ALTER TABLE shomei_oauth_clients
  DROP CONSTRAINT IF EXISTS shomei_oauth_clients_client_type_check;
ALTER TABLE shomei_oauth_clients
  ADD CONSTRAINT shomei_oauth_clients_client_type_check
  CHECK (client_type IN ('confidential', 'public'));

-- The application normalizes new identifiers, but uniqueness must still hold when historical
-- imports, administrative SQL, or a future writer reaches the database directly.
CREATE UNIQUE INDEX IF NOT EXISTS shomei_users_login_id_lower_key
  ON shomei_users (lower(login_id));

CREATE UNIQUE INDEX IF NOT EXISTS shomei_users_email_lower_key
  ON shomei_users (lower(email))
  WHERE email IS NOT NULL;

CREATE UNIQUE INDEX IF NOT EXISTS shomei_password_credentials_login_id_lower_key
  ON shomei_password_credentials (lower(login_id));

CREATE UNIQUE INDEX IF NOT EXISTS shomei_password_credentials_email_lower_key
  ON shomei_password_credentials (lower(email))
  WHERE email IS NOT NULL;
