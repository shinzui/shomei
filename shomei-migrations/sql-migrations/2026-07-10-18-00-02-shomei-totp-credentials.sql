-- codd: in-txn

SET search_path TO shomei, pg_catalog;

-- A user's TOTP (RFC 6238) second-factor credential (EP-7). One per user (UNIQUE (user_id)):
-- re-enrolling while an unconfirmed row exists replaces it; enrolling over a confirmed row is
-- refused by the workflow (removal is a separate, audited, impersonation-blocked step).
--
-- secret_enc is the AES-256-GCM ciphertext of the raw 20-byte shared secret, laid out as
-- `nonce (12 bytes) || ciphertext || GCM tag (16 bytes)` in one bytea. It is encrypted, never
-- hashed: a verifier must recompute HMAC(secret, counter) on every login, so it needs the
-- secret back. The key lives outside the database (SHOMEI_TOTP_ENCRYPTION_KEY), so a database
-- dump alone never yields a usable secret.
--
-- last_used_counter is the RFC 6238 §5.2 replay-defense high-water mark: a code is accepted only
-- when its time-step counter is strictly greater than this value, which is then updated. NULL
-- until the first acceptance (the confirming code sets it too).
--
-- confirmed_at NULL marks an enrollment that has not yet been activated with a first valid code;
-- rows older than the enrollment TTL with NULL confirmed_at are treated as absent and replaced.
CREATE TABLE IF NOT EXISTS shomei_totp_credentials (
  totp_credential_id uuid        PRIMARY KEY,
  user_id            uuid        NOT NULL UNIQUE REFERENCES shomei_users(user_id),
  secret_enc         bytea       NOT NULL,
  last_used_counter  bigint      NULL,
  confirmed_at       timestamptz NULL,
  created_at         timestamptz NOT NULL
);
