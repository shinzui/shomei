---
type: Architecture Decision Record
title: Runtime secrets stay outside printable configuration
description: SMTP and webhook credentials are non-printable runtime values carried beside ShomeiConfig, with secure transport posture enforced at boot.
docId: ADR-11
status: Accepted
date: 2026-08-27
timestamp: 2026-08-27T21:58:23Z
originatingPlan: docs/plans/57-notifier-and-log-hygiene-no-token-or-secret-reaches-a-log-audit-row-or-config-dump.md
generated:
  by: openai-codex/gpt-5
  at: 2026-08-27T21:58:23Z
---

# Runtime secrets stay outside printable configuration

## Context

`ShomeiConfig` is public embedding policy and derives `Show` and `ToJSON`. The SMTP password and
webhook signing key nevertheless lived inside its notifier sub-records after being read from the
environment. Any diagnostic config dump could therefore disclose credentials despite Dhall never
having fields for them. Whitespace around environment values also survived into connection and
credential material.

Transport policy had a related fail-open edge: webhook URLs accepted plaintext HTTP, and SMTP
could authenticate over the explicitly plaintext mode without an additional acknowledgement.

## Decision

Secret material is carried beside policy configuration. `SmtpConfig` contains relay addressing
and an optional username but no password; `WebhookConfig` contains endpoint and retry policy but
no signing key. The standalone runtime holds `SmtpPassword` and `WebhookSecret` in
`Env.envNotifierSecrets`. Those types deliberately have no `Show`, `Eq`, or JSON instances, while
narrow accessors expose material only to the transport implementation.

Environment text and credentials are stripped before use. Selected transports validate secret
completeness at boot. Webhooks require `https://`, and authenticated SMTP requires STARTTLS or
implicit TLS. The only exceptions are explicit per-process lab flags,
`SHOMEI_WEBHOOK_ALLOW_INSECURE=true` and `SHOMEI_SMTP_ALLOW_PLAINTEXT_AUTH=true`; neither has a
Dhall key. Plain unauthenticated SMTP remains available for lab sinks and emits a warning.

## Consequences

Printing or encoding `ShomeiConfig` cannot expose notifier credentials, and embedding hosts must
now supply runtime secrets explicitly. This is a breaking change to the core configuration API.
Misconfigured or insecure transports fail before delivery begins, while intentional lab setups
remain possible only through conspicuous environment state.

All future credentials must follow the same pattern: non-printable runtime values outside public
configuration records, with completeness and transport posture checked at the assembly boundary.

## Alternatives rejected

A redacting `Show` instance on the existing config fields was rejected because `ToJSON`, lenses,
and arbitrary record access would still expose the values. Placeholder JSON fields were rejected
because they retain secrets in the broadly shared config and make absence impossible to verify
structurally. Allowing HTTP only for loopback was rejected because it adds URL-origin policy and
still makes insecure posture implicit rather than a per-process decision.
