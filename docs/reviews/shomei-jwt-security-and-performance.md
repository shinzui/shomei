---
type: Review
title: shomei-jwt signing, verification, JWKS, and key protection
description: >-
  No forgery or confusion path exists — jose 0.13 refuses none, HMAC-with-public-key, and
  cross-family verification, the JWKS is public-only, and the KEK envelope binds each key
  to its kid — but zero clock skew rejects fresh tokens at a trailing verifier, the default
  ES256 signs through crypton's timing-annotated ECDSA, and "exactly one active key" is
  not enforced, so changes are requested.
generated:
  by: process:claude-code
  at: "2026-08-27T02:56:01Z"
reviewId: REV-3
subject: mori://shinzui/shomei/packages/shomei-jwt
subjectKind: component
reviewedSha: ee00382509c6cf4b3db2a3c87ff0bd029932c770
coverage: full
reviewedAt: "2026-08-27T02:56:01Z"
reviewerKind: model
reviewer: process:claude-code
provider: anthropic
model: claude-fable-5
effort: xhigh
outcome: changes-requested
dimensions:
  - security
  - correctness
  - performance
  - operability
  - test-coverage
  - documentation
context: >-
  One reader agent read every module and test in the package, the SigningKey ports and
  claims types in shomei-core it implements, the production wiring in Shomei.Servant.Seam
  and Shomei.Server.Keys, and — because the findings rest on library behavior — the jose
  0.13 sdist unpacked under dist-newstyle (verification policy, JWKSet key store, claim
  validators, StringOrURI parsing, JWK serialization, key generation) and crypton 1.1.4
  (ECDSA, ChaCha20-Poly1305, entropy). The review of record re-checked the finding
  severities against that evidence. The shomei-jwt test suite passed at the commit.
---

# shomei-jwt signing, verification, JWKS, and key protection

## Verdict

Changes requested, none of them for a forgery path. The package does the dangerous things
right: `alg: none` is excluded by jose's default policy and an unsigned token raises
`JWSNoSignatures`; HS256 with the public key as the HMAC secret is structurally impossible
because `verify HS256` pattern-matches `OctKeyMaterial` only; ES384/RS256/PS256 over a P-256 key
reach the `AlgorithmMismatch` arm because `verify ES256` matches on the curve; the signature is
checked before any claim; `iss` and `aud` are exact `StringOrURI` equality; `sub`, `sid`, and
`act` are parsed as typed TypeIDs and anything else is `TokenMalformed`; the JWKS is built
through `asPublicKey`, which drops `d` and the RSA private parameters; and the envelope is
ChaCha20-Poly1305 with a fresh 12-byte nonce, the `kid` as associated data, a strict `enc:v1:`
parse, a 32-byte KEK, and a boot failure on any decrypt error. Reserved-claim filtering works in
both directions, so an attacker-controlled `roles` inside `extraClaims` can never shadow the
typed field.

## Findings

**1. Medium — `verifyToken` pins `allowedSkew` to zero with `checkIssuedAt` on, and `iat` is
serialized with sub-second precision** (`src/Shomei/SigningKey/Verify/Jwt.hs:79-84`; jose
`JWT.hs:529-533, 580-582, 269-271`). A downstream verifier — the documented template uses this
very function — whose clock trails the issuer by a few hundred milliseconds rejects every fresh
token with `iat in the future` until its clock catches up. Intermittent, clock-dependent, and it
presents as `401 token_invalid`. Remedy: a small configurable skew (30–60 s) or
`checkIssuedAt .~ False`, and whole-second `iat`/`exp`.

**2. Medium (plausible) — ES256, the default, signs with crypton's generic ECDSA.**
`Sign/Jwt.hs:121-125` selects ES256 for EC material; jose's `signEC` calls
`Crypto.PubKey.ECC.ECDSA.sign` (`JWA/JWK.hs:254`), whose module header reads "Signature
operations may leak the private key" and whose `pointMul` branches on the nonce bits
(`crypton/Crypto/PubKey/ECC/Prim.hs:108-115`). RS256 goes through the blinded
`PKCS15.signSafer`. Every mint is a signing operation an ordinary account can trigger. Whether the
timing signal survives GHC scheduling over the network at the request volumes a deployment
permits is unverified, which is why this is medium and not high. Remedy: document the
trade-off in `security.md`'s Tokens section; consider RS256 as the recommended default or an
EdDSA key type until a constant-time ES256 exists in the dependency chain.

**3. Low — "exactly one active key" is not enforced anywhere and activation is not atomic.**
There is no partial unique index on `status = 'active'`; `rotateSigningKey` inserts the new key
as active before retiring the old (`src/Shomei/SigningKey/Rotation/Jwt.hs:43-50`);
`UpdateSigningKeyStatus` ignores its timestamp so `retired_at` is never stamped by rotation
(REV-5); `Shomei.Server.Keys` tolerates several active keys by taking the newest
`activated_at`. Two concurrent `keys activate` runs, or one that dies between statements, leave
two active keys, both published and trusted, against `security.md`'s state machine. Remedy in
REV-6 and REV-8.

**4. Low — issuer or audience text containing `:` that is not a parseable URI makes every mint
and every verify throw.** `sou = fromString . Text.unpack` relies on jose's `IsString
StringOrURI = fromJust . preview stringOrUri` (`JWT.hs:227-228, 235-237`); the server validates
the issuer only when OIDC is enabled. Remedy: parse through `preview stringOrUri` at config load.

**5. Low — the accepted `alg` set is jose's full default and there is no `typ` header.**
Nothing narrows `validationSettingsAlgorithms` (`Verify/Jwt.hs:80`; jose `JWS.hs:591-601`), so
with an RSA key RS384/RS512/PS* signatures by the same private key also verify; tokens carry no
`typ: at+jwt` (RFC 9068). No forgery follows today; it is one future key type away from
mattering. Remedy: `validationSettingsAlgorithms .~ {ES256, RS256}`; add `typ`.

**6. Low — `kid` does not select the verification key.** jose's `JWKSet` store returns every key
regardless of header (`JWK/Store.hs:98-103`) and `verifyJWSWithPayload` tries them all with `any`
(`JWS.hs:680`). An unknown, missing, or duplicate `kid` is verified against all published keys;
an invalid token costs N signature checks. `security.md` says the `kid` "keeps identifying which
key signed a token" and the test named "selects the signing key by kid" proves only that
multi-key trial succeeds. Remedy: a kid-filtering `VerificationKeyStore`, or reword.

**7. Low — lenient claim shapes.** A non-array `roles`/`scopes`/`permissions` decodes to the
empty set instead of `TokenMalformed` (`Verify/Jwt.hs:188`); a list-valued `aud` is accepted if
any element matches but only the first is reported (`:179-181`); there is no maximum `exp − iat`;
`nbf` and `jti` are absent from `reservedClaimKeys`, so a host that sets them in `extraClaims`
sees them vanish at serialization.

**8. Low — `keys rewrap`'s write pass is not one transaction.** Decrypt-all-before-first-write
holds, but a failure mid-way through the second pass leaves rows under two KEKs (evidence in
REV-8).

**9. Info.** JWKS entries omit `alg` (`Key/Jwt.hs:50-55`) while `security.md` says the algorithm
is reflected in the JWKS; there is no `jti`, so `sid` is the only correlation handle;
`toStoredSigningKey`'s `fromMaybe k (k ^. asPublicKey)` would write private material into
`public_key_jwk` for a key type without a public projection (unreachable with the EC/RSA
generators, but the fallback should be an error).

**10. Info — test coverage.** Not tested: `alg: none`, HS256-with-public-key, RS256-over-EC,
unknown or missing `kid`, a revoked key's token rejected by the verifier (the rotation spec
checks `currentJwks` only), future `iat`, `nbf`, ill-typed `roles`, multi-element `aud`, and
`rotateSigningKey` itself. The library behaviors these would pin are exactly the ones the
verdict rests on.

## Verified holds

- `none` rejected: `JWS.hs:591-601` excludes it; `:668` filters unsigned signatures; `:671`
  raises `JWSNoSignatures`; `Verify/Jwt.hs:121` maps it to `TokenSignatureInvalid`.
- HMAC with public key impossible: `JWA/JWK.hs:670` (HS256 only for `OctKeyMaterial`),
  `:674-675` (`AlgorithmMismatch`), `JWS.hs:693-694, 672`.
- Curve and family pinned: `JWA/JWK.hs:660` matches `P_256` for ES256; signing writes the header
  from the key material (`Sign/Jwt.hs:121-136`).
- Signature before claims (`JWT.hs:690-693`); exp/nbf/iat validators (`:551-615`); Shōmei
  requires `sub`, `sid`, `iss`, `aud`, `iat`, `exp` present (`Verify/Jwt.hs:128-135`) and parses
  ids through `KindID.parseText` (`shomei-core/src/Shomei/Id.hs:157-160`).
- ID token unusable as access token: `aud = client_id` (`Sign/Jwt.hs:161-162`) and the verifier's
  audience predicate; `IdTokenSpec.hs:120-130`.
- Reserved-claim filtering: `Claims/Domain.hs:79-83`; `Sign/Jwt.hs:93-107` writes Shōmei's
  values last (`addClaim` is `M.insert`); jose strips registered names at serialize and parse
  (`JWT.hs:457, 470`); `Verify/Jwt.hs:142-148` excludes the typed names from `extraClaims`.
- JWKS public-only: `Jwks/Jwt.hs:29-38` → `asPublicKey` (`JWA/JWK.hs:686, 689`); `ToJSON` emits
  `kty/crv/x/y` or `kty/n/e` plus `use`/`kid`; `Jwks/JwtSpec.hs:24-30`.
- JWKS and verifier set = active + retired (`SigningKey/Postgres.hs:106-117`), hot-reloaded on
  interval and SIGHUP with last-good retention, read per request from one `IORef`.
- Key generation: P-256 via `ECC.generate` over `getEntropy` (`/dev/urandom`); RSA 2048-bit,
  e = 65537, keys below 2040 bits refused by jose; `kid` is the RFC 7638 thumbprint and the
  table's primary key; EC public keys are point-validated on parse.
- Envelope: `Protection/Jwt.hs:57-63` (32-byte KEK), `:94` (12-byte nonce from `getRandomBytes`),
  `:104-133` (strict versioned parse, plaintext rows rejected), `:137-141` (AAD = kid);
  `KeyEncryptionKey` has no `Show` or JSON instance; no code path shows a decrypted JWK.
- `iat`/`exp` come from the `Clock` port at the workflow, not wall clock in the signer;
  `sub` is the typed `UserId` written last; the header carries `kid` and `alg` only.

## Not examined

jose compact parsing beyond part count, `crit` handling, and JWE; crypton ChaCha and Poly1305
internals and the body of `PKCS15.signSafer` (only its export and blinder import were checked);
`Shomei.Servant.Error`'s rendering of `TokenOtherError` text; `mmzk-typeid`'s `parseText`
internals; `Shomei.Server.Boot`/`App`/`Config` beyond the key-loading ranges quoted.
