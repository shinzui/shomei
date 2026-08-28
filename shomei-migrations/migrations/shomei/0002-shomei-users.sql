SET LOCAL search_path = pg_catalog, pg_temp;

CREATE TABLE IF NOT EXISTS shomei.shomei_users (
  user_id      uuid PRIMARY KEY,
  email        text NOT NULL UNIQUE,
  display_name text NULL,
  status       text NOT NULL,
  created_at   timestamptz NOT NULL,
  updated_at   timestamptz NOT NULL
);
