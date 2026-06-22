# Service Tokens

Service tokens are short-lived, refresh-less access tokens for machine callers such as connectors,
agent runtimes, and downstream services. They are separate from human login: normal signup/login
tokens still carry empty scopes, while `POST /auth/service-token` can mint a token with configured
coarse scopes such as `kawa:ingest`, `signal:raise`, or `channel:egress`.

The HTTP reference is in [api.md](api.md#post-authservice-token). This guide focuses on operating
and consuming the feature.

## Model

A service account is runtime configuration, not a database row. Each account maps:

- `accountId`: the public identifier the machine caller sends.
- `userId`: an existing Shōmei user id used as the JWT `sub`.
- `secretSha256`: a SHA-256 hex digest of the shared secret.
- `allowedScopes`: the coarse scopes this account may request.

Issuance is disabled by default. A successful request creates a session row, signs an access token,
returns `{"accessToken","expiresIn"}`, and does not return a refresh token. The caller must request
only scopes in the configured allow-list. If `actorId` is supplied, Shōmei verifies that actor user
exists and is active, then emits it as the JWT `act` claim.

## Configure

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

## Request a Token

```bash
curl -s -X POST http://localhost:8080/auth/service-token \
  -H 'content-type: application/json' \
  -d '{
    "accountId": "connector:kawa",
    "secret": "replace-with-long-random-secret",
    "scopes": ["kawa:ingest"]
  }'
```

The response is:

```json
{
  "accessToken": "eyJ...",
  "expiresIn": 300
}
```

Use the returned access token as a bearer token against downstream routes that verify Shōmei's JWKS
and enforce `requireScope (Scope "kawa:ingest")`.

## Security Notes

- Unknown accounts, bad secrets, disabled issuance, and disallowed scopes return `403`.
- Empty requested scopes and malformed actor ids return `400`.
- Secrets are hashed with SHA-256 and compared in constant time.
- Tokens are short-lived and refresh-less, so callers must request a new token after expiry.
- Every successful issuance writes a `service_token_issued` audit event.
