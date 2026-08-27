# Machine Tokens and Service Accounts

Machine tokens are short-lived, refresh-less access tokens for connectors, agent runtimes, and
downstream services. Shōmei issues them through standard OAuth 2.0 interfaces: the
`client_credentials` grant for a service acting as itself, and RFC 8693 token exchange when a
service or operator acts for a user.

Service accounts live in PostgreSQL and are managed with `shomei-admin`. Each account has a public
`client_id`, a secret whose digest is stored, a dedicated backing user, an allowed-scope ceiling,
and an active or revoked status. There is no static account list in runtime configuration.

## Create an account

```bash
DATABASE_URL="$PG_CONNECTION_STRING" shomei-admin service-accounts create \
  --display-name "rei connector" --scope kawa:ingest --scope signal:raise
```

```text
client_id:     svcacct_01kx5512s4erkbgf2wn36qb0e3
client_secret: VY5m8lHUmBMp8BpdBqD-pMJH3ufcn2Q8lmNMI_XV9sY  (shown once)
scopes:        kawa:ingest signal:raise
```

The secret is generated from the system CSPRNG and shown exactly once. Shōmei stores only its
SHA-256 digest and compares presented secrets in constant time. Put the secret in a secret manager;
if it is lost, rotate it.

## Request a token with `client_credentials`

Any OAuth 2.0 client library can use the endpoint. HTTP Basic authentication is preferred:

```bash
curl -s -u "$CLIENT_ID:$CLIENT_SECRET" \
  -d 'grant_type=client_credentials&scope=kawa:ingest' \
  http://localhost:8080/oauth/token
```

```json
{"access_token":"eyJhbGciOiJFUzI1NiIsImtpZCI6...","token_type":"Bearer","expires_in":300,"scope":"kawa:ingest"}
```

Credentials may instead use `client_secret_post`:

```bash
curl -s \
  -d 'grant_type=client_credentials' \
  --data-urlencode "client_id=$CLIENT_ID" \
  --data-urlencode "client_secret=$CLIENT_SECRET" \
  http://localhost:8080/oauth/token
```

Omitting `scope` grants the account's entire allowed set. An explicit empty scope or a scope
outside the account's allow-list returns `invalid_scope`. The access token has no refresh token;
request another after it expires. `SHOMEI_MACHINE_TOKEN_TTL` or the Dhall
`machineTokenTtlSeconds` field sets its lifetime, defaulting to 300 seconds.

A `client_credentials` token names a **machine session**. It can authenticate to APIs that accept
its scopes, but it cannot authorize an OAuth client at `GET /oauth/authorize`; that endpoint
requires a live interactive session and answers the machine credential with `401 login_required`.

OAuth failures use RFC 6749 error objects rather than Problem Details:

```json
{"error":"invalid_client","error_description":"client authentication failed"}
```

Unknown client ids, wrong secrets, revoked accounts, and inactive backing users are deliberately
indistinguishable. Successful issuance writes a `service_token_issued` audit event; lifecycle
operations write `service_account_created`, `service_account_secret_rotated`, and
`service_account_revoked` without recording a secret.

## Rotate or revoke credentials

```bash
shomei-admin service-accounts rotate-secret svcacct_01kx…
shomei-admin service-accounts revoke svcacct_01kx…
shomei-admin service-accounts list
```

Rotation has no overlap: the previous secret stops working as soon as the new digest is stored.
For a zero-downtime handover, create a second account, move consumers, then revoke the first.
Revocation prevents future issuance but cannot retract an already-issued stateless JWT; the short
machine-token TTL bounds that window.

## Act on behalf of a user with RFC 8693

A plain `client_credentials` token identifies only the service. For a cross-service call that must
retain user attribution, give the account the `token-exchange:subject` gate scope and exchange the
user's access token:

```bash
curl -s -u "$CLIENT_ID:$CLIENT_SECRET" \
  -d 'grant_type=urn:ietf:params:oauth:grant-type:token-exchange' \
  --data-urlencode "subject_token=$USER_ACCESS_TOKEN" \
  -d 'subject_token_type=urn:ietf:params:oauth:token-type:access_token' \
  -d 'scope=kawa:ingest' \
  http://localhost:8080/oauth/token
```

The issued token has the user in `sub`, the service's backing user in `act`, narrowed scopes, the
machine-token TTL, and no refresh token. The `token-exchange:subject` gate is never copied into the
issued token. A resource server verifies the JWT against `/.well-known/jwks.json`, attributes the
action to `sub`, and logs `act`. Token exchange refuses a subject token whose session is missing,
expired, or revoked immediately, in every `sessionCheckMode`.

An operator can use the same grant to obtain a delegated token for a target user. The operator
sends the target user id as a Shōmei user-id subject token and their own access token as the actor:

```bash
curl -s \
  -d 'grant_type=urn:ietf:params:oauth:grant-type:token-exchange' \
  --data-urlencode 'subject_token=user_01jz...' \
  -d 'subject_token_type=urn:shomei:params:oauth:token-type:user-id' \
  --data-urlencode "actor_token=$OPERATOR_ACCESS_TOKEN" \
  -d 'actor_token_type=urn:ietf:params:oauth:token-type:access_token' \
  --data-urlencode 'reason=support ticket 4711' \
  http://localhost:8080/oauth/token
```

This mode requires the operator's configured `impersonate:user` scope and a fresh actor token.
The actor token must name a live session and the operator account must remain active, regardless
of `sessionCheckMode`. Delegated tokens are short-lived, refresh-less, carry the target in `sub`
and operator in `act`, and cannot be exchanged again or authorize an OAuth client at
`GET /oauth/authorize`. Revoke a delegated token or its session through `POST /oauth/revoke`.

## Security checklist

- Use a distinct service account for each workload and environment.
- Grant only the scopes the workload requires.
- Store the secret outside source code and rotate it periodically.
- Treat `token-exchange:subject` and `impersonate:user` as high-privilege gates.
- Verify signature, issuer, audience, expiry, and required scopes in every resource server.
- Log `act` whenever it is present so delegated work retains actor attribution.
