SET LOCAL search_path = pg_catalog, pg_temp;

CREATE TABLE IF NOT EXISTS shomei.shomei_account_lockouts (
  account_key  text PRIMARY KEY,
  failed_count int NOT NULL,
  locked_until timestamptz NULL,
  updated_at   timestamptz NOT NULL
);

CREATE INDEX IF NOT EXISTS shomei_account_lockouts_locked_until_idx
  ON shomei.shomei_account_lockouts (locked_until);
