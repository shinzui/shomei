SET search_path TO shomei, pg_catalog;

-- One password credential per user is the invariant every workflow assumes: signup creates
-- exactly one, and password reset and change update by user_id expecting one row. Stating it as a
-- UNIQUE index also gives those updates the index they lacked. A duplicate can only have arrived
-- out of band; this migration deliberately refuses to apply until the operator resolves it.
CREATE UNIQUE INDEX IF NOT EXISTS shomei_password_credentials_user_id_key
  ON shomei_password_credentials (user_id);
