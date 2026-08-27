---
type: Architecture Decision Record
title: Reserved privilege scopes are service-account authority and never OAuth-client grants
description: Shōmei refuses its three privilege-gate scopes on OAuth clients while allowing service accounts to hold them as their own authority.
docId: ADR-2
status: Accepted
date: 2026-08-27
timestamp: 2026-08-27T15:15:28Z
originatingPlan: docs/plans/52-bind-oauth-sessions-to-their-client-and-govern-privilege-scopes.md
generated:
  by: openai-codex/gpt-5
  at: 2026-08-27T15:15:28Z
---

# Reserved privilege scopes are service-account authority and never OAuth-client grants

## Context

Shōmei uses flat scopes in two distinct principal models. A service account's
`allowed_scopes` is the ceiling on authority minted for that machine principal. An OAuth client's
`allowed_scopes` is copied into the access token of each human who authorizes through that client.
Treating those allow-lists as interchangeable lets a registered client confer Shōmei's own
privilege gates on every authorizing user.

Three scopes are interpreted by Shōmei itself as privilege gates: the configured impersonation
scope (`impersonate:user` by default), `shomei:admin`, and `token-exchange:subject`. The scoped
service-token contracts [IR-1](mori://shinzui/shomei/okf/improvement-requests/concepts/IR-1) and
[IR-2](mori://shinzui/shomei/okf/improvement-requests/concepts/IR-2) require service accounts to
hold coarse scopes as their own authority. Refusing these scopes everywhere would therefore break
their intended principals rather than close the escalation path.

## Decision

`Shomei.Authorization.Scope.Domain` owns the three reserved values and derives the impersonation
value from `ShomeiConfig`. OAuth-client registration goes through
`Shomei.OAuth.Client.Workflow.registerOAuthClient`, which refuses a client whose allow-list
intersects that set before writing a row.

`GET /oauth/authorize` is the backstop for legacy rows, hand-written rows, and any future caller
that bypasses the registration workflow. An explicit request containing a reserved scope is
`invalid_scope`. When the `scope` parameter is absent, authorize subtracts reserved scopes from
the client's default grant and returns `invalid_scope` if the remainder is empty.

Service-account registration continues to accept reserved scopes. The CLI prints a warning because
the account now holds principal-level authority, but it does not refuse the intended holder.

## Consequences

An OAuth client cannot turn every user who signs in through it into an administrator, an
impersonator, or an on-behalf-of token exchanger. The registration workflow prevents new unsafe
rows, while authorize makes the boundary hold for rows created outside that workflow.

The reserved set changes when an operator changes the configured impersonation scope. A value that
was previously ordinary may become reserved at the next process start; authorize then refuses or
filters it even if an existing client row still contains it. Service-account issuance is unchanged.

Every future Shōmei scope that gates a privilege-minting or administration operation must be added
to the central set and enforced at these same two OAuth-client seams.

## Alternatives rejected

Refusing reserved values only in `shomei-admin` would leave hand-written rows and future
registration entry points able to bypass the rule. The core workflow is the registration policy,
and authorize remains the defense-in-depth enforcement point.

Refusing the values on service accounts would contradict the scoped-service-token contract and
remove the intended database-less administrator and service-exchange principals. A service account
holds a scope as itself; an OAuth client causes a human user to hold it. That principal distinction
is the boundary.

Maintaining separate lists in Servant, token exchange, and the CLI would invite drift. The core
scope domain is the single owner; existing modules re-export the constants for compatibility.
