-- codd: in-txn

SET search_path TO shomei, pg_catalog;

-- OAuth2 / OIDC clients: the relying parties that drive the authorization-code flow.
--
-- client_id is the TypeID text rendering of oauth_client_id (prefix 'oauthclient'), matching how
-- shomei_service_accounts derives its client_id. A client_id is public and copy-pasteable;
-- secrecy lives entirely in the secret.
--
-- secret_hash is a lowercase 64-char SHA-256 hex digest, the same format the service accounts use,
-- so Shomei.Workflow.ServiceToken.verifyServiceSecret verifies both. It is NULL for exactly the
-- public clients (SPAs, native apps), which hold no secret and whose only binding between the
-- authorize and token requests is PKCE.
--
-- client_type is 'confidential' or 'public'.
--
-- redirect_uris is a jsonb array of absolute URI texts, compared by EXACT STRING EQUALITY at
-- authorize time. No prefix matching, no wildcards: a redirect_uri that is not registered must
-- never receive a redirect, or the endpoint becomes an open redirector.
--
-- allowed_scopes is a jsonb array of scope texts (matching shomei_service_accounts.allowed_scopes),
-- the ceiling on what an authorize request may ask for.
--
-- status is 'active' or 'revoked'. A revoked client keeps its row so audit events naming it still
-- resolve, and so a revoked client_id is never recycled.
--
-- Unlike a service account, an oauth client has NO backing shomei_users row: it is never a token
-- subject. The user it acts for is the one who authenticated at /oauth/authorize.
CREATE TABLE IF NOT EXISTS shomei_oauth_clients (
  oauth_client_id uuid        PRIMARY KEY,
  client_id       text        NOT NULL UNIQUE,
  secret_hash     text        NULL,
  client_type     text        NOT NULL,
  display_name    text        NOT NULL,
  redirect_uris   jsonb       NOT NULL,
  allowed_scopes  jsonb       NOT NULL,
  status          text        NOT NULL,
  created_at      timestamptz NOT NULL,
  revoked_at      timestamptz NULL
);
