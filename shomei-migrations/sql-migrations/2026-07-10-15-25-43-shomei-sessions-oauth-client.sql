-- codd: in-txn

SET search_path TO shomei, pg_catalog;

-- The OAuth client that minted this session, for sessions created by the authorization-code grant.
--
-- NULL for every session that already exists and for every one minted by password login, passkey
-- login, MFA completion, impersonation, or a service-account grant. Those flows are unchanged and
-- the bespoke POST /v1/auth/refresh ignores this column entirely.
--
-- Its purpose is client binding on the OAuth refresh_token grant: a refresh token issued through
-- client A must not be rotatable by client B, and Shomei's refresh tokens are already
-- session-scoped, so binding the session is enough. A session with a NULL here cannot be refreshed
-- through /oauth/token at all -- only through the endpoint that created it.
--
-- Deliberately a plain text client_id rather than a foreign key into shomei_oauth_clients: a
-- revoked and re-registered client must never inherit the sessions of its namesake, and the
-- sessions of a deleted client row must not block its deletion.
ALTER TABLE shomei_sessions
  ADD COLUMN IF NOT EXISTS oauth_client_id text NULL;
