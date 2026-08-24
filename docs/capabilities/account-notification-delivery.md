---
title: "Account-lifecycle notification delivery"
type: Capability
description: "Deliver email-verification and password-reset one-time links through a log sender, an SMTP relay, an HMAC-signed webhook, or your own Notifier interpreter - without a failed delivery ever failing the request."
generated:
  by: claude-opus-5/1
  at: "2026-08-24T00:00:00Z"
capabilityId: CAP-24
provider: mori://shinzui/shomei
status: shipped
stability: experimental
since: unreleased
packages:
  - shomei-core
  - shomei-server
interface:
  - Shomei.Account.Notification.Store
  - Shomei.Account.Notification.Domain
  - Shomei.Notify
requires:
  - CAP-2
evidence:
  - kind: test
    resource: shomei-server/test/Shomei/Server/NotifySpec.hs
    proves: The log sender redacts the one-time token by default and prints it only under logRawTokens; SMTP delivers to a sink and a refused connection audits a failure without throwing; the webhook POSTs a signature the receiver can verify, retries a 5xx then succeeds, and audits a redacted failure once attempts are exhausted.
  - kind: test
    resource: shomei-server/test/Shomei/Server/E2ESpec.hs
    proves: The webhook transport delivers a signed verification payload whose token is live against the running server.
  - kind: guide
    resource: docs/user/notifications.md
    proves: The three transports, the configuration reference, the signature-verification recipe, and how to write your own interpreter.
---

# Account-lifecycle notification delivery

**Builds on:** [CAP-2 — password account lifecycle](password-account-lifecycle.md).

Shōmei emits a `Notification` — recipient, one-time token, expiry — and a `Notifier` interpreter
turns it into something delivered. Three ship:

| Transport | What it does |
|---|---|
| `LogNotifier` (default) | Writes one line to the server log. Development and log-scraping. |
| `SmtpNotifier` | Plain-text email through a **provider relay** (SES, SendGrid, Resend, Postmark) over implicit TLS, STARTTLS, or a plaintext lab mode. |
| `WebhookNotifier` | HMAC-signed JSON `POST` to a URL you own, with retries. |

The webhook doubles as the eventing hook: it is the sanctioned way to own the copy and branding,
call a provider's own HTTP API, or attach side effects, without writing Haskell.
`X-Shomei-Signature` is `sha256=` plus the lowercase-hex HMAC-SHA256 of the exact raw body bytes
under `SHOMEI_WEBHOOK_SECRET`.

Both delivering transports are **fire-and-forget and hardened**: every exception is caught inside
the interpreter, a failure logs one redacted line and publishes a `NotificationDeliveryFailed`
audit event, and the triggering HTTP request still succeeds.

Operational log lines never contain the token: by default the log sender prints only the first
eight hex characters of its SHA-256, enough to correlate with the stored hash trail and useless
for taking the account over.

## Limits

- **Shōmei is not a mail server.** `SmtpNotifier` is a relay client. Deliverability, SPF/DKIM,
  bounce handling, and suppression lists are your provider's problem.
- Messages are **plain text with fixed copy**. There is no template system, no HTML, no
  localization. Owning the copy means using the webhook transport or your own interpreter.
- Fire-and-forget means a delivery failure is **invisible to the caller**. The user sees a
  successful `202` and no email; the only signal is the audit event and the log line. There is no
  delivery-status API.
- The webhook body **carries the raw one-time token** — that is what the receiver needs to build
  the link. The endpoint must be HTTPS and internal, and the secret rotated.
- Webhook retries are bounded and in-process. There is no durable queue: if the server dies
  mid-retry, that notification is gone.
