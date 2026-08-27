---
type: Architecture Decision Record
title: Every credential proof participates in one abuse budget
description: Password, second-factor, passkey, password-change, and TOTP-removal proofs share one account lockout and the API-derived edge throttle.
docId: ADR-5
status: Accepted
date: 2026-08-27
timestamp: 2026-08-27T18:22:19Z
originatingPlan: docs/plans/54-count-second-factor-and-credential-oracle-failures-and-throttle-every-unauthenticated-proof.md
generated:
  by: openai-codex/gpt-5
  at: 2026-08-27T18:22:19Z
---

# Every credential proof participates in one abuse budget

## Context

Shōmei originally counted only wrong passwords. TOTP and recovery codes, WebAuthn assertions,
passwordless passkeys, the current password at password change, and the proof used to remove TOTP
were credential oracles with no shared failure budget. A caller could obtain a fresh MFA ceremony
with each correct password and guess one TOTP forever because the password success cleared the
counter before each second-factor attempt.

The edge token bucket repeated this omission. Its literal five-path list could drift from the
Servant API and did not cover MFA completion, passkey login, confirmation endpoints,
password change, TOTP removal, or the OAuth token endpoint.

## Decision

Every interactive credential proof uses the same per-account and per-client-IP abuse workflow.
Attempt rows distinguish `password`, `totp`, `recovery`, `passkey`, and `password_change` with a
`factor` column while retaining `success` and `failure` as the indexed outcomes. TOTP removal uses
the factor actually presented.

A correct password that leads to an MFA challenge records no success and clears no lockout. The
successful second factor records the success and clears the lockout; every bad completion counts.
Passwordless passkeys, current-password checks, and TOTP-removal proofs follow the same rule.
Suspended-account attempts are counted and audited. A currently locked account is refused with the
same error as a bad proof and records no further attempt, so an attacker cannot extend the victim's
lockout; the password-login branch still performs one configured-cost hash to preserve timing.

The WAI request-rate limiter derives its exact method/path inventory from the Servant API's
`RateLimited` markers. The standalone API marks all thirteen credential-presenting operations,
including authenticated password change and TOTP removal and unversioned `POST /oauth/token`.

## Consequences

Five failed proofs lock the account regardless of which supported credential type was guessed or
how many fresh ceremonies the caller obtained. The attempt table can be grouped by factor without
weakening its existing outcome indexes, and a successful password cannot erase evidence before MFA
is complete.

Every new credential-verification workflow must call the shared abuse gate and record exactly one
success or failure at the complete-proof boundary. Every new edge-throttled operation must carry the
type-level marker; a missing derivation instance fails compilation, while the conformance test makes
an intentional inventory change explicit.

The edge bucket remains per-process and keyed by the socket peer. It bounds raw request volume but
does not replace the durable PostgreSQL account lockout.

## Alternatives rejected

Separate budgets per credential type were rejected because an attacker could rotate among factors
to multiply the guess allowance and operators would have no single account-compromise signal.

Recording password success before MFA completion was rejected because “failures since the latest
success” would make every second-factor guess free. Adding a third attempt outcome was rejected
because existing partial indexes intentionally partition the two outcomes; the factor is an
orthogonal discriminator.

Maintaining another runtime path list was rejected because route declarations and middleware would
again drift silently. The `RateLimited` marker is the single route-level source of truth.
