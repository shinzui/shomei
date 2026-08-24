---
title: "Zero-downtime signing-key rotation with encryption at rest"
type: Capability
description: "Rotate the JWT signing key through pending, active, retired, and revoked states without invalidating outstanding tokens, and keep private key material encrypted under an operator-held KEK."
generated:
  by: claude-opus-5/1
  at: "2026-08-24T00:00:00Z"
capabilityId: CAP-5
provider: mori://shinzui/shomei
status: shipped
stability: experimental
since: unreleased
packages:
  - shomei-jwt
  - shomei-postgres
  - shomei-server
interface:
  - Shomei.SigningKey.Rotation.Jwt
  - Shomei.SigningKey.Protection.Jwt
  - Shomei.Server.Keys
requires:
  - CAP-4
evidence:
  - kind: test
    resource: shomei-jwt/test/Shomei/SigningKey/Rotation/JwtSpec.hs
    proves: The pending -> active -> retired -> revoked lifecycle and which states a verifier still trusts.
  - kind: test
    resource: shomei-jwt/test/Shomei/SigningKey/Protection/JwtSpec.hs
    proves: Private material encrypts and decrypts under a KEK, and the ciphertext framing.
  - kind: test
    resource: shomei-server/test/Admin/Main.hs
    proves: generate -> activate (auto-retiring the old key) -> tokens from both keys verify -> revoke breaks it; rewrap moves rows to a new KEK, and a wrong old KEK modifies nothing.
  - kind: guide
    resource: docs/user/security.md
    proves: The rotation runbook and the encryption-at-rest model.
---

# Zero-downtime signing-key rotation with encryption at rest

**Builds on:** [CAP-4 — jWT access tokens with a published JWKS](jwt-access-tokens-and-jwks.md).

A signing key moves through four states:

| State | Signs new tokens | Published in JWKS | Verifies existing tokens |
|---|---|---|---|
| `pending` | no | no | no |
| `active` | yes | yes | yes |
| `retired` | no | yes | yes |
| `revoked` | no | no | no |

Activating a new key auto-retires the previous one, so both are published and both verify while
outstanding tokens drain. Nothing signed by the retiring key is invalidated, and no consumer has
to coordinate a restart. `revoke` is the emergency exit: the key leaves the JWKS at once and
every token it signed stops verifying.

```bash
shomei-admin keys generate --alg ES256   # prints a kid, status pending
shomei-admin keys activate <kid>         # old active key auto-retires
shomei-admin keys list
```

A running server picks up an activation without a restart — the key reloader is a supervised
background loop, and `SIGHUP` forces it.

**Encryption at rest.** With `SHOMEI_KEY_ENCRYPTION_KEY` set, private key material is stored
encrypted under that KEK. Publishing the JWKS and verifying tokens need no KEK at all — only
signing does. `shomei-admin keys rewrap` moves every row from an old KEK to a new one, and aborts
having written nothing if the old KEK is wrong, so a half-rewrapped table is not a reachable
state.

## Limits

- Rotation is **operator-driven**. There is no automatic rotation schedule; `keys generate` and
  `keys activate` are things a human or a deploy pipeline runs.
- The JWKS is cached by consumers for up to five minutes (`max-age=300`). That bounds how long a
  revoked key's public half can linger in a downstream cache — a revocation is not instantaneous
  across the fleet.
- Losing the KEK loses the ability to *sign* with every key it wrapped, and there is no escrow.
  Verification survives — public halves are not encrypted, so outstanding tokens keep verifying —
  but recovery means generating and activating a fresh key under a new KEK.
- `keys rewrap` needs both the old and new KEK present at once, in the environment of the
  process running it.
