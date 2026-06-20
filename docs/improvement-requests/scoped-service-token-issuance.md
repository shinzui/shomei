# Improvement Request: Scoped Service-Token Issuance

- **Status:** proposed
- **Origin:** Kikan MasterPlan 2 (platform evolution), EP-10 — the *trust boundary*
  (`kikan:docs/plans/17-trust-boundary-authn-and-authz-via-shomei.md`).
- **Owner of the build:** `shinzui/shomei` (this repo).
- **Size:** a **minor addition that reuses an existing seam** — not a redesign. Everything this
  needs except the issuance entry point already exists and is verified in source (cited below).

> This request is **design, not code**. Kikan wrote zero production code in this repo; it authored
> the trust-boundary contract and proved the doorway/agent boundaries against Python fixtures that
> mint shomei-shaped tokens. This request carries that design here so shomei's own roadmap can add
> the one missing path.


## Context — the contract this satisfies

**C11 — the trust boundary** (`kikan:docs/architecture/evolution/contracts.md`) makes `shinzui/shomei`
the owner of authentication and authorization for the whole platform, *leveraged, not rebuilt*. The
ratified split ("Option A") is:

- **shomei carries identity + coarse scopes** (e.g. `kawa:ingest`, `signal:raise`), which a consuming
  doorway/sink gates with shomei's own `requireScope`.
- **Fine-grained, per-agent-per-sink permissions stay local** to the consuming service (a grant table
  keyed by the verified `sub`) — keeping per-sink vocabulary out of the central auth service.
- Agents use shomei's `act` (actor) claim for on-behalf-of attribution.

The coarse half of that split requires a connector or the `shinzui/shikigami` runtime to obtain a
service token that **bears coarse scopes**. Today they cannot, because the built-in login/session
flow issues *empty* scopes by design.


## What shomei already provides (verified — leverage, do not redesign)

These were read directly from this repo's source and are the foundation this request builds on:

- `AuthClaims` already models signed, un-forgeable `scopes :: Set Scope`, `roles :: Set Role`,
  `actor :: Maybe UserId` (the `act` claim), and `extraClaims :: Object`
  (`shomei-core/src/Shomei/Domain/Claims.hs`, lines 38–57; reserved-key guard at line 65).
- The signing primitive
  `signAccessToken :: JWK -> AuthClaims -> IO (Either JWTError AccessToken)`
  (`shomei-jwt/src/Shomei/Jwt/Sign.hs`, line 125) signs **whatever** scopes are placed in the
  claims — it is already exercised directly in shomei's own tests.
- The enforcement guards `requireScope :: Scope -> AuthUser -> Handler ()` and
  `requireRole :: Role -> AuthUser -> Handler ()` already ship and throw 403
  (`shomei-servant/src/Shomei/Servant/Authz.hs`, lines 41/47), as does JWKS verification
  (`verifyToken`, `shomei-jwt/src/Shomei/Jwt/Verify.hs`).
- **The only gap:** the built-in login/session workflow signs every token with
  `scopes = Set.empty, roles = Set.empty` *by design* — identity, not capability
  (`shomei-core/src/Shomei/Workflow/Session.hs`, lines 52–53), and the admin `users create` path
  assigns none either. `docs/api.md` confirms "Signup/login do not issue roles … yet."

So the building blocks are all present. What is missing is a *path to mint a token whose claims
already carry coarse scopes*.


## The Request

Add a **scoped service-token issuance** path for connector and runtime **service accounts** that
mints an access token bearing a caller-requested set of **coarse scopes**, by calling the existing
`signAccessToken` over an `AuthClaims` whose `scopes` field is populated (rather than left empty as
the login flow does).

It must:

1. Reuse `signAccessToken` / `buildClaims` (or the equivalent claims-construction seam) — **no new
   signing primitive, no new key handling, no change to `verifyToken`/JWKS**.
2. Mint tokens only for service-account principals (connectors, the agent runtime), distinct from
   the human login flow, which keeps issuing empty scopes.
3. Accept a closed, configured set of coarse scopes (see below) — the issuer validates the requested
   scopes against an allowed set per service account, so a connector cannot mint itself arbitrary
   capabilities.
4. Optionally set the `act` claim so an agent token attributes to the operator who authorized it.


## Design (lifted from EP-10)

### The coarse scope vocabulary

Coarse scopes are **one per capability class, not per resource** — they answer "may this bearer
ingest / raise signals **at all**," leaving "may *this specific* identity touch *this specific*
source/sink" to the consuming service's local grant table. The initial set:

- `kawa:ingest` — the bearer may submit to the `shinzui/kawa` ingest doorway at all. The doorway
  gates this with `requireScope "kawa:ingest"` before any local grant lookup.
- `signal:raise` — the bearer may raise `shinzui/kizashi` signals (the coarse capability behind the
  agent `KizashiSignal` sink and `kizashi`'s `POST /v1/signals`).
- `channel:egress` — the bearer may invoke `shinzui/kanmon`'s outbound channel actions at all
  (per-destination authorization remains a fine-grained, host-side decision; C12).

The set is closed and extended in C11, not invented ad hoc by callers.

### Shape (illustrative — implement against shomei's own API conventions)

A service-account issuance call that maps to:

```text
issueServiceToken
  :: ServiceAccountId       -- the connector/runtime principal (resolved to its UserId/sub)
  -> Set Scope              -- requested coarse scopes; validated against the account's allowed set
  -> Maybe UserId           -- optional `act` (operator on whose behalf an agent acts)
  -> IO (Either IssueError AccessToken)
```

implemented as: build `AuthClaims` for the service account with the validated `scopes` populated
(and `actor` set when `act` is requested), then `signAccessToken jwk claims`. The resulting JWT is
indistinguishable in shape from any other shomei access token — same `iss`/`sub`/`aud`/`iat`/`exp`/
`sid`/`scopes`/`roles`/(`act`) claims and `alg`/`kid` header — so existing verifiers and the
`requireScope` guard handle it unchanged.

A natural transport is an authenticated `POST /auth/service-token` (service account presents its
secret; receives `{ accessToken, expiresIn }`), but the entry-point surface is shomei's choice; the
load-bearing requirement is only that the minted token's claims carry the requested coarse scopes.

### Identity naming (for legibility, owned by the consumer)

EP-10 keys its identities by a `loginId` convention — `connector:<source>` (e.g.
`connector:shinzui/rei`), `service:shinzui/shikigami`, `agent:<name>`. shomei need not adopt this
convention internally; it only needs to be able to mint scoped tokens for service accounts created
out-of-band (`shomei-admin users create` / `POST /auth/signup`). The verified `sub` is the join key
the consuming service resolves to its grant table.


## Acceptance

The Kikan conformance proof lives at `kikan:docs/plans/artifacts/17-trust-boundary/`. It mints
shomei-shaped tokens against a JWKS fixture (`mint-token.py`, with a `--scopes` flag) — standing in
for this issuance path so the proof runs offline — and drives a doorway stub that mirrors
`requireScope`. shomei's implementation is conformant when:

1. A scoped service token bearing `kawa:ingest` verifies and passes a `requireScope "kawa:ingest"`
   gate (the proof's submission `[3]` → 200).
2. An empty-scopes token (exactly what the built-in login flow issues today) is rejected by that
   same gate (the proof's submission `[2]` → 403), confirming the coarse half of Option A.
3. The minted token is byte-shape-compatible with `verifyToken` and the existing JWKS, i.e. nothing
   downstream needs to change to verify it.

When this path ships upstream, EP-10's proof swaps `mint-token.py` for a live
`POST /auth/service-token` call with no change to the doorway/agent gates.


## Out of scope

- Any change to `verifyToken`, JWKS publication, key rotation, the login/signup/session lifecycle,
  WebAuthn/passkeys, or refresh-token rotation — all leveraged as-is.
- The **fine-grained** per-agent-per-sink grant table — that lives in the consuming service
  (`shinzui/shikigami`), keyed by the verified `sub`, not in shomei. C11 is explicit that pushing
  every agent's per-sink vocabulary into the central service would bloat it.
- Multi-tenant Spaces / per-Space grants — deferred to Ren (`shinzui/rei`'s multiplayer evolution),
  per C11's single-tenant change rule.
- The `shinzui/kawa` doorway-side verification wiring — that is a separate improvement-request owned
  by another agent against the kawa repo; this request covers only token *issuance*.


## References

- `kikan:docs/plans/17-trust-boundary-authn-and-authz-via-shomei.md` (EP-10).
- `kikan:docs/architecture/evolution/contracts.md` — C11 (trust boundary; the Option A split and the
  "only gap" finding), C2 (the verification boundary the coarse scopes gate), C5 (agent sinks),
  C12 (`channel:egress`).
- This repo (verified seams): `shomei-jwt/src/Shomei/Jwt/Sign.hs` (`signAccessToken`),
  `shomei-core/src/Shomei/Domain/Claims.hs` (`AuthClaims`, `Scope`/`Role`),
  `shomei-servant/src/Shomei/Servant/Authz.hs` (`requireScope`/`requireRole`),
  `shomei-jwt/src/Shomei/Jwt/Verify.hs` (`verifyToken`),
  `shomei-core/src/Shomei/Workflow/Session.hs` (the empty-scopes-by-design gap).
