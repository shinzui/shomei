SET LOCAL search_path = pg_catalog, pg_temp;

CREATE TABLE IF NOT EXISTS shomei.shomei_refresh_tokens (
  refresh_token_id uuid PRIMARY KEY,
  session_id       uuid NOT NULL REFERENCES shomei.shomei_sessions(session_id),
  token_hash       text NOT NULL UNIQUE,
  parent_token_id  uuid NULL REFERENCES shomei.shomei_refresh_tokens(refresh_token_id),
  status           text NOT NULL,
  created_at       timestamptz NOT NULL,
  expires_at       timestamptz NOT NULL,
  used_at          timestamptz NULL,
  revoked_at       timestamptz NULL
);

CREATE INDEX IF NOT EXISTS shomei_refresh_tokens_session_id_idx
  ON shomei.shomei_refresh_tokens (session_id);
CREATE INDEX IF NOT EXISTS shomei_refresh_tokens_parent_token_id_idx
  ON shomei.shomei_refresh_tokens (parent_token_id);
CREATE INDEX IF NOT EXISTS shomei_refresh_tokens_status_idx
  ON shomei.shomei_refresh_tokens (status);
