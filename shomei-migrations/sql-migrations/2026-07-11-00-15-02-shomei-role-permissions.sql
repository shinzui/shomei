-- codd: in-txn

SET search_path TO shomei, pg_catalog;

-- Role→permission definitions (EP-9): a role implies a set of flat verb-noun capability
-- strings (e.g. 'projects:write'), resolved to the union across a subject's roles at token
-- mint and carried in the 'permissions' claim. The FK into shomei_roles makes "a permission
-- can only attach to a defined role" a database invariant (typo protection), mirroring the
-- shomei_role_grants.role FK. There is deliberately no CASCADE on the role FK — the registry
-- is append-only, so a role is never deleted.
CREATE TABLE IF NOT EXISTS shomei_role_permissions (
  role       text        NOT NULL REFERENCES shomei_roles(role),
  permission text        NOT NULL,
  created_at timestamptz NOT NULL,
  PRIMARY KEY (role, permission)
);

-- Time-bound grants (EP-9): a nullable expiry on each grant. NULL means "forever", so every
-- existing row keeps its meaning — a safe additive migration. Expiry is passive: the mint path
-- filters (expires_at IS NULL OR expires_at > $now); nothing fires at the instant a grant
-- expires, and the (already-inert) row is swept later as hygiene.
ALTER TABLE shomei_role_grants
  ADD COLUMN IF NOT EXISTS expires_at timestamptz NULL;

-- Serves the sweeper's `DELETE … WHERE expires_at < $1` in bounded batches without taxing the
-- common forever-NULL case; the mint-path list query stays on the (user_id) leading key.
CREATE INDEX IF NOT EXISTS shomei_role_grants_expires_at_idx
  ON shomei_role_grants (expires_at)
  WHERE expires_at IS NOT NULL;
