---
type: Architecture Decision Record
title: Authentication freshness is based on credential proof time
description: Sessions persist the last credential-proof instant as auth_time, refresh preserves it, and sensitive gates never use token issue time as proof.
docId: ADR-6
status: Accepted
date: 2026-08-27
timestamp: 2026-08-27T18:22:19Z
originatingPlan: docs/plans/54-count-second-factor-and-credential-oracle-failures-and-throttle-every-unauthenticated-proof.md
generated:
  by: openai-codex/gpt-5
  at: 2026-08-27T18:22:19Z
---

# Authentication freshness is based on credential proof time

## Context

Sensitive operations such as impersonation, recovery-code regeneration, and TOTP removal require a
recent credential proof. JWT `iat` records when a token was issued, not when the user last proved a
credential. Because refresh rotates tokens without authenticating the user, treating `iat` as the
freshness clock lets an old session become “recent” indefinitely by refreshing immediately before a
sensitive action.

The proof instant must survive token rotation and remain authoritative for every access token in
the session, including tokens minted through the OAuth authorization-code path.

## Decision

Interactive sessions persist `authenticated_at`, the instant the credential proof that established
the session completed. Access tokens expose the same value as the managed NumericDate claim
`auth_time`. Signup, complete password login, MFA completion, passwordless login, machine issuance,
and delegated issuance set the field explicitly for their session kind.

Refresh gives the new access token a new `iat` but copies the stored `authenticated_at` unchanged.
Authorization-code issuance and its ID token likewise preserve the authenticated session's proof
time. The signer writes `auth_time` after host-provided extra claims, so an embedding host cannot
forge freshness through claim enrichment.

Recovery-code regeneration, impersonation, and TOTP removal compare their freshness window with
verified `auth_time`, never `iat`. A token issued before this claim existed reads `auth_time` as
`iat`; a session row created before the column existed reads `authenticated_at` as `created_at`.

## Consequences

Refreshing extends token usability within the session policy but never satisfies a
recent-authentication requirement. A stale caller must complete a real login again before changing
or printing sensitive credential material or minting delegated authority.

`authenticated_at` is part of the session domain and persistence interfaces, so every future
session-minting path must choose a proof instant. `auth_time` is a reserved, signer-managed claim and
must remain in strict verifier shape validation.

The nullable migration and read fallbacks permit rolling deployment without rewriting existing
rows or invalidating pre-deploy tokens. During that compatibility window, the historical `iat` or
session creation time remains the best available approximation; newly minted sessions and tokens
carry the exact value.

## Alternatives rejected

Using `iat` was rejected because token refresh is not authentication. Refusing all old tokens and
rows without `auth_time` was rejected because it would force a coordinated session-wide logout for
a change that has a conservative compatibility fallback.

Storing freshness only in each token was rejected because refresh would have to trust caller-held
state and OAuth flows could accidentally reset it. The session is the authoritative source, and
the JWT is its signed projection.
