---
title: "RFC 8693 token exchange: on-behalf-of and impersonation"
type: Capability
description: "Exchange a token for a delegated one whose sub is the represented user and whose act is the acting party, for propagating user identity across service hops or for audited operator impersonation."
generated:
  by: claude-opus-5/1
  at: "2026-08-24T00:00:00Z"
capabilityId: CAP-15
provider: mori://shinzui/shomei
status: shipped
stability: experimental
since: unreleased
packages:
  - shomei-core
  - shomei-servant
interface:
  - Shomei.OAuth.TokenExchange.Workflow
  - Shomei.Delegation.Workflow
requires:
  - CAP-13
evidence:
  - kind: test
    resource: shomei-core/test/Shomei/OAuth/TokenExchange/WorkflowSpec.hs
    proves: Both exchange modes, the scope-narrowing rules, the token-exchange:subject scope gate, and the refusal of chained exchanges.
  - kind: test
    resource: shomei-core/test/Shomei/Delegation/WorkflowSpec.hs
    proves: A delegated session is short-lived, carries act, and gets no refresh token.
  - kind: test
    resource: shomei-servant/test/Main.hs
    proves: Both modes over HTTP including denyUnderImpersonation inheritance and the wire refusals; and that a delegated token cannot perform an admin mutation.
  - kind: test
    resource: shomei-server/test/Shomei/Server/E2ESpec.hs
    proves: On-behalf-of and impersonation against the live server, verified against the published JWKS and audited.
  - kind: guide
    resource: docs/user/machine-tokens.md
    proves: The narrowing rules and the operator workflow.
---

# RFC 8693 token exchange: on-behalf-of and impersonation

**Builds on:** [CAP-13 — oAuth2 client-credentials machine tokens](oauth2-client-credentials-machine-tokens.md).

`POST /oauth/token` accepts `grant_type=urn:ietf:params:oauth:grant-type:token-exchange` and mints
a token carrying **two identities**: `sub` is the represented user, `act` is the acting party.

**Service on-behalf-of.** A service account presents a user's access token as `subject_token` and
receives a narrowed token with the user's `sub` and its own identity in `act`. The account must
hold the dedicated `token-exchange:subject` scope, which is never itself copied into an issued
token. This is the paved road for propagating user identity across service hops.

**Impersonation.** An operator holding the `impersonate:user` scope exchanges a bare user id
(`subject_token_type=urn:shomei:params:oauth:token-type:user-id`) plus their own access token as
`actor_token`, for a token whose `sub` is the target and `act` is them. Optional `reason` and
`ticket_id` parameters feed the audit trail, and an `impersonation_started` event is written.

A delegated session is a **new, short-lived row with no refresh token**, so it cannot be silently
renewed. Credential-changing endpoints — password change and every passkey mutation — refuse a
delegated token with `403 impersonation_action_blocked` and audit the refusal, as do admin
mutations. An operator can look but cannot change the customer's credentials or launder privilege
through the admin API.

## Limits

- **Who may impersonate whom is not Shōmei's decision.** It enforces the scope gate, the freshness
  gate, and the audit event; business-action gating belongs to the embedding service, which reads
  `act`/`sub` from the verified token.
- The blocklist of credential-changing endpoints is fixed in Shōmei. A host's own sensitive routes
  are not covered automatically — the host must check `act` itself.
- Chained exchanges are refused: a token already carrying `act` cannot be presented as either a
  `subject_token` or an `actor_token`.
- The exchange issues **access tokens only** — no refresh tokens, no ID tokens. A `resource`
  parameter is rejected and an `audience` parameter is ignored, so audience-restricted tokens are
  not available.
- Revoking the result means `POST /oauth/revoke`, and the same stateless-verification caveat as
  everywhere else applies.
