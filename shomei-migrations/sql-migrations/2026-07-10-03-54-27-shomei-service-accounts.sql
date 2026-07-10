-- codd: in-txn

SET search_path TO shomei, pg_catalog;

-- Database-backed service accounts: machine credentials an operator creates, rotates, and
-- revokes at runtime, replacing the static config-defined accounts that required a redeploy.
--
-- client_id is the TypeID text rendering of service_account_id (prefix 'svcacct'), so it is
-- unique and copy-pasteable; secrecy lives entirely in the secret, never in the identifier.
--
-- secret_hash is a lowercase 64-char SHA-256 hex digest of a server-generated 256-bit random
-- secret, compared in constant time. Deliberately NOT Argon2id: these secrets are never
-- human-chosen, so there is no low-entropy preimage to slow down, and an Argon2 verify on every
-- token request would be a self-inflicted DoS vector.
--
-- user_id backs the account with a row in shomei_users, because AuthClaims.subject is a UserId
-- and shomei_sessions.user_id has an FK into shomei_users: a token cannot be minted without a
-- user row behind its session. No CASCADE — the user row is provisioned for this account and
-- the audit trail references both.
--
-- allowed_scopes rides as a jsonb array of scope texts, matching how shomei_webauthn_credentials
-- stores `transports`. No query here needs SQL-level array operators.
--
-- status is 'active' or 'revoked'. A revoked account keeps its row so audit events that name it
-- still resolve.
CREATE TABLE IF NOT EXISTS shomei_service_accounts (
  service_account_id uuid        PRIMARY KEY,
  client_id          text        NOT NULL UNIQUE,
  user_id            uuid        NOT NULL REFERENCES shomei_users(user_id),
  secret_hash        text        NOT NULL,
  display_name       text        NOT NULL,
  allowed_scopes     jsonb       NOT NULL,
  status             text        NOT NULL,
  created_at         timestamptz NOT NULL,
  rotated_at         timestamptz NULL,
  revoked_at         timestamptz NULL
);

CREATE INDEX IF NOT EXISTS shomei_service_accounts_user_id_idx
  ON shomei_service_accounts (user_id);
