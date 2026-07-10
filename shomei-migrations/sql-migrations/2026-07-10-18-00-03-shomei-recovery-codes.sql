-- codd: in-txn

SET search_path TO shomei, pg_catalog;

-- Single-use MFA recovery codes (EP-7): the lockout escape hatch when a user loses their TOTP
-- authenticator or passkey. Ten per set; regeneration replaces the whole set.
--
-- code_hash is a lowercase SHA-256 hex digest of the normalized code (dash stripped, casefolded),
-- the same defensible pattern service-token secrets use. The plaintext is shown to the user once
-- and never stored, so a database dump never yields a spendable code.
--
-- used_at NULL marks a code still spendable. Consumption is a compare-and-set
-- (UPDATE ... WHERE used_at IS NULL RETURNING), which makes a double-spend impossible even under
-- concurrent requests. A spent row is kept (not deleted) so a replay finds a used row.
--
-- No CASCADE on the user FK: a user is never hard-deleted while codes exist, and the row set is
-- replaced wholesale by regeneration.
CREATE TABLE IF NOT EXISTS shomei_recovery_codes (
  recovery_code_id uuid        PRIMARY KEY,
  user_id          uuid        NOT NULL REFERENCES shomei_users(user_id),
  code_hash        text        NOT NULL,
  created_at       timestamptz NOT NULL,
  used_at          timestamptz NULL
);

CREATE INDEX IF NOT EXISTS shomei_recovery_codes_user_id_idx
  ON shomei_recovery_codes (user_id);
