-- shomei-signing-keys-one-active

SET LOCAL search_path = pg_catalog, pg_temp;

ALTER TABLE shomei.shomei_signing_keys
  ADD COLUMN IF NOT EXISTS revoked_at timestamptz NULL;

-- Establish the invariant before declaring it. Keep the row the pre-migration loader would
-- have selected (latest activation, then creation, then key id) and retire every other active
-- row. Retired rows remain published so outstanding tokens continue to verify.
UPDATE shomei.shomei_signing_keys
SET status = 'retired', retired_at = now()
WHERE status = 'active'
  AND key_id <> (
    SELECT key_id
    FROM shomei.shomei_signing_keys
    WHERE status = 'active'
    ORDER BY activated_at DESC NULLS LAST, created_at DESC, key_id DESC
    LIMIT 1
  );

CREATE UNIQUE INDEX IF NOT EXISTS shomei_signing_keys_one_active
  ON shomei.shomei_signing_keys ((1))
  WHERE status = 'active';
