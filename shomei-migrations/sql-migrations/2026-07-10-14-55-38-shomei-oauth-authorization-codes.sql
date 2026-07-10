-- codd: in-txn

SET search_path TO shomei, pg_catalog;

-- Single-use OAuth2 authorization codes (RFC 6749 §4.1), issued by GET /oauth/authorize and
-- exchanged at POST /oauth/token.
--
-- The primary key is the code's SHA-256 hex digest, never the code: the code itself is a
-- high-entropy opaque string that exists only in the redirect URL and the exchanging request, so a
-- database leak leaks no usable codes. This mirrors how refresh tokens and the one-time
-- verification/reset tokens are stored.
--
-- Every column is a binding the exchange must re-check, which is the point of the table:
--
--   client_id      the code may be exchanged only by the client it was issued to
--   redirect_uri   the exchange must present the same URI the authorize request did
--   code_challenge the PKCE S256 challenge (RFC 7636), NULL when the confidential client sent
--                  none. The method is not stored because only S256 is accepted.
--   user_id        the subject whose session the exchange will mint
--   scopes         a jsonb array of scope texts, as shomei_oauth_clients.allowed_scopes is
--   nonce          echoed verbatim into the ID token when present, so the client can bind the
--                  token to its own session
--   auth_time      when the user actually authenticated (the authorizing token's iat), for the
--                  ID token's auth_time claim
--
-- consumed_at is what makes a code single-use. The exchange is one atomic statement --
-- UPDATE ... SET consumed_at = now WHERE code_hash = $1 AND consumed_at IS NULL AND
-- expires_at > now RETURNING ... -- so two racing exchanges of the same code cannot both win.
-- The row is kept rather than deleted, so a replay is distinguishable from an unknown code by
-- anyone reading the table (both answer invalid_grant on the wire), and so the sweeper is the
-- single deleter.
CREATE TABLE IF NOT EXISTS shomei_oauth_authorization_codes (
  code_hash       text        PRIMARY KEY,
  client_id       text        NOT NULL,
  redirect_uri    text        NOT NULL,
  user_id         uuid        NOT NULL REFERENCES shomei_users(user_id),
  scopes          jsonb       NOT NULL,
  nonce           text        NULL,
  code_challenge  text        NULL,
  auth_time       timestamptz NOT NULL,
  created_at      timestamptz NOT NULL,
  expires_at      timestamptz NOT NULL,
  consumed_at     timestamptz NULL
);

-- The sweeper deletes by expiry; codes live 60 seconds by default, so this table is small and
-- churns fast.
CREATE INDEX IF NOT EXISTS shomei_oauth_authorization_codes_expires_at_idx
  ON shomei_oauth_authorization_codes (expires_at);
