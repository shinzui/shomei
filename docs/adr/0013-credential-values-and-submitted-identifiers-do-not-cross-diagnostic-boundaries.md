---
type: Architecture Decision Record
title: Credential values and submitted identifiers do not cross diagnostic boundaries
description: Secret-bearing token values are non-serializable and redacted, while failed-login audit data retains only a hashed account key and resolved user identity.
docId: ADR-13
status: Accepted
date: 2026-08-27
timestamp: 2026-08-27T22:07:01Z
originatingPlan: docs/plans/57-notifier-and-log-hygiene-no-token-or-secret-reaches-a-log-audit-row-or-config-dump.md
generated:
  by: openai-codex/gpt-5
  at: 2026-08-27T22:07:01Z
---

# Credential values and submitted identifiers do not cross diagnostic boundaries

## Context

Access and refresh tokens are bearer credentials. Derived `Show` and JSON instances made it easy
for assertion failures, generic logging, or incidental serialization to disclose them. Failed
login audit events similarly persisted the submitted login identifier verbatim even though the
field is untrusted text and may itself contain a password or another secret.

Operators still need to correlate a failed proof with an account lock and, when a credential was
resolved, query the failure by its subject user. Historical failed-login rows must remain readable.

## Decision

`AccessToken`, `RefreshToken`, and the client `Token` have explicit `Show` instances that emit only
a redaction marker. The core token types and `TokenPair` have no generic JSON instances; wire DTOs
remain the only serialization boundary.

New `login_failed` events store the already-derived SHA-256 `AccountKey` and an optional resolved
`UserId`, never the submitted `LoginId`. The resolved user also populates the audit envelope's
`user_id` column. Both payload fields are optional so a historical payload containing only
`loginId` and `occurredAt` decodes without reproducing the raw identifier in the typed event.

## Consequences

Generic diagnostics cannot render or serialize these bearer credentials. Callers that used the
removed core JSON instances must serialize an explicit wire DTO. `IdToken` retains its existing
instances and is a separately tracked follow-up because OIDC response modeling is outside this
remediation's compatibility boundary.

Failed-login and account-lock events can be joined by `accountKey`, and resolved failures appear in
user-filtered audit queries. New SIEM rules must move from `payload.loginId` to
`payload.accountKey`; unknown-login events intentionally carry no user identity.

## Alternatives rejected

Redacting only the logger was rejected because other `Show` and JSON consumers would remain unsafe.
Persisting a normalized login identifier was rejected because normalization does not make untrusted
input safe to retain. Making the replacement fields required was rejected because it would make
pre-change audit rows undecodable.
