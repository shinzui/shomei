# Shōmei Architecture

## Library-first, transport-agnostic core

Shōmei is built so the same authentication logic powers both a standalone HTTP service and an
embedded library. The design principle: the **core knows nothing about HTTP, SQL, or JWTs**. It
expresses every external capability it needs (store a user, hash a password, sign a token, tell
the time, publish an audit event, send a notification, record a login attempt) as an `effectful`
**dynamic effect** — an interface — and the auth workflows are written purely against those
interfaces. Concrete *interpreters* supply meaning at the edges.

```text
shomei-core  ──>  shomei-jwt / shomei-postgres  ──>  shomei-servant  ──>  shomei-server
 (domain,           (ES256 JWT,    (hasql adapters,    (ShomeiAPI,         (warp exe,
  effects,           JWKS)          Argon2id)           handlers,           shomei-admin,
  workflows)                                            combinators)        middleware, config)
```

## Effects and interpreters

Each effect interface lives beside the concept it serves, usually in a
`shomei-core/src/Shomei/<Concept>/…/Store.hs` module, as a GADT of operations plus a `send`-based
smart constructor. Examples include `Shomei.Session.Store`, `Shomei.Account.User.Store`, and
`Shomei.SigningKey.Store`; the non-store ports include `Shomei.SigningKey.Signer`,
`Shomei.SigningKey.Verifier`, `Shomei.Session.Token.Generator`, `Shomei.Time.Store`, and
`Shomei.Audit.Publisher.Store`. The surviving `Shomei.Effect` directory contains shared effect
machinery, not the interfaces themselves.

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
order (outermost first): **trusted-proxy client resolution → request-id + structured logging →
HTTP metrics → `/metrics` endpoint → metered body cap → per-IP rate limiter → the Servant app**
(IP-4). The proxy rewrite is outermost so every downstream consumer sees one canonical client;
the metrics endpoint remains inside request logging but bypasses the body cap, limiter, and router.
The body cap meters chunks as the application reads them, so oversized or chunked requests cannot
escape the limit by omitting `Content-Length`.

Embedded hosts receive the same edge through `hostMiddleware`, which must wrap the host's whole WAI
application. They install signing-key reload, expiry sweeping, notification delivery, and startup
role validation once with `installHostBackgroundTasks`, then call the returned
`stopHostBackgroundTasks` after the HTTP server drains. This explicit two-part contract keeps the
bare Servant application composable without silently dropping the standalone server's runtime
protections. The package also hosts the `shomei-admin` CLI and the configuration loader.

## Persistence and migrations

All state lives in the `shomei` PostgreSQL schema, managed by `pg-migrate` migrations under
`shomei-migrations/migrations/shomei/`, ordered by the `manifest` file beside them and embedded at
compile time. `pg-migrate` records what it has applied in its own `pgmigrate` schema, so the
`shomei` schema holds application tables only. Identifiers are TypeID-style
prefixed UUIDv7 values (`mmzk-typeid`) stored in native `uuid` columns; statuses are `text`;
timestamps are `timestamptz`.

## Configuration

`Shomei.Config.ShomeiConfig` is the transport-agnostic runtime config (issuer, audience, TTLs,
password policy, token transport, session-check mode, signing algorithm, notifier, rate-limit,
observability, WebAuthn, delegation, and machine-token sub-records). `Shomei.Server.Config`
assembles the standalone server subset from defaults, an optional typed Dhall file
(`$SHOMEI_CONFIG`), and environment variables — see [deployment.md](deployment.md).
