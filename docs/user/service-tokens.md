# Machine Tokens (Service Accounts)

Machine tokens are short-lived, refresh-less access tokens for non-human callers: connectors,
agent runtimes, and downstream services. They are separate from human login — an ordinary
signup/login token carries no scopes, while a machine token carries coarse scopes such as
`kawa:ingest`, `signal:raise`, or `channel:egress`, which downstream routes gate on.

There are two ways to get one, and you should use the first.

| | **`POST /oauth/token`** (recommended) | `POST /v1/auth/service-token` (deprecated) |
|---|---|---|
| Protocol | OAuth2 `client_credentials`, RFC 6749 | Shōmei-specific JSON |
| Accounts live in | PostgreSQL, managed at runtime | Static configuration |
| Create / rotate / revoke | `shomei-admin service-accounts …` | edit config, redeploy |
| Client code | any stock OAuth2 library | hand-written |

The HTTP reference for both is in [api.md](api.md). This guide covers operating and consuming them.

## The recommended path: OAuth2 client credentials

A service account is a row in `shomei_service_accounts`. Each carries:

- `client_id` — the public identifier the caller sends. It is the account's TypeID text
  (`svcacct_01kx…`), so it is unique and copy-pasteable. It is **not** a secret.
- `secret_hash` — a SHA-256 digest of the secret. The secret itself is never stored.
- `user_id` — a dedicated row in `shomei_users`, created with the account. A token's `sub` is a
  user id and sessions have a foreign key into `shomei_users`, so every account needs one. It has
  no password credential and cannot be logged into.
- `allowed_scopes` — the ceiling on what a token from this account may carry.
- `status` — `active` or `revoked`.

### Create an account

```bash
DATABASE_URL="$PG_CONNECTION_STRING" shomei-admin service-accounts create \
  --display-name "rei connector" --scope kawa:ingest --scope signal:raise
```

```text
client_id:     svcacct_01kx5512s4erkbgf2wn36qb0e3
client_secret: VY5m8lHUmBMp8BpdBqD-pMJH3ufcn2Q8lmNMI_XV9sY  (shown once - store it now, it cannot be retrieved)
scopes:        kawa:ingest signal:raise
```

The secret is 32 bytes from the system CSPRNG, shown exactly once. Shōmei stores only its digest,
so a lost secret cannot be recovered — only replaced with `rotate-secret`. Put it in your secret
manager now.

### Fetch a token

Any OAuth2 client library works, with no Shōmei-specific code. With `curl`:

```bash
curl -s -u "$CLIENT_ID:$CLIENT_SECRET" \
  -d 'grant_type=client_credentials&scope=kawa:ingest' \
  http://localhost:8080/oauth/token
```

```json
{"access_token":"eyJhbGciOiJFUzI1NiIsImtpZCI6...","token_type":"Bearer","expires_in":300,"scope":"kawa:ingest"}
```

Credentials may instead ride in the body (`client_secret_post`), which some clients prefer:

```bash
curl -s -d "grant_type=client_credentials&client_id=$CLIENT_ID&client_secret=$CLIENT_SECRET" \
  http://localhost:8080/oauth/token
```

**Omitting `scope` grants every scope the account is allowed**, and the response always echoes
what was granted, so a client never has to guess. Sending `scope=` (empty) is a malformed request,
not a request for no scopes.

Use the `access_token` as a bearer token against downstream routes that verify Shōmei's JWKS and
enforce `requireScope (Scope "kawa:ingest")`. The token is refresh-less: when it expires, ask
again.

### Rotate and revoke

```bash
shomei-admin service-accounts rotate-secret svcacct_01kx…   # prints a new secret, once
shomei-admin service-accounts revoke        svcacct_01kx…
shomei-admin service-accounts list
```

Rotation is **single-secret with no overlap**: the previous secret stops working the instant the
new one is written. For a zero-downtime handover, create a *second* account, move consumers to it,
then revoke the first.

Revocation refuses every future token request. It does **not** invalidate tokens already issued:
those are stateless JWTs that any verifier accepts until they expire (five minutes by default),
and revoking a database row cannot reach into a client's memory. If you need instant cutoff,
shorten `serviceToken.ttlSeconds`, or put a live-revocable authorization layer in front of the
protected resource (see [authorization](security.md)).

### Error responses

`/oauth/*` speaks the OAuth2 wire protocol, so its errors are RFC 6749 §5.2 objects — **not** the
[problem-details envelope](api.md) every other Shōmei endpoint returns. This is deliberate and
permanent: stock OAuth2 clients parse `error` and `error_description` by field name.

```json
{"error":"invalid_client","error_description":"client authentication failed"}
```

| `error` | HTTP | When |
|---|---|---|
| `invalid_client` | 401 | Unknown `client_id`, wrong secret, revoked account, inactive backing user, or no credentials. Carries `WWW-Authenticate: Basic realm="shomei"`. |
| `invalid_scope` | 400 | The requested scope is empty, or outside `allowed_scopes`. |
| `invalid_request` | 400 | A required parameter is missing or malformed (e.g. no `grant_type`). |
| `unsupported_grant_type` | 400 | A `grant_type` this deployment does not implement. |
| `server_error` | 500 | An unexpected condition, still in the OAuth shape. |

Every authentication failure returns the same `invalid_client` body. An unknown `client_id` is
indistinguishable from a wrong secret, which is indistinguishable from a revoked account — nothing
discloses whether an account exists.

### Auditing

Every successful issuance writes a `service_token_issued` event, exactly as the deprecated
endpoint does, so a consumer of the audit trail sees one event type for "a machine token was
minted" regardless of which endpoint minted it. The lifecycle also writes
`service_account_created`, `service_account_secret_rotated`, and `service_account_revoked`. No
payload ever contains a secret. Each event's `user_id` column is the account's backing user, so
filtering the audit trail by that user returns an account's whole history alongside the tokens it
minted.

---

## Acting on behalf of a user

A plain `client_credentials` token says "this service is calling"; it carries the service's identity
and nothing about any user. When service A handles a user's request and calls service B, that loses
the user: B sees only "service A", not "user U, via service A". Forwarding the user's *own* token
instead is over-broad (B gets the user's full token) and fragile (it expires mid-job). **Service
on-behalf-of** — RFC 8693 token exchange — is the fix: service A exchanges the user's access token
for a **narrowed, short-lived token that names both**, so B verifies `sub` = the user and `act` =
service A, offline, from the JWKS it already trusts.

Use it when a request genuinely acts for a user across a hop. Use plain `client_credentials` when the
service acts as *itself* (a cron job, a batch import with no user in the loop).

### The gate scope

On-behalf-of is powerful — any user access token a service sees, it could re-mint with itself as
actor — so it is **opt-in per account**. The service account must hold the dedicated scope
`token-exchange:subject` in its `allowed_scopes`; an account without it gets `invalid_scope` and
learns nothing else. The gate scope is a gate, **never carried**: it is stripped from every issued
token, so an exchanged token can never itself perform another exchange.

```bash
shomei-admin service-accounts create \
  --display-name svc-b --scope kawa:ingest --scope token-exchange:subject
```

### The exchange

```bash
curl -s -u "$CLIENT_ID:$CLIENT_SECRET" \
  -d 'grant_type=urn:ietf:params:oauth:grant-type:token-exchange' \
  --data-urlencode "subject_token=$USER_ACCESS_TOKEN" \
  -d 'subject_token_type=urn:ietf:params:oauth:token-type:access_token' \
  -d 'scope=kawa:ingest' \
  http://localhost:8080/oauth/token
```

```json
{"access_token":"<jwt>","issued_token_type":"urn:ietf:params:oauth:token-type:access_token","token_type":"Bearer","expires_in":300,"scope":"kawa:ingest"}
```

The issued token's `sub` is the user, its `act` is the service account's backing user, its lifetime is
`serviceTokenConfig.ttl` (default 5 minutes), and it is **refresh-less**. The response always carries
`issued_token_type` (RFC 8693), always the access-token URN — the exchange issues access tokens only.

### Scope narrowing

The granted scopes are `requested ∩ (allowed_scopes \ token-exchange:subject)`. When the `scope`
parameter is absent it defaults to the account's whole allow-list minus the gate scope. A request for
a scope the account does not hold, or for the gate scope itself, yields an empty grant and
`invalid_scope`.

There is one deliberate asymmetry. When the **subject token carries a non-empty scope set**, the
grant must additionally be within it (`granted ⊆ subject.scopes`, else `invalid_scope`): the service
acts with no more authority than the user had. But **today's interactive user tokens carry empty
scopes by design** (Shōmei mints empty scope sets on login until role/scope enrichment populates
them), where empty means "unscoped interactive session", **not** "no authority" — treating it as a
bound would make on-behalf-of unusable. So an empty subject scope set imposes **no** bound; once user
tokens carry scopes, the subject bound engages automatically. The service ceiling
(`allowed_scopes`) is always enforced.

### The downstream contract

A resource server verifies the exchanged token exactly as it verifies any Shōmei token: fetch
`/.well-known/jwks.json`, verify the signature and claims offline, then read **`sub` for the user**
and **`act` for the acting service**. Attribute writes to `sub`, and log `act` so an audit trail
records which service acted. Note that inside Shōmei itself the token is a delegated token (it carries
`act`), so Shōmei's own credential-changing endpoints refuse it with `impersonation_action_blocked` —
a service acting for a user must not change that user's credentials. Chained exchanges are refused: a
token already carrying `act` cannot be presented as a `subject_token`.

Every successful exchange writes a `service_on_behalf_issued` audit event carrying the service's
`client_id`, the actor (its backing user), the subject user, the session, and the granted scopes.

The full endpoint reference is in [api.md](api.md#token-exchange-rfc-8693); the security model is in
[security.md](security.md#impersonation--delegated-tokens).

---

## The deprecated path: config-defined accounts

`POST /v1/auth/service-token` and the `serviceToken.accounts` configuration block still work
unchanged, and existing deployments keep running. **They are deprecated**: creating, rotating, or
revoking one of these credentials means editing configuration and redeploying, and no off-the-shelf
OAuth2 client can talk to the endpoint. Removal is a candidate for the next major version boundary.

An account is runtime configuration, not a database row:

- `accountId`: the public identifier the machine caller sends.
- `userId`: an existing Shōmei user id used as the JWT `sub`.
- `secretSha256`: a SHA-256 hex digest of the shared secret.
- `allowedScopes`: the coarse scopes this account may request.

Issuance is disabled by default (`serviceToken.enabled`). A successful request creates a session
row, signs an access token, returns `{"accessToken","expiresIn"}`, and returns no refresh token.
If `actorId` is supplied, Shōmei verifies that actor user exists and is active, then emits it as
the JWT `act` claim. (The database-backed path has no `actorId`: acting on behalf of a user is
what [token exchange](api.md) is for.)

Note that `serviceToken.enabled` gates **only** this endpoint. A database-backed account is
enabled by existing and disabled by being revoked; it is unaffected by that flag. The
`serviceToken.ttlSeconds` setting, by contrast, is shared — both paths mint tokens with the same
lifetime.

### Configure

Dhall:

```dhall
{ serviceToken =
    { enabled = True
    , ttlSeconds = 300
    , accounts =
        [ { accountId = "connector:kawa"
          , userId = "user_..."
          , secretSha256 = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
          , allowedScopes = [ "kawa:ingest" ]
          }
        ]
    }
}
```

Environment:

```bash
export SHOMEI_SERVICE_TOKEN_ENABLED=true
export SHOMEI_SERVICE_TOKEN_TTL=300
export SHOMEI_SERVICE_ACCOUNTS_JSON='[
  {
    "accountId": "connector:kawa",
    "userId": "user_...",
    "secretSha256": "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
    "allowedScopes": ["kawa:ingest"]
  }
]'
```

Generate a configured digest from a secret:

```bash
printf '%s' 'replace-with-long-random-secret' | shasum -a 256
```

Store only the hex digest in configuration. Keep the raw shared secret in your secret manager and
send it only in the token request.

### Request a token

```bash
curl -s -X POST http://localhost:8080/v1/auth/service-token \
  -H 'content-type: application/json' \
  -d '{
    "accountId": "connector:kawa",
    "secret": "replace-with-long-random-secret",
    "scopes": ["kawa:ingest"]
  }'
```

```json
{"accessToken": "eyJ...", "expiresIn": 300}
```

Unlike `/oauth/token`, this endpoint returns the [problem-details envelope](api.md) on failure:
unknown accounts, bad secrets, disabled issuance, and disallowed scopes are `403`; empty requested
scopes and malformed actor ids are `400`.

---

## Migrating from config accounts to `/oauth/token`

Do this one account at a time; the two paths coexist, so there is no flag day.

1. **Create the replacement**, with the same scopes the config account had:

    ```bash
    DATABASE_URL="$PG_CONNECTION_STRING" shomei-admin service-accounts create \
      --display-name "connector:kawa (migrated)" --scope kawa:ingest
    ```

2. **Hand the new `client_id` and `client_secret` to the consumer** through your secret manager.
   Note the `client_id` is a new, different identifier — the old `accountId` string does not carry
   over, and neither does the old `userId` (the new account gets its own backing user, so audit
   rows for the new account file under a different `sub`).

3. **Point the consumer at `/oauth/token`.** If it already has an OAuth2 client library, delete the
   hand-written token-fetching code and configure the library with the token URL, client id, and
   secret. Nothing else changes: the token it receives is the same shape, signed by the same key,
   and verifies against the same JWKS.

4. **Confirm** the consumer is minting tokens on the new path — the audit trail's
   `service_token_issued` events now name the new `client_id` in their `accountId` field.

5. **Delete the config entry** and redeploy. If it was the last one, set
   `serviceToken.enabled = False` to close the deprecated endpoint entirely.

Nothing in step 5 is urgent: a config account left in place keeps working.

## Security notes

- Secrets are compared in constant time against a SHA-256 digest, on both paths, through one
  function. They are not Argon2-hashed, deliberately: these secrets are 256 bits of CSPRNG output,
  never human-chosen, so there is no low-entropy preimage to slow down — and an Argon2 verification
  on every token request would be a self-inflicted denial-of-service vector.
- Tokens are short-lived and refresh-less. A `client_credentials` session never gets a refresh
  token, so the credential cannot outlive its TTL.
- A `client_id` is public. Only the secret is a secret.
- `/oauth/token` is not rate-limited. The per-IP limiter that guards `/v1/auth/login` exists to
  slow guessing of human-chosen passwords; a 256-bit random secret is not guessable online, and a
  fleet of services behind one egress IP would share a single bucket and throttle each other.
  If you want a bound here, apply it at your ingress, keyed on `client_id`.
