---
title: "Password account lifecycle"
type: Capability
description: "Sign up, log in, verify an email, reset a forgotten password, and change a password, keyed on a free-form login identifier with email as an optional attribute."
generated:
  by: claude-opus-5/1
  at: "2026-08-24T00:00:00Z"
capabilityId: CAP-2
provider: mori://shinzui/shomei
status: shipped
stability: experimental
since: unreleased
packages:
  - shomei-core
  - shomei-postgres
interface:
  - Shomei.Session.Authentication.Workflow
  - Shomei.Account.Lifecycle.Workflow
  - Shomei.Account.LoginId.Domain
  - Shomei.Account.Password.Domain
requires:
  - CAP-1
evidence:
  - kind: test
    resource: shomei-core/test/Shomei/AccountSpec.hs
    proves: Signup, login, and the account workflows over the in-memory world, including signup with a login identifier and no email at all.
  - kind: test
    resource: shomei-core/test/Shomei/Account/Password/DomainSpec.hs
    proves: Minimum length, the common-password dictionary, contextual rejection of the email local part / full email / display name, and the flags that disable each check.
  - kind: test
    resource: shomei-core/test/Shomei/Account/Verification/WorkflowSpec.hs
    proves: Email-verification and password-reset tokens are single-use and expire.
  - kind: test
    resource: shomei-core/test/Shomei/BreachSpec.hs
    proves: The opt-in breach check rejects a known-breached password and can fail open or closed when the checker is unreachable.
  - kind: test
    resource: shomei-postgres/test/Main.hs
    proves: Argon2id hashes are PHC-formatted, survive a parameter change, and a lookup miss costs what a hit costs.
  - kind: guide
    resource: docs/user/api.md
    proves: The wire contract of every lifecycle endpoint, with status codes.
---

# Password account lifecycle

**Builds on:** [CAP-1 — transport-agnostic authentication core](transport-agnostic-auth-core.md).

The complete password-credential story: create an account, authenticate, prove an email address,
recover from a forgotten password, and rotate a known one.

The principal is a **login identifier** (`LoginId`) — case-insensitive, trimmed, no `@` or dot
required — so `agent-4815162342` is as valid a subject as `alice@example.com`. Email is an
optional attribute on the user. A caller that supplies only an email gets `loginId` defaulted to
the email text, so email-first clients need no changes.

```bash
curl -X POST localhost:8080/v1/auth/signup -H 'content-type: application/json' \
  -d '{"loginId":"agent-4815162342","password":"correct horse battery staple"}'
curl -X POST localhost:8080/v1/auth/login -H 'content-type: application/json' \
  -d '{"loginId":"agent-4815162342","password":"correct horse battery staple"}'
```

Passwords are hashed with **Argon2id** in PHC string format, so the parameters travel with the
hash and can be raised without invalidating existing credentials. Hashing runs behind a
concurrency limiter, and a login for a non-existent account performs a dummy verification with
the *configured* parameters, so a miss costs what a hit costs.

The password policy is a pure function — minimum length, a common-password dictionary, and a
contextual check that rejects a password containing the account's own email local part, full
email, or display name — plus an **opt-in** breach check against the HIBP Pwned Passwords range
API; `breachCheckFailClosed` decides what an unreachable checker means.

Email verification and password reset both emit a one-time token through the `Notifier` port
([CAP-24](account-notification-delivery.md)); consuming one is a compare-and-swap, so a token
works exactly once. `emailVerificationRequired` turns an unverified email into a `403` at login.

## Limits

- Shōmei **does not deliver email**. It emits the notification; the log transport is the default
  and the SMTP/webhook transports are relays, not a mail server. See
  [CAP-24](account-notification-delivery.md).
- Neither the lifecycle *request* endpoints nor a failed login reveal whether an account exists:
  `verify-email/request` and `password-reset/request` answer `202` unconditionally, and a locked
  account returns the same error as a wrong password. That is deliberate, and it means these
  endpoints cannot be used to tell a caller their address was wrong.
- The breach checker that ships is a HIBP range-API client in `shomei-server`; `shomei-core`
  alone gives you the port and a fake. The check is off by default and fails **open** by default.
- `email` is nullable with a partial unique index, so many accounts may have no email — but an
  account with no email can never use password reset or email verification.
