---
type: Architecture Decision Record
title: Sessions carry their provenance and only an interactive session may authorize a client
description: Every session records whether a human established it, and OAuth authorization codes are minted only for live interactive sessions.
docId: ADR-1
status: Accepted
date: 2026-08-27
originatingPlan: docs/plans/51-bind-sessions-to-their-provenance-and-refuse-non-interactive-tokens-at-oauth-authorize.md
generated:
  by: openai-codex/gpt-5
  at: 2026-08-27T14:25:33Z
---

# Sessions carry their provenance and only an interactive session may authorize a client

## Context

Interactive users, service accounts, and delegated actors share one token verifier and the same
`sub`-keyed identity model in downstream services. Before this decision, a stored session did not
record which credential class established it. The authorization-code flow therefore could not
distinguish a human login from a machine or delegated credential: any verifying token could mint a
fresh, refreshable, fully enriched interactive session.

The August 2026 security review identified the resulting laundering path as critical. An operator
could impersonate a user and present the delegated token at `GET /oauth/authorize`; a service could
do the same with a `client_credentials` token. Authorization-code exchange then removed the actor
provenance and issued the subject an ordinary refreshable session.

## Decision

Every session carries a `kind` chosen by its minting path: `interactive`, `machine`, or
`delegated`. Signup, password and passkey login, MFA completion, and authorization-code exchange
mint interactive sessions. `client_credentials` mints machine sessions. Impersonation and RFC 8693
on-behalf-of exchange mint delegated sessions. The kind is never a caller-supplied option.

`GET /oauth/authorize` mints a code only when the presented token carries no `act` claim and its
stored session is live and interactive. It reads the session in every `sessionCheckMode`; the
deployment's stateless-request setting cannot weaken this privilege boundary.

Operations that mint new privilege from a presented token are likewise session-aware in every
mode. RFC 8693 exchange verifies the subject or actor token's session. Impersonation additionally
requires the operator's session to be live and the operator account to remain active.

## Consequences

A delegated or machine credential can never become an ordinary session through the
authorization-code flow. Missing, revoked, and expired sessions stop authorization and
privilege-minting exchanges immediately even when ordinary authenticated routes verify JWTs
statelessly.

The interactive/non-interactive boundary is persisted as a column. Every future session-minting
path must choose a kind, and the required record field makes forgetting a compile-time error.
Existing rows remain interactive through the migration's nullable default and read fallback.

Authorize, token exchange, and impersonation each pay a session-store read. These are deliberate
reads at privilege-minting boundaries, independent of the performance choice made for ordinary
requests. [EP-2](../plans/52-bind-oauth-sessions-to-their-client-and-govern-privilege-scopes.md)
builds client binding and reserved-scope policy on this boundary.

## Alternatives rejected

Refusing only tokens carrying `act` is insufficient because a `client_credentials` token has no
actor claim. It is still a machine credential and must not authorize a user session.

Encoding provenance only as a JWT claim would make the decision stateless and uncorrectable.
Revocation could not change it, and tokens minted before the claim existed would be
unclassifiable. The stored session is the authoritative, revocable provenance record.

Checking provenance only when `sessionCheckMode = VerifyTokenAndSession` would leave the default
`VerifyTokenOnly` deployment vulnerable. Minting new authority is always session-aware; the
configuration switch remains only a request-time verification tradeoff.
