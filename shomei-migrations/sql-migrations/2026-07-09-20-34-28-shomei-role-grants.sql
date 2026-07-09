-- codd: in-txn

SET search_path TO shomei, pg_catalog;

-- The role registry: the catalog of roles an operator has declared grantable. Seeded with
-- 'admin' so the bootstrap grant works on a fresh database with no prior `roles define`.
CREATE TABLE IF NOT EXISTS shomei_roles (
  role        text        PRIMARY KEY,
  description text        NULL,
  created_at  timestamptz NOT NULL
);

INSERT INTO shomei_roles (role, description, created_at)
VALUES ('admin', 'Full access to the shomei /admin surface and admin CLI-equivalent HTTP routes', now())
ON CONFLICT (role) DO NOTHING;

-- Durable "user U has role R" facts. The FK into shomei_roles makes "grants reference defined
-- roles" a database invariant rather than workflow discipline. granted_by is nullable: CLI
-- bootstrap grants and config-driven default-role grants have no authenticated actor. There is
-- deliberately no CASCADE on the role FK — the registry is append-only, so the case never arises.
CREATE TABLE IF NOT EXISTS shomei_role_grants (
  user_id    uuid        NOT NULL REFERENCES shomei_users(user_id) ON DELETE CASCADE,
  role       text        NOT NULL REFERENCES shomei_roles(role),
  granted_by uuid        NULL REFERENCES shomei_users(user_id),
  granted_at timestamptz NOT NULL,
  PRIMARY KEY (user_id, role)
);

CREATE INDEX IF NOT EXISTS shomei_role_grants_role_idx ON shomei_role_grants (role);
