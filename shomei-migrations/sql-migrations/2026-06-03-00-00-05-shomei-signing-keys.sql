-- codd: in-txn

SET search_path TO shomei, pg_catalog;

-- public_key_jwk / private_key_jwk are opaque JWK-JSON text (IP-4: the core and
-- postgres packages never import jose; only shomei-jwt interprets the material).
CREATE TABLE IF NOT EXISTS shomei_signing_keys (
  key_id          text PRIMARY KEY,
  algorithm       text NOT NULL,
  public_key_jwk  text NOT NULL,
  private_key_jwk text NOT NULL,
  status          text NOT NULL,
  created_at      timestamptz NOT NULL,
  activated_at    timestamptz NULL,
  retired_at      timestamptz NULL
);
