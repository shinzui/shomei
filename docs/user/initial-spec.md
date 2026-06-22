# Shōmei / 証明 — Technical Specification

## Overview

**Shōmei** is a Haskell authentication toolkit designed to support two deployment modes:

1. **Standalone authentication service** for microservice architectures.
2. **Embedded authentication library** for Servant-based monolithic applications.

The standalone service should be built from the same core primitives used by embedded applications.

## Name

**Shōmei**
Japanese: **証明**
Reading: **しょうめい**
Meaning: proof, verification, certification.

Authentication is fundamentally about proving identity and verifying claims, so **Shōmei** fits the domain well.

## Package Structure

```text
shomei-core
shomei-jwt
shomei-postgres
shomei-servant
shomei-server
shomei-client
```

## Goals

Shōmei should provide:

```text
User registration
Email/password login
Session management
Refresh token rotation
JWT access tokens
JWKS publishing
Token verification
Servant route protection
PostgreSQL persistence
Standalone auth service API
Embedded Servant integration
Audit/security events
```

Shōmei should not initially support:

```text
OAuth
OIDC
Social login
Magic links
Passkeys/WebAuthn
MFA
Full authorization policy engine
Admin UI
Organization/team management
```

## Design Principles

### Library-first

The standalone service should be a thin application layer over the reusable library.

```text
shomei-core
  ↓
shomei-jwt
  ↓
shomei-postgres
  ↓
shomei-servant
  ↓
shomei-server
```

### Transport-agnostic core

`shomei-core` should not depend on Servant, WAI, PostgreSQL, JWT libraries, cookies, or HTTP.

It should define domain types, commands, events, errors, and effects.

### Servant-native

Embedded usage should feel natural in a Servant app.

```haskell
type API =
  Authenticated AuthUser
    :> "me"
    :> Get '[JSON] AuthUser
```

### Microservice-ready

In standalone mode, Shōmei should issue locally verifiable access tokens.

Downstream services should verify JWTs using the auth service’s JWKS endpoint without calling the auth service on every request.

## Core Domain Model

### User

```haskell
newtype UserId = UserId UUID

data User = User
  { userId      :: UserId
  , email       :: Email
  , displayName :: Maybe Text
  , status      :: UserStatus
  , createdAt   :: UTCTime
  , updatedAt   :: UTCTime
  }

data UserStatus
  = UserActive
  | UserSuspended
  | UserDeleted
```

### Email

```haskell
newtype Email = Email Text
```

Email normalization:

```text
Trim whitespace
Lowercase domain
Lowercase full email for initial implementation
Reject invalid shape
```

Do not initially collapse Gmail dots or plus-addressing.

### Password

```haskell
newtype PlainPassword = PlainPassword Text
newtype PasswordHash = PasswordHash Text
```

Password hashing should use **Argon2id**.

Plain passwords should never be logged, serialized, or persisted.

### Credential

Initially, only password credentials are supported.

```haskell
newtype CredentialId = CredentialId UUID

data Credential = PasswordCredential
  { credentialId :: CredentialId
  , userId       :: UserId
  , email        :: Email
  , passwordHash :: PasswordHash
  , createdAt    :: UTCTime
  , updatedAt    :: UTCTime
  }
```

### Session

```haskell
newtype SessionId = SessionId UUID

data Session = Session
  { sessionId :: SessionId
  , userId    :: UserId
  , status    :: SessionStatus
  , createdAt :: UTCTime
  , expiresAt :: UTCTime
  , revokedAt :: Maybe UTCTime
  }

data SessionStatus
  = SessionActive
  | SessionRevoked
  | SessionExpired
```

Sessions should be persisted.

Access tokens should include the session ID.

### Refresh Token

Refresh tokens should be opaque random tokens.

Only the hash should be persisted.

```haskell
newtype RefreshToken = RefreshToken Text
newtype RefreshTokenHash = RefreshTokenHash Text
newtype RefreshTokenId = RefreshTokenId UUID

data PersistedRefreshToken = PersistedRefreshToken
  { refreshTokenId :: RefreshTokenId
  , sessionId      :: SessionId
  , tokenHash      :: RefreshTokenHash
  , parentTokenId  :: Maybe RefreshTokenId
  , status         :: RefreshTokenStatus
  , createdAt      :: UTCTime
  , expiresAt      :: UTCTime
  , usedAt         :: Maybe UTCTime
  , revokedAt      :: Maybe UTCTime
  }

data RefreshTokenStatus
  = RefreshTokenActive
  | RefreshTokenUsed
  | RefreshTokenRevoked
  | RefreshTokenExpired
```

Refresh tokens should be rotated on every refresh.

If a previously used refresh token is presented again, Shōmei should treat it as possible token theft and revoke the session.

### Access Token

Access tokens should be signed JWTs.

```haskell
newtype AccessToken = AccessToken Text
```

Recommended default:

```text
Access token TTL: 15 minutes
```

### Token Pair

```haskell
data TokenPair = TokenPair
  { accessToken  :: AccessToken
  , refreshToken :: RefreshToken
  , expiresIn    :: NominalDiffTime
  }
```

### Auth Claims

```haskell
newtype Issuer = Issuer Text
newtype Audience = Audience Text
newtype Scope = Scope Text
newtype Role = Role Text

data AuthClaims = AuthClaims
  { subject   :: UserId
  , sessionId :: SessionId
  , issuer    :: Issuer
  , audience  :: Audience
  , issuedAt  :: UTCTime
  , expiresAt :: UTCTime
  , scopes    :: Set Scope
  , roles     :: Set Role
  }
```

## Core Effects

### User Store

```haskell
class Monad m => UserStore m where
  createUser :: NewUser -> m User
  findUserById :: UserId -> m (Maybe User)
  findUserByEmail :: Email -> m (Maybe User)
  updateUserStatus :: UserId -> UserStatus -> m ()
```

### Credential Store

```haskell
class Monad m => CredentialStore m where
  createPasswordCredential :: UserId -> Email -> PasswordHash -> m Credential
  findPasswordCredentialByEmail :: Email -> m (Maybe Credential)
  updatePasswordHash :: UserId -> PasswordHash -> m ()
```

### Session Store

```haskell
class Monad m => SessionStore m where
  createSession :: NewSession -> m Session
  findSessionById :: SessionId -> m (Maybe Session)
  revokeSession :: SessionId -> UTCTime -> m ()
  revokeAllUserSessions :: UserId -> UTCTime -> m ()
```

### Refresh Token Store

```haskell
class Monad m => RefreshTokenStore m where
  createRefreshToken :: NewRefreshToken -> m PersistedRefreshToken
  findRefreshTokenByHash :: RefreshTokenHash -> m (Maybe PersistedRefreshToken)
  markRefreshTokenUsed :: RefreshTokenId -> UTCTime -> m ()
  revokeRefreshTokenFamily :: RefreshTokenId -> UTCTime -> m ()
  revokeSessionRefreshTokens :: SessionId -> UTCTime -> m ()
```

### Password Hasher

```haskell
class Monad m => PasswordHasher m where
  hashPassword :: PlainPassword -> m PasswordHash
  verifyPassword :: PlainPassword -> PasswordHash -> m Bool
```

### Token Signer

```haskell
class Monad m => TokenSigner m where
  signAccessToken :: AuthClaims -> m AccessToken
```

### Token Verifier

```haskell
class Monad m => TokenVerifier m where
  verifyAccessToken :: AccessToken -> m (Either TokenError AuthClaims)
```

### Event Publisher

```haskell
class Monad m => AuthEventPublisher m where
  publishAuthEvent :: AuthEvent -> m ()
```

## Commands

```haskell
data SignupCommand = SignupCommand
  { email       :: Email
  , password    :: PlainPassword
  , displayName :: Maybe Text
  }

data LoginCommand = LoginCommand
  { email    :: Email
  , password :: PlainPassword
  }

data RefreshCommand = RefreshCommand
  { refreshToken :: RefreshToken
  }

data LogoutCommand = LogoutCommand
  { sessionId :: SessionId
  }
```

## Events

```haskell
data AuthEvent
  = UserRegistered UserRegisteredData
  | LoginSucceeded LoginSucceededData
  | LoginFailed LoginFailedData
  | SessionStarted SessionStartedData
  | SessionRevoked SessionRevokedData
  | RefreshTokenRotated RefreshTokenRotatedData
  | RefreshTokenReuseDetected RefreshTokenReuseDetectedData
  | PasswordChanged PasswordChangedData
  | UserSuspended UserSuspendedData
  | UserDeleted UserDeletedData
```

Events are useful for:

```text
Audit logs
Security alerts
Analytics
User notifications
Session management
Cross-service synchronization
```

## Errors

```haskell
data AuthError
  = InvalidEmail
  | WeakPassword PasswordPolicyViolation
  | EmailAlreadyRegistered
  | InvalidCredentials
  | UserNotActive
  | SessionNotFound
  | SessionExpired
  | SessionRevoked
  | RefreshTokenInvalid
  | RefreshTokenExpired
  | RefreshTokenReuseDetected
  | TokenInvalid TokenError
  | InternalAuthError Text
```

For login, the public API should return:

```text
Invalid email or password
```

Do not reveal whether the email exists.

## Workflows

### Signup

```text
Receive email, password, display name
Normalize email
Validate email
Validate password policy
Check email uniqueness
Hash password
Create user
Create password credential
Create session
Create refresh token
Issue access token
Publish UserRegistered
Publish SessionStarted
Return token pair and user
```

### Login

```text
Receive email and password
Normalize email
Look up password credential by email
If missing, return generic InvalidCredentials
Look up user
Check user status
Verify password
If invalid, publish LoginFailed and return generic InvalidCredentials
Create session
Create refresh token
Issue access token
Publish LoginSucceeded
Publish SessionStarted
Return token pair and user
```

### Refresh Token Rotation

```text
Receive refresh token
Hash refresh token
Find persisted refresh token by hash
Check token exists
Check token is active
Check token is not expired
Find session
Check session is active
Mark old refresh token as used
Create child refresh token
Issue new access token
Publish RefreshTokenRotated
Return new token pair
```

If a used refresh token is presented:

```text
Detect reuse
Revoke refresh token family
Revoke session
Publish RefreshTokenReuseDetected
Return error
```

### Logout

```text
Receive authenticated session
Revoke session
Revoke all refresh tokens for session
Publish SessionRevoked
Clear cookie if using cookie transport
Return 204 No Content
```

### Token Verification

```text
Extract access token from Authorization header or cookie
Verify JWT signature
Validate issuer
Validate audience
Validate expiry
Decode claims
Optionally check session status
Attach AuthUser to request
```

For microservices, the default should be local JWT verification only.

For monoliths, checking the session store on protected routes can be configurable.

## Standalone HTTP API

```text
POST /auth/signup
POST /auth/login
POST /auth/refresh
POST /auth/logout
GET  /auth/me
GET  /auth/session
GET  /.well-known/jwks.json
GET  /health
```

### Signup

```http
POST /auth/signup
```

Request:

```json
{
  "email": "nadeem@example.com",
  "password": "correct horse battery staple",
  "displayName": "Nadeem"
}
```

Response:

```json
{
  "user": {
    "userId": "uuid",
    "email": "nadeem@example.com",
    "displayName": "Nadeem",
    "status": "active"
  },
  "token": {
    "accessToken": "jwt",
    "refreshToken": "opaque-refresh-token",
    "expiresIn": 900
  }
}
```

### Login

```http
POST /auth/login
```

Request:

```json
{
  "email": "nadeem@example.com",
  "password": "correct horse battery staple"
}
```

Response:

```json
{
  "user": {
    "userId": "uuid",
    "email": "nadeem@example.com",
    "displayName": "Nadeem",
    "status": "active"
  },
  "token": {
    "accessToken": "jwt",
    "refreshToken": "opaque-refresh-token",
    "expiresIn": 900
  }
}
```

### Refresh

```http
POST /auth/refresh
```

Request:

```json
{
  "refreshToken": "opaque-refresh-token"
}
```

Response:

```json
{
  "accessToken": "new-jwt",
  "refreshToken": "new-opaque-refresh-token",
  "expiresIn": 900
}
```

### Logout

```http
POST /auth/logout
Authorization: Bearer <access-token>
```

Response:

```http
204 No Content
```

### Current User

```http
GET /auth/me
Authorization: Bearer <access-token>
```

### Current Session

```http
GET /auth/session
Authorization: Bearer <access-token>
```

### JWKS

```http
GET /.well-known/jwks.json
```

Used by downstream services to verify JWT access tokens locally.

## Servant API Shape

```haskell
type ShomeiAPI =
       "auth" :> "signup"
          :> ReqBody '[JSON] SignupRequest
          :> Post '[JSON] SignupResponse

  :<|> "auth" :> "login"
          :> ReqBody '[JSON] LoginRequest
          :> Post '[JSON] LoginResponse

  :<|> "auth" :> "refresh"
          :> ReqBody '[JSON] RefreshRequest
          :> Post '[JSON] TokenPair

  :<|> "auth" :> "logout"
          :> Authenticated AuthUser
          :> PostNoContent

  :<|> "auth" :> "me"
          :> Authenticated AuthUser
          :> Get '[JSON] User

  :<|> "auth" :> "session"
          :> Authenticated AuthUser
          :> Get '[JSON] Session

  :<|> ".well-known" :> "jwks.json"
          :> Get '[JSON] JWKS

  :<|> "health"
          :> Get '[JSON] HealthResponse
```

Embedded app usage:

```haskell
type AppAPI =
       "auth" :> ShomeiAPI
  :<|> Authenticated AuthUser
          :> "projects"
          :> Get '[JSON] [Project]
```

## Servant Authentication Model

```haskell
data AuthUser = AuthUser
  { authUserId    :: UserId
  , authSessionId :: SessionId
  , authRoles     :: Set Role
  , authScopes    :: Set Scope
  , authClaims    :: AuthClaims
  }
```

Recommended MVP combinator:

```haskell
type Authenticated = Auth '[JWT] AuthUser
```

Scope helpers:

```haskell
data RequireScope (scope :: Symbol)
data RequireRole (role :: Symbol)
```

Example:

```haskell
type AdminAPI =
  RequireRole "admin"
    :> Authenticated AuthUser
    :> "admin"
    :> "users"
    :> Get '[JSON] [User]
```

## PostgreSQL Schema

### Users

```sql
CREATE TABLE shomei_users (
  user_id UUID PRIMARY KEY,
  email TEXT NOT NULL UNIQUE,
  display_name TEXT NULL,
  status TEXT NOT NULL,
  created_at TIMESTAMPTZ NOT NULL,
  updated_at TIMESTAMPTZ NOT NULL
);
```

### Password Credentials

```sql
CREATE TABLE shomei_password_credentials (
  credential_id UUID PRIMARY KEY,
  user_id UUID NOT NULL REFERENCES shomei_users(user_id),
  email TEXT NOT NULL UNIQUE,
  password_hash TEXT NOT NULL,
  created_at TIMESTAMPTZ NOT NULL,
  updated_at TIMESTAMPTZ NOT NULL
);
```

### Sessions

```sql
CREATE TABLE shomei_sessions (
  session_id UUID PRIMARY KEY,
  user_id UUID NOT NULL REFERENCES shomei_users(user_id),
  status TEXT NOT NULL,
  created_at TIMESTAMPTZ NOT NULL,
  expires_at TIMESTAMPTZ NOT NULL,
  revoked_at TIMESTAMPTZ NULL
);

CREATE INDEX shomei_sessions_user_id_idx
  ON shomei_sessions(user_id);

CREATE INDEX shomei_sessions_status_idx
  ON shomei_sessions(status);
```

### Refresh Tokens

```sql
CREATE TABLE shomei_refresh_tokens (
  refresh_token_id UUID PRIMARY KEY,
  session_id UUID NOT NULL REFERENCES shomei_sessions(session_id),
  token_hash TEXT NOT NULL UNIQUE,
  parent_token_id UUID NULL REFERENCES shomei_refresh_tokens(refresh_token_id),
  status TEXT NOT NULL,
  created_at TIMESTAMPTZ NOT NULL,
  expires_at TIMESTAMPTZ NOT NULL,
  used_at TIMESTAMPTZ NULL,
  revoked_at TIMESTAMPTZ NULL
);

CREATE INDEX shomei_refresh_tokens_session_id_idx
  ON shomei_refresh_tokens(session_id);

CREATE INDEX shomei_refresh_tokens_parent_token_id_idx
  ON shomei_refresh_tokens(parent_token_id);

CREATE INDEX shomei_refresh_tokens_status_idx
  ON shomei_refresh_tokens(status);
```

### Signing Keys

```sql
CREATE TABLE shomei_signing_keys (
  key_id TEXT PRIMARY KEY,
  algorithm TEXT NOT NULL,
  public_key_pem TEXT NOT NULL,
  private_key_pem_encrypted TEXT NOT NULL,
  status TEXT NOT NULL,
  created_at TIMESTAMPTZ NOT NULL,
  activated_at TIMESTAMPTZ NULL,
  retired_at TIMESTAMPTZ NULL
);
```

Statuses:

```text
pending
active
retired
revoked
```

### Auth Events

```sql
CREATE TABLE shomei_auth_events (
  event_id UUID PRIMARY KEY,
  user_id UUID NULL,
  session_id UUID NULL,
  event_type TEXT NOT NULL,
  payload JSONB NOT NULL,
  created_at TIMESTAMPTZ NOT NULL
);

CREATE INDEX shomei_auth_events_user_id_idx
  ON shomei_auth_events(user_id);

CREATE INDEX shomei_auth_events_session_id_idx
  ON shomei_auth_events(session_id);

CREATE INDEX shomei_auth_events_event_type_idx
  ON shomei_auth_events(event_type);

CREATE INDEX shomei_auth_events_created_at_idx
  ON shomei_auth_events(created_at);
```

## Configuration

```haskell
data ShomeiConfig = ShomeiConfig
  { issuer              :: Issuer
  , audience            :: Audience
  , accessTokenTTL      :: NominalDiffTime
  , refreshTokenTTL     :: NominalDiffTime
  , sessionTTL          :: NominalDiffTime
  , passwordPolicy      :: PasswordPolicy
  , tokenTransport      :: TokenTransport
  , signingKeyConfig    :: SigningKeyConfig
  , sessionCheckMode    :: SessionCheckMode
  }
```

### Token Transport

```haskell
data TokenTransport
  = BearerToken
  | HttpOnlyCookie
  | BearerAndCookie
```

Recommended defaults:

```text
API clients: BearerToken
Browser apps: HttpOnlyCookie
Mixed apps: BearerAndCookie
```

### Session Check Mode

```haskell
data SessionCheckMode
  = VerifyTokenOnly
  | VerifyTokenAndSession
```

Recommended defaults:

```text
Standalone downstream services: VerifyTokenOnly
Embedded monolith: VerifyTokenAndSession
```

### Default TTLs

```text
Access token TTL: 15 minutes
Refresh token TTL: 30 days
Session TTL: 30 days
JWKS cache TTL: 5–30 minutes
```

## Security Requirements

### Passwords

```text
Use Argon2id
Never store plaintext passwords
Never log passwords
Validate password strength
Use constant-time password verification where applicable
Return generic login errors
```

### Refresh Tokens

```text
Use opaque random tokens
Store only token hashes
Rotate refresh tokens on every use
Detect reuse
Revoke token family on reuse
Revoke session on reuse
```

### Access Tokens

```text
Use short-lived JWTs
Validate issuer
Validate audience
Validate expiry
Use asymmetric signing for microservice mode
Publish public keys via JWKS
Support key rotation
```

### Cookies

If using cookies:

```text
HttpOnly
Secure
SameSite=Lax or SameSite=Strict by default
Configurable domain
Configurable path
CSRF protection for unsafe methods
```

## Authorization Scope

Shōmei should include minimal authorization primitives only.

MVP:

```text
Roles in claims
Scopes in claims
RequireRole helper
RequireScope helper
```

Do not build:

```text
RBAC admin UI
Policy engine
Permission graph
Organization membership system
```

## Microservice Deployment Model

```text
              ┌────────────────────┐
              │   shomei-server     │
              │ authentication svc  │
              └─────────┬──────────┘
                        │
                        │ publishes JWKS
                        ▼
              /.well-known/jwks.json

┌────────────────────┐      ┌────────────────────┐
│ project-service     │      │ billing-service     │
│ verifies JWT locally│      │ verifies JWT locally│
└────────────────────┘      └────────────────────┘

┌────────────────────┐
│ notification-service│
│ verifies JWT locally│
└────────────────────┘
```

Normal request path:

```text
Client sends access token to downstream service
Downstream service verifies JWT locally
Downstream service uses claims as AuthUser
No auth-service network call required
```

Refresh/login/logout path:

```text
Client talks directly to shomei-server
```

## Embedded Monolith Model

```text
┌──────────────────────────────────────┐
│ Servant application                   │
│                                      │
│  ┌──────────────┐                    │
│  │ App API      │                    │
│  └──────┬───────┘                    │
│         │                            │
│  ┌──────▼───────┐                    │
│  │ shomei       │                    │
│  │ embedded auth│                    │
│  └──────┬───────┘                    │
│         │                            │
│  ┌──────▼───────┐                    │
│  │ PostgreSQL   │                    │
│  └──────────────┘                    │
└──────────────────────────────────────┘
```

## MVP Milestone

The first milestone should prove the full vertical slice.

### MVP Features

```text
Create user
Login with email/password
Create session
Issue JWT access token
Issue opaque refresh token
Persist refresh token hash
Refresh access token
Rotate refresh token
Detect refresh token reuse
Logout
Protect a Servant route
Publish JWKS
Verify token from another service
PostgreSQL persistence
Basic audit events
```

### MVP Packages

```text
shomei-core
shomei-jwt
shomei-postgres
shomei-servant
shomei-server
```

### MVP Demo Apps

```text
examples/embedded-servant-app
examples/microservice-auth-stack
```

Embedded demo:

```text
One Servant app
Uses shomei embedded
Signup/login/logout routes mounted inside app
Protected /me route
Protected /projects route
```

Microservice demo:

```text
shomei-server
example-project-service
project-service verifies JWT using JWKS
project-service exposes protected /projects route
```

## Deferred Features

Do not support these initially:

```text
OAuth
OIDC
Google login
GitHub login
Apple login
Microsoft login
Magic links
Passkeys/WebAuthn
MFA
Device management
Admin UI
Organization membership
Team auth
Fine-grained permission engine
Risk scoring
Anomaly detection
```

## Suggested Repo Layout

```text
shomei/
  cabal.project
  flake.nix

  packages/
    shomei-core/
    shomei-jwt/
    shomei-postgres/
    shomei-servant/
    shomei-server/
    shomei-client/

  examples/
    embedded-servant-app/
    microservice-auth-stack/

  migrations/
    postgres/

  docs/
    architecture.md
    api.md
    security.md
    deployment.md
```

## Open Questions

### Token transport

Should the default browser mode be HTTP-only cookies or bearer tokens returned in JSON?

Recommendation:

```text
Support both, but default examples should use HTTP-only cookies for browser apps and bearer tokens for service/API clients.
```

### Session verification

Should protected routes check the database session on every request?

Recommendation:

```text
Embedded monolith: yes, configurable.
Microservice downstream services: no, verify JWT locally.
```

### Event storage

Should auth events be stored in a regular audit table or event-sourced through MessageDB?

Recommendation:

```text
Start with an AuthEventPublisher effect.
Provide a PostgreSQL audit implementation first.
Add MessageDB implementation later.
```

### Authorization

Should roles/scopes live in Shōmei or in application code?

Recommendation:

```text
Shōmei should carry roles/scopes in claims and provide simple checks.
Application-specific authorization should live outside Shōmei.
```

## One-line Summary

**Shōmei** is a Haskell authentication toolkit that can run as a standalone auth service or embed directly into Servant applications, with password login, sessions, refresh token rotation, JWT verification, JWKS publishing, and PostgreSQL persistence.

