# Shōmei User Documentation

This directory contains the user-facing documentation for running Shōmei, embedding it in a
Haskell service, and integrating client applications.

## Start Here

- [Architecture](architecture.md) explains the package layout, effect ports, interpreters, and
  standalone-vs-embedded model.
- [Deployment](deployment.md) covers local development, production container startup,
  configuration, migrations, key rotation, and operational endpoints.
- [HTTP API](api.md) lists every standalone server endpoint with request and response shapes.

## Feature Guides

- [Passkeys & MFA](passkeys.md) covers passkey enrollment, password-plus-passkey step-up,
  passwordless login, WebAuthn configuration, and the browser demo.
- [Service Tokens](service-tokens.md) covers machine-to-machine scoped token issuance for
  connectors, agents, and downstream services.
- [OpenID Connect](oidc.md) covers running Shōmei as an OIDC provider: discovery, the
  authorization-code flow with PKCE, ID tokens, userinfo, introspection, and revocation, plus the
  headless authorize contract and a worked oauth2-proxy configuration.
- [Notifications](notifications.md) explains the `Notifier` effect and how to deliver email
  verification and password-reset links through your own provider.
- [Security Model](security.md) summarizes password hashing, token handling, session revocation,
  key rotation, signing-key encryption at rest, cookie transport and CSRF defenses,
  lockout/rate limits, audit logging, impersonation, passkeys, and service tokens.
- [Client & Examples](client-and-examples.md) shows the typed Haskell client and the two runnable
  example applications.
- [Generating API Clients](openapi-client-generation.md) explains the committed OpenAPI 3.1 schema
  (`docs/api/openapi.json`) and how to generate typed clients in TypeScript, Python, Go, and other
  languages.

## Historical Reference

- [Initial Spec](initial-spec.md) is the original project specification. It is useful context, but
  the guides above describe the current implemented behavior.
