---
type: Architecture Decision Record
title: Downstream JWKS refresh is bounded by local policy
description: Resource services fetch keys over TLS, cap publisher freshness, and rate-limit one retry for an unknown key identifier.
docId: ADR-18
status: Accepted
date: 2026-08-27
timestamp: 2026-08-28T01:58:53Z
originatingPlan: docs/plans/59-embedding-parity-and-a-trustworthy-downstream-verification-template.md
generated:
  by: openai-codex/gpt-5
  at: 2026-08-28T01:58:53Z
---

# Downstream JWKS refresh is bounded by local policy

## Context

Resource services verify Shōmei access tokens offline against a cached JWKS. Rotation creates a
short interval in which a valid token can name a key the cache has not fetched. Refreshing on every
unknown key closes that availability gap but lets an attacker turn arbitrary `kid` values into an
outbound request storm. Refreshing only by age leaves valid post-rotation tokens unavailable until
the normal refresh window.

Publisher caching headers and transport are also part of this trust boundary. An unbounded
`max-age` can override the resource service's revocation posture, `max-age=0` can collapse caching
into a fetch-per-request loop, and plaintext JWKS transport lets an on-path attacker substitute its
own verification keys.

## Decision

Downstream services select an HTTP manager from the JWKS URL scheme. HTTPS uses a TLS-capable
manager. Plaintext HTTP is retained for loopback development; non-loopback plaintext emits an
operator warning and is not an acceptable production posture.

The configured maximum staleness is a hard local bound. A positive publisher `max-age` may set an
entry's freshness lifetime but is clamped to that bound. Zero or negative `max-age` is ignored, so
the configured TTL applies. Once the last good entry reaches maximum staleness, verification fails
closed as unavailable rather than continuing with revoked keys.

After strict verification reports `TokenKeyNotFound`, a cache whose entry is at least five seconds
old may perform one synchronous single-flight refresh and retry verification exactly once. The
process claims a global unknown-key refresh slot atomically before entering the flight; at most one
such fetch occurs per 30 seconds. Missing or unknown keys may spend this budget, while malformed
tokens and bad signatures do not trigger a fetch. A retry that still fails returns the ordinary
Bearer `401` response.

## Consequences

A freshly rotated key can become usable on the first eligible request instead of waiting for the
age-driven refresh window. Forged or random key identifiers cannot make outbound work grow with
request volume, and concurrent eligible requests share one fetch.

Publisher cache policy can shorten ordinary freshness but cannot extend the service's maximum trust
window. Outages may continue to use the last good keys only within that explicit bound; after it,
the service returns `503` because verification is unavailable rather than claiming the caller's
token is invalid.

The five-second minimum age and 30-second interval are part of the template's default operational
policy. Services that expose them as configuration must retain positive bounds and the same atomic,
single-flight semantics.

## Alternatives rejected

Refreshing on every verification failure was rejected because bad signatures and malformed tokens
are attacker-controlled. Refreshing on every unknown `kid` was rejected because a stream of unique
identifiers becomes a network-amplification path. Trial verification across every cached key was
rejected by the strict JWT trust-boundary decision and does not solve a genuinely absent key.

Treating `max-age=0` literally was rejected because it defeats offline verification. Allowing a
publisher header to exceed maximum staleness was rejected because revocation policy belongs to the
resource service. A universal plaintext-capable manager without an explicit warning was rejected
because it makes an insecure deployment appear normal.
