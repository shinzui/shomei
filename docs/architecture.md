# Shōmei Architecture

## Library-first, transport-agnostic core

Shōmei is built so the same authentication logic powers both a standalone HTTP service and an
embedded library. The design principle: the **core knows nothing about HTTP, SQL, or JWTs**. It
expresses every external capability it needs (store a user, hash a password, sign a token, tell
the time, publish an audit event, send a notification, record a login attempt) as an `effectful`
**dynamic effect** — an interface — and the auth workflows are written purely against those
interfaces. Concrete *interpreters* supply meaning at the edges.

```
shomei-core  ──>  shomei-jwt / shomei-postgres  ──>  shomei-servant  ──>  shomei-server
 (domain,           (ES256 JWT,    (hasql adapters,    (ShomeiAPI,         (warp exe,
  ports,             JWKS)          Argon2id)           handlers,           shomei-admin,
  workflows)                                            combinators)        middleware, config)
```

## Ports and interpreters

Each effect interface lives in `shomei-core/src/Shomei/Effect/*` as a GADT of operations plus a
`send`-based smart constructor — for example `UserStore`, `CredentialStore`, `SessionStore`,
`RefreshTokenStore`, `VerificationTokenStore`, `PasswordResetTokenStore`, `LoginAttemptStore`,
`SigningKeyStore`, `PasswordHasher`, `TokenSigner`, `TokenVerifier`, `TokenGen`, `Clock`,
`AuthEventPublisher`, and `Notifier`.

There are two interpreter assemblies for the same canonical effect stack (`AppEffects`):

- **In-memory** (`shomei-core/src/Shomei/Effect/InMemory.hs`) — a single mutable `World` in an
  `IORef`, used by the pure test suites. No database, JWT library, or network.
- **Production** (`shomei-server`/`runAppIO`) — the `hasql` PostgreSQL interpreters plus the real
  `jose` signer/verifier. The servant in-process test uses a *hybrid* (in-memory stores + real
  ES256) so signing is genuinely exercised.

Because the workflows depend only on the interface order, the identical `signup`/`login`/`refresh`
/account-lifecycle code runs unchanged over either assembly. The same property is the extension
point for email: Shōmei emits account-lifecycle notifications through the `Notifier` effect and
ships only a dev log sender — to deliver them through your provider you supply your own `Notifier`
interpreter (see [notifications.md](notifications.md)).

## The workflows

`shomei-core/src/Shomei/Workflow.hs` and `Shomei.Workflow.Account` hold the behavioral heart:
`signup`, `login` (with the EP-2 lockout/throttle gates), `refresh` (rotation with reuse
detection), `logout`, `verifyToken`, and the account-lifecycle flows
(`requestEmailVerification`/`confirm`, `requestPasswordReset`/`confirm`, `changePassword`). They
short-circuit on the first `AuthError` and publish `AuthEvent`s for audit.

## The HTTP layer

`shomei-servant` defines `ShomeiAPI` as a Servant `NamedRoutes` record and the handlers that map
DTOs to workflow commands through a thin **seam** (`Shomei.Servant.Seam`) that runs a workflow in
the `AppEffects` stack and maps a `Left AuthError` to a `ServerError`. The `Authenticated`
combinator guards protected routes; `RequireRole`/`RequireScope` express authorization.

`shomei-server` assembles the warp `Application` and wraps it in the WAI middleware stack, in this
order (outermost first): **request-id + structured logging → HTTP metrics → `/metrics` endpoint →
per-IP rate limiter → the Servant app** (IP-4). It also hosts the `shomei-admin` CLI and the
configuration loader.

## Persistence and migrations

All state lives in the `shomei` PostgreSQL schema, managed by timestamped `codd` migrations under
`shomei-migrations/sql-migrations/` (embedded at compile time). Identifiers are TypeID-style
prefixed UUIDv7 values (`mmzk-typeid`) stored in native `uuid` columns; statuses are `text`;
timestamps are `timestamptz`.

## Configuration

`Shomei.Config.ShomeiConfig` is the transport-agnostic runtime config (issuer, audience, TTLs,
password policy, notifier, rate-limit, observability sub-records). `Shomei.Server.Config`
assembles it from defaults, an optional typed Dhall file (`$SHOMEI_CONFIG`), and environment
variables — see [deployment.md](deployment.md).
