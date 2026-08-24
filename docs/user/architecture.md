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
  effects,           JWKS)          Argon2id)           handlers,           shomei-admin,
  workflows)                                            combinators)        middleware, config)
```

## Effects and interpreters

Each effect interface lives in `shomei-core/src/Shomei/Effect/*` as a GADT of operations plus a
`send`-based smart constructor — for example `UserStore`, `CredentialStore`, `SessionStore`,
`RefreshTokenStore`, `VerificationTokenStore`, `PasswordResetTokenStore`, `LoginAttemptStore`,
`SigningKeyStore`, `PasswordHasher`, `TokenSigner`, `TokenVerifier`, `TokenGen`, `Clock`,
`AuthEventPublisher`, and `Notifier`.

There are two interpreter assemblies for the same canonical effect stack (`AppEffects`):

- **In-memory** (`shomei-core/src/Shomei/Test/InMemory.hs`) — a single mutable `World` in an
  `IORef`, used by the pure test suites. No database, JWT library, or network.
- **Production** (`shomei-server`/`runAppIO`) — the `hasql` PostgreSQL interpreters plus the real
  `jose` signer/verifier (ES256 by default, RS256 selectable). The servant in-process test uses a
  *hybrid* (in-memory stores + real ES256) so signing is genuinely exercised.

Because the workflows depend only on the interface order, the identical `signup`/`login`/`refresh`
/account-lifecycle code runs unchanged over either assembly. The same property is the extension
point for email: Shōmei emits account-lifecycle notifications through the `Notifier` effect and
ships only a dev log sender — to deliver them through your provider you supply your own `Notifier`
interpreter (see [notifications.md](notifications.md)).

## The workflows

Concept-first workflow modules hold the behavioral heart: for example,
`Shomei.Session.Authentication.Workflow`, `Shomei.Account.Lifecycle.Workflow`,
`Shomei.Passkey.Workflow`, `Shomei.Mfa.Workflow`, and `Shomei.OAuth.TokenGrant.Workflow`.
They implement signup/login, refresh rotation and reuse detection, lifecycle flows, passkey/MFA
ceremonies, token exchange, and OAuth machine-token issuance. They short-circuit on the first
`AuthError` and publish audit events. There is intentionally no aggregate `Shomei.Workflow`
re-export.

## The HTTP layer

`shomei-servant` composes concept-owned `Api`, `Dto`, `Result`, and `Handler` modules into the thin
`ShomeiRoutes` `NamedRoutes` root. The seam (`Shomei.Servant.Seam`) preserves
`Either AuthError`; each application handler maps expected failures to a typed `ApplicationResult`
constructor, while OAuth handlers use their protocol result sum. The `Authenticated` combinator
guards protected routes; `RequireRole`/`RequireScope`/`RequirePermission`/`RequireAdmin` express
authorization and contribute their pre-handler responses to OpenAPI.

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
password policy, token transport, session-check mode, signing algorithm, notifier, rate-limit,
observability, WebAuthn, delegation, and machine-token sub-records). `Shomei.Server.Config`
assembles the standalone server subset from defaults, an optional typed Dhall file
(`$SHOMEI_CONFIG`), and environment variables — see [deployment.md](deployment.md).
