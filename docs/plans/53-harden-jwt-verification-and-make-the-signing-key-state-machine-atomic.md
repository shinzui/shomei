---
id: 53
slug: harden-jwt-verification-and-make-the-signing-key-state-machine-atomic
title: "Harden JWT Verification and Make the Signing-Key State Machine Atomic"
kind: exec-plan
created_at: 2026-08-27T03:23:49Z
intention: "intention_01m10kwqt9eedbjvk91rn726mq"
master_plan: "docs/masterplans/8-trust-boundary-remediation-close-the-august-2026-security-and-performance-review.md"
---

# Harden JWT Verification and Make the Signing-Key State Machine Atomic

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

Everything downstream of Shōmei trusts two edges: the JWT verifier accepting exactly the tokens
Shōmei minted, and the signing-key table holding exactly one key that mints them. The August
2026 review (`docs/reviews/shomei-jwt-security-and-performance.md`, REV-3) found no forgery path
but both edges softer than documented: `verifyToken` pins clock skew to zero while `iat` carries
sub-second precision, so a verifier half a second behind the issuer rejects every fresh token;
it accepts any of jose's thirteen algorithms, tries every published key regardless of `kid`,
decodes a string-valued `roles` as the empty set, and accepts a multi-element `aud`. Nothing
prevents two `active` keys; `keys activate` is two autocommit statements; `rotateSigningKey`
inserts before it retires; `UpdateSigningKeyStatus` drops its timestamp.

After this plan a token 20 seconds ahead of a slow downstream verifies while one 2 minutes ahead
does not; the verifier accepts only `ES256`/`RS256`, selects its key by `kid`, reports an unknown
key as `TokenKeyNotFound` (so `docs/plans/59-…`'s template can refresh on it), refuses ill-typed
list claims and any `aud` but the configured one, and reads its tolerance from
`allowedClockSkewSeconds` (default 30; `SHOMEI_ALLOWED_CLOCK_SKEW_SECONDS`); tokens carry `typ`
and whole-second timestamps. A second `active` row is a unique-index violation; activate,
rotate, and rewrap each run in one transaction; every status change stamps its timestamp (a new
`revoked_at` included); JWKS entries carry `alg`; `security.md` tells the truth about `kid` and
the ES256 timing trade-off. Proof: a negative-test module whose cases fail on today's code, and
a `psql` session that can no longer activate a second row.


## Progress

- [x] (2026-08-27 16:26Z) M1 regression step: added verifier-boundary tests and reproduced the
      zero-skew, permissive list-claim, multi-audience, fractional-time, and reserved-name failures.
- [x] (2026-08-27 16:35Z) M1 implementation: `nbf`/`jti` reserved; `allowedClockSkewSeconds` (30);
      `TokenKeyNotFound`; `VerifierSettings`, kid-selecting store, pinned algorithms, `typ`, strict
      claims, whole seconds; complete the unknown/missing-`kid`, `typ`, and algorithm negatives.
- [x] (2026-08-27 16:42Z) M2: env `SHOMEI_ALLOWED_CLOCK_SKEW_SECONDS`, Dhall key, deployment.md row;
      issuer/audience validated as StringOrURI at boot; config tests.
- [x] (2026-08-27 16:58Z) M3: migration `0032`; `revokedAt`; stamped `UpdateSigningKeyStatus`;
      `ReplaceActiveSigningKey`; transactional activate/rotate/rewrap; `assembleKeys` refuses
      two actives; JWKS `alg`; `toStoredSigningKey` returns `Either`; postgres/jwt/admin tests.
- [ ] M4: security.md, deployment.md, api.md, changelogs; docs grep; Outcomes written.


## Surprises & Discoveries

- The M1 regression module reproduced all five pre-fix weaknesses that were expected to fail;
  the three algorithm-confusion controls already held in the existing suite. The focused new
  output was:

  ```text
  accepts an iat within the configured 30-second skew:          FAIL (iat in the future)
  rejects a string-valued roles claim as malformed:             FAIL (verified with roles = [])
  rejects a multi-element audience even when one value matches: FAIL (verified)
  mints integral iat and exp values:                            FAIL (fractional NumericDate)
  drops nbf and jti from the extension claim bag:               FAIL (nbf was retained)
  ```

- After the M1 implementation, `cabal test shomei-jwt` passed all 58 cases, including the new
  unknown/missing-`kid`, `none`, HS256-public-key, cross-family, `typ`, strict-claim, and skew
  cases. `cabal build all --enable-tests` succeeded, and the wider
  `cabal test shomei-core shomei-servant shomei-server` run passed 260 core tests, 40 Servant
  tests, 62 OpenAPI examples, and every server/config/health/admin suite.

- RFC 3986 permits a scheme followed by a rootless path, so `shomei:prod` is a valid URI and
  therefore a valid StringOrURI. The draft plan's proposed refusal was incorrect. The boot-time
  negative test and transcript now use `https://bad host`, which contains a colon but cannot parse
  as a URI; `shomei:prod` is pinned as accepted. `cabal test shomei-server-config-test`, Dhall
  type-check/render, and the real invalid-issuer boot all passed with the intended behavior.

- The migration allocator had advanced to `0032`, so the durable artifact is
  `0032-shomei-signing-keys-one-active.sql`, not the draft's illustrative `0029`. Hasql also
  deliberately separates statement composition (`Hasql.Transaction`) from execution
  (`Hasql.Transaction.Sessions`); the CLI now uses both, while the PostgreSQL interpreter uses
  its existing `Database.runTransaction` effect. `just migration-check`, all 61 JWT tests, all
  61 PostgreSQL tests, and all 27 admin tests passed. The database tests prove SQLSTATE `23505`,
  timestamp stamping, and atomic replacement; the admin test also bypasses the CLI to prove the
  index itself refuses a second active row.


## Decision Log

- Decision: The tolerance is `SigningKeyConfig.allowedClockSkewSeconds :: Int`, default 30,
  applied through jose's `allowedSkew` to `exp`, `nbf`, and `iat`; `checkIssuedAt` stays `True`.
  Rationale: Integration Point 3 names the record and default. jose widens validity symmetrically
  (`JWT.hs:568, 581, 593`), so one number covers a trailing verifier (REV-3 finding 1) and a
  leading one; 30 s exceeds NTP drift and is negligible against the 15-minute TTL. Disabling
  `checkIssuedAt` was rejected: the skew fixes the bug; the check still catches a wild clock.
  Date: 2026-08-27

- Decision: The key store selects by `kid`; an unknown `kid` is `TokenKeyNotFound (Just kid)`,
  an absent `kid` is `TokenKeyNotFound Nothing`; neither falls back to trying every key.
  Rationale: Shōmei writes `kid` on every token (`Sign/Jwt.hs:135-136`), so an absent `kid` is a
  foreign token; trial verification costs N signature checks per bad token (REV-3 finding 6);
  `Just`/`Nothing` tells the template whether a refresh could help (REV-10 finding 3;
  `docs/plans/59-…` implements it). `Shomei.Servant.Error:559` still maps every `TokenInvalid _`
  to `401 token_invalid`, so the wire is unchanged.
  Date: 2026-08-27

- Decision: Access tokens carry `typ: at+jwt`, ID tokens `typ: JWT`. The verifier refuses a
  present `typ` other than `at+jwt`/`application/at+jwt` (case-insensitive, RFC 9068 §2.1) but
  accepts an absent `typ` this release, behind `VerifierSettings.requireTokenType` (`False`).
  Rationale: A downstream upgrading `shomei-jwt` before its issuer would otherwise refuse every
  token for the deployment gap; `typ`-less tokens vanish 15 minutes after the issuer upgrades;
  the default flips next minor release. Checked after signature and claims, so the
  ID-token-at-resource-server test keeps reporting `TokenAudienceInvalid`.
  Date: 2026-08-27

- Decision: Migration `0032` first retires every `active` row except the one
  `Shomei.Server.Keys.assembleKeys` would already choose (greatest `activated_at`, `NULL`
  lowest, then `created_at`, then `key_id`), stamping `retired_at`, then creates the index.
  Rationale: The index must not fail an existing deployment; retired keys stay published and
  trusted (`SigningKey/Postgres.hs:113`), so no outstanding token breaks; `activated_at` can be
  `NULL` on old rows (plan 29's Surprises), hence `NULLS LAST`.
  Date: 2026-08-27

- Decision: `aud` must be a one-element array (or string) equal to the configured audience,
  else `TokenAudienceInvalid`; a non-array `roles`/`scopes`/`permissions` is `TokenMalformed`.
  Rationale: Shōmei mints a single audience (`Sign/Jwt.hs:98-99`) and owns the claim shapes.
  Date: 2026-08-27

- Decision: `assembleKeys` returns `Left` on more than one active row instead of picking.
  Rationale: A `Left` is the logged error the MasterPlan asks for — fatal at boot, "key reload
  failed … keeping previous key material" on reload — and after `0032` the state is reachable
  only if the index is missing, which the message names.
  Date: 2026-08-27

- Decision: Atomic rotation is a new port operation `ReplaceActiveSigningKey` (retire all
  active, then insert-or-promote one key as active, one transaction); the CLI keeps its own SQL
  (plan 29's Decision Log) inside `Hasql.Transaction`.
  Rationale: MasterPlan 5's `AuthUnitOfWork` shape; the fake is one `modifyWorld`. Retire, then
  activate: a partial unique index is checked per statement and cannot be deferred.
  Date: 2026-08-27

- Decision: Issuer and audience are validated as StringOrURI in `Shomei.Server.Config` through
  `Shomei.SigningKey.Verify.Jwt.checkStringOrUri`; the verifier becomes total (an unparseable
  configured value yields `const False`); the signer stays partial for values the loader refuses.
  Rationale: `shomei-core` may not import jose (IP-4); `shomei-server` already depends on
  `shomei-jwt`; `Boot.validateOidcIssuer` checks only when OIDC is on (`Boot.hs:160`).
  Date: 2026-08-27

- Decision: ES256 timing is documented, not engineered around (MasterPlan 8 Decision Log).
  Date: 2026-08-27

- Decision: Accept every RFC 7519 StringOrURI, including scheme/rootless-path values such as
  `shomei:prod`, and reject only colon-bearing values that fail URI parsing.
  Rationale: StringOrURI delegates colon-bearing values to RFC 3986 URI syntax; rejecting a valid
  non-hierarchical URI would impose an undocumented HTTPS-URL policy rather than make jose's
  partial conversion safe. OIDC's stricter HTTP(S) issuer rule remains separately enforced when
  OIDC is enabled.
  Date: 2026-08-27


## Outcomes & Retrospective

(To be filled during and after implementation. No `docs/adr/` bundle exists; the distillation
pass creates it per `.claude/skills/exec-plan/ADR.md` for the one-active-key invariant and the
verifier's strictness rules.)


## Context and Orientation

Shōmei is a multi-package Haskell (Cabal, GHC 9.12) toolkit built inside a Nix devshell. Touched
here: `shomei-core` (domain, config, the `effectful` port effects such as `SigningKeyStore`, and
the in-memory fake `shomei-core/src/Shomei/Test/InMemory.hs`), `shomei-jwt` (jose interpreters),
`shomei-postgres` (hasql interpreters), `shomei-migrations` (SQL embedded at compile time), and
`shomei-server` (server, `shomei-admin` CLI, loader). Tests are tasty + tasty-hunit; database
suites use an ephemeral PostgreSQL via `withShomeiMigratedDatabase`. Terms: a JWT is a signed
JSON claims document in three base64url segments whose protected header names the algorithm
(`alg`), the key (`kid`), and optionally the token type (`typ`); a JWKS is the public key set at
`GET /.well-known/jwks.json`; clock skew is the tolerance granted to time claims; a StringOrURI
(RFC 7519) must be a valid URI if it contains a colon; a partial unique index covers only rows
matching its `WHERE`; envelope encryption is plan 32's `enc:v1:` wrapping of `private_key_jwk`.

No `docs/adr/` bundle exists (checked 2026-08-27; `mori.dhall` declares `improvement-requests`,
`capabilities`, and `reviews`), so no local ADR applies and none is cited across repositories.
Prior plans, both checked in: `docs/plans/29-publish-and-hot-reload-the-full-jwks-with-retired-keys.md`
(the single load path `Shomei.Server.Keys.loadKeyMaterial`, periodic and SIGHUP reload,
keep-last-good; `activated_at` can be `NULL`) and `docs/plans/32-encrypt-signing-private-keys-at-rest.md`
(publication reads `public_key_jwk`; `private_key_jwk` is parsed only in
`decryptStoredSigningKey`; `rotateSigningKey` has no in-tree caller). Both rules survive.

The code at HEAD `5dfd2a6`. The verifier, `shomei-jwt/src/Shomei/SigningKey/Verify/Jwt.hs:77-91`,
is `verifyToken :: JWKSet -> ShomeiConfig -> Text -> IO (Either TokenError AuthClaims)`, whose
settings are `defaultJWTValidationSettings (== sou (audienceText cfg.audience)) &
issuerPredicate .~ (…) & allowedSkew .~ 0` (`:79-84`), verified against the bare `JWKSet`
(`:88`). jose 0.13 facts (source under `dist-newstyle/src/hs-jose-*/src/Crypto/`): `defaultValidationSettings`
(`JOSE/JWS.hs:591-601`) accepts every algorithm but `none`; the `JWKSet` store returns all keys
ignoring the header (`JOSE/JWK/Store.hs:98-103`); `verifyJWSWithPayload` accepts if `any` key
verifies (`JOSE/JWS.hs:680`) and raises `NoUsableKeys` when the store returns none (`:679`);
`NumericDate` serializes fractional seconds (`JWT.hs:269-271`); `validateIatClaim` throws
`JWTIssuedAtFuture` when `iat > now + skew` (`:580-582`); `IsString StringOrURI` is
`fromJust . preview stringOrUri` (`JWT.hs:227-228`), so `sou = fromString . Text.unpack`
(`Verify/Jwt.hs:72`, `Sign/Jwt.hs:79`) crashes on a malformed issuer such as `https://bad host`.

`claimsToAuth` (`Verify/Jwt.hs:126-189`) reports the first `aud` element (`:178-181`), decodes
list claims with `either (const []) id` (`:188`), and excludes a hand-written `managed` list
(`:142`) duplicating `reservedClaimKeys` (`shomei-core/src/Shomei/Authorization/Claims/Domain.hs:79`),
which lacks `nbf` and `jti`. The signer (`Sign/Jwt.hs:84-114`) seeds `extraClaims` first and
writes Shōmei's claims on top; its header (`:133-136`) carries `alg` and `kid` only. ES256 signs
through crypton's `Crypto.PubKey.ECC.ECDSA.sign` (jose `JOSE/JWA/JWK.hs:254`), whose module
header (`crypton/Crypto/PubKey/ECC/ECDSA.hs:3-4`; `mori registry show kazu-yamamoto/crypton --full`)
says "Signature operations may leak the private key" and whose `pointMul` (`…/ECC/Prim.hs:108-115`)
branches on scalar bits; RS256 uses the blinded `PKCS15.signSafer` (`JWA/JWK.hs:407`).
`Key/Jwt.hs:50-58` generates keys without `alg`; `toStoredSigningKey` (`:72-85`) has
`pub = fromMaybe k (k ^. asPublicKey)`, which would store private material as public for a key
type without a public projection; `publicJwkFromStored` (`Protection/Jwt.hs:173-175`) feeds the
JWKS and verifier set; `rotateSigningKey` (`Rotation/Jwt.hs:43-50`) inserts, then retires.

`SigningKeyConfig` (`shomei-core/src/Shomei/Config.hs:124-132`) is constructed at `:498` and
`shomei-jwt/test/Shomei/SigningKey/Sign/RsaCustomClaimSpec.hs:74-75`; `TokenError` is at
`shomei-core/src/Shomei/Error.hs:35-43`. The table
(`shomei-migrations/migrations/shomei/0006-shomei-signing-keys.sql:5-14`) has `created_at`,
`activated_at NULL`, `retired_at NULL` — no `revoked_at`, no index on status.
`shomei-postgres/src/Shomei/SigningKey/Postgres.hs:45-47` discards its timestamp and `:152-159`
updates `status` only; the fake matches at `InMemory.hs:1176-1177`; `runTransaction` exists
(`shomei-postgres/src/Shomei/Persistence/Database/Postgres.hs:32`, used with
`Hasql.Transaction.statement` by `Shomei.Session.UnitOfWork.Postgres`).
`Shomei.Server.Keys.assembleKeys` (`shomei-server/src/Shomei/Server/Keys.hs:119-151`) picks
`newestActive` (`:147-148`). `shomei-server/app/Shomei/Admin/Keys.hs:71-81` (`keysActivate`)
runs `setActiveStmt` and one `setRetiredStmt` per old key, each an autocommit `runSess`
(`:168-171`); `keysRevoke` (`:94-99`) stamps nothing; `keysRewrap` (`:105-114`) writes row by
row; the `shomei-admin` executable (`shomei-server.cabal:117-168`) lacks `hasql-transaction`.
`shomei-server/src/Shomei/Server/Config.hs` reads `SHOMEI_ISSUER`/`SHOMEI_AUDIENCE` at
`:441-443` unvalidated; `keyRefreshIntervalEnv` (`:1118-1123`) models a non-negative env var;
`FileConfig` (`:162-262`) is merged by `baseFromFile` (`:364-369`); `config/shomei-types.dhall`
is a closed record whose newer keys are `Optional`. Callers of the pure verifier that must keep
compiling unchanged: `Shomei.Server.App:176`, `shomei-servant/test/Main.hs:255`,
`shomei-server/test/Admin/Main.hs:180-328`, and `examples/microservice-auth-stack/src/Downstream/Service.hs:324`
— how `docs/plans/59-…` inherits this behavior without code of its own. Docs to correct:
`docs/user/security.md:14-21`, `:50-58`; `docs/user/deployment.md:12-62`, `:141-158`, `:172-199`; `docs/user/api.md:497`.


## Plan of Work

### Milestone 1 — The verifier accepts exactly Shōmei's tokens

Scope: `shomei-core` types and `shomei-jwt` sign/verify, negative tests first; at the end
`cabal test shomei-jwt` proves skew, algorithm pinning, `kid` selection, `typ`, strict claim
shapes, whole-second timestamps, and the reserved-name list. In `Claims/Domain.hs:79` extend
the list to
`["iss", "sub", "aud", "iat", "exp", "nbf", "jti", "sid", "scopes", "roles", "permissions", "act"]`
with a comment that is the cross-plan contract: the signer writes each name after the extra
bag, the verifier excludes each from `extraClaims`, `mkExtraClaims` drops each — all from this
one list, so adding a managed claim (EP-4 adds `auth_time`) is one entry here plus the signer's
own write. In `Config.hs:124-132` add `allowedClockSkewSeconds :: !Int` (haddock: "tolerance
for exp/nbf/iat at the verifier; 0 is exact"), set `30` at `:498` and
`RsaCustomClaimSpec.hs:74-75`. In `Error.hs:35-43` add `| TokenKeyNotFound !(Maybe Text)`
(`Just kid` unknown, `Nothing` absent). `Shomei.Servant.Error` needs no edit.

Rewrite `Verify/Jwt.hs`, exporting `VerifierSettings (..)`, `verifierSettingsFromConfig`,
`verifyTokenWith`, `verifyToken`, `runTokenVerifierJwt`, `jwtErrorToTokenError`,
`KidSelectingKeys (..)`, `checkStringOrUri`:

```haskell
newtype KidSelectingKeys = KidSelectingKeys JWKSet -- answers only the key the header's kid names
instance (Applicative m, HasKid h) => VerificationKeyStore m (h p) s KidSelectingKeys where
  getVerificationKeys h _ (KidSelectingKeys (JWKSet ks)) =
    pure case preview (kid . _Just . param) h of
      Just k -> filter ((== Just k) . view jwkKid) ks
      Nothing -> []
verifyTokenWith :: VerifierSettings -> JWKSet -> Text -> IO (Either TokenError AuthClaims)
verifyTokenWith vs jwks raw = do
  -- decodeCompact first (a Left here is jwtErrorToTokenError), then:
  let hdrKid = signed ^? signatures . header . kid . _Just . param -- hdrTyp likewise via typ
      settings =
        defaultJWTValidationSettings (matches (audienceText vs.audience))
          & issuerPredicate .~ matches (issuerText vs.issuer)
          & allowedSkew .~ vs.allowedClockSkew
          & validationSettingsAlgorithms .~ Set.fromList [ES256, RS256]
  result <- runJOSE @JWTError (verifyClaims settings (KidSelectingKeys jwks) (signed :: SignedJWT))
  pure case result of
    Left (JWSError NoUsableKeys) -> Left (TokenKeyNotFound hdrKid)
    Left e -> Left (jwtErrorToTokenError e)
    Right cs -> checkTokenType vs hdrTyp >> claimsToAuth cs
  where
    matches want = maybe (const False) (==) (preview stringOrUri want)
```

`VerifierSettings` is the record in Interfaces; `verifierSettingsFromConfig cfg` is
`VerifierSettings cfg.issuer cfg.audience (fromIntegral cfg.signingKeyConfig.allowedClockSkewSeconds) False`;
`checkStringOrUri t` is `Right ()` when `preview stringOrUri t` succeeds, else
`Left "contains ':' but is not a valid URI (RFC 7519 StringOrURI)"`. Imports: `HasKid`, `HasTyp`,
`param` from `Crypto.JOSE.Header`; `VerificationKeyStore` from `Crypto.JOSE.JWK.Store`; `jwkKid`,
`JWKSet (..)` from `Crypto.JOSE.JWK`; `signatures`, `header`, `validationSettingsAlgorithms` from
`Crypto.JOSE.JWS`; `Alg` from `Crypto.JOSE.JWA.JWS`; `stringOrUri` from `Crypto.JWT`.
`verifyToken jwks cfg = verifyTokenWith (verifierSettingsFromConfig cfg) jwks`, so every caller
and the template inherit the behavior. `checkTokenType` accepts `Nothing` unless
`requireTokenType`, accepts `at+jwt`/`application/at+jwt` case-insensitively, else
`TokenOtherError ("typ " <> t <> " is not at+jwt")`; `jwtErrorToTokenError` maps `NoUsableKeys`
to `TokenKeyNotFound Nothing`. In `claimsToAuth`: `lookupStringList` returns
`Either TokenError [Text]` (absent → `Right []`, any decode failure → `Left TokenMalformed`);
`firstAudience` becomes `exactAudience`, accepting `Audience [x]` only, else
`TokenAudienceInvalid`; the `managed` literal becomes `Domain.reservedClaimKeys`; delete `sou`.
In `Sign/Jwt.hs` add and export `wholeSeconds :: UTCTime -> UTCTime`
(`posixSecondsToUTCTime . fromInteger . floor . utcTimeToPOSIXSeconds`), apply it inside the
`NumericDate`s at `:100-103` and `:163-166`, add `& JWS.typ ?~ newHeaderParamProtected "at+jwt"`
to the header at `:133-136` and `"JWT"` at `:182-185`, reword `:87-92` to name
`reservedClaimKeys`, and leave the signer's `sou` (the loader refuses what it cannot parse).

Tests: create `shomei-jwt/test/Shomei/SigningKey/Verify/JwtSpec.hs` (register in the cabal
`other-modules` and `test/Main.hs`) with a helper signing any jose `ClaimsSet` under any
protected header (`signClaims` + `encodeCompact`) over `claimsFromAuth` of `mkClaims`. Cases:
`alg none` (hand-assemble `header.payload.` from a real token's payload; `TokenSignatureInvalid`);
HS256 with the public key as secret (an Oct JWK via `fromOctets` over the public JWK's JSON, the
EC key's `kid`; `TokenSignatureInvalid`); RS256 by an RSA key under the EC `kid`
(`TokenSignatureInvalid`); unknown `kid` (sign with A, verify against `{B}`;
`TokenKeyNotFound (Just kidA)`); missing `kid` (`TokenKeyNotFound Nothing`); future `iat`
`+10 s` verifies, `+120 s` is `TokenOtherError "iat in the future"`; `roles` as a JSON string is
`TokenMalformed`; a two-element `aud` containing the right one is `TokenAudienceInvalid`; header
`typ: JWT` on an access token is refused, absent `typ` accepted; minted headers carry `typ`
(decoded as `Sign/JwtSpec.hs:166-172` does); payload `iat`/`exp` are integers
(`Scientific.isInteger`); `mkExtraClaims` drops `nbf` and `jti`.

Commit:

```text
fix(jwt): harden verification with skew, pinned algorithms, kid selection, typ, strict claims

MasterPlan: docs/masterplans/8-trust-boundary-remediation-close-the-august-2026-security-and-performance-review.md
ExecPlan: docs/plans/53-harden-jwt-verification-and-make-the-signing-key-state-machine-atomic.md
Intention: intention_01m10kwqt9eedbjvk91rn726mq
```

### Milestone 2 — The tolerance is configurable and the issuer cannot crash the signer

Scope: the `shomei-server` loader, the Dhall schema, `deployment.md`, config tests; at the end
`SHOMEI_ALLOWED_CLOCK_SKEW_SECONDS=-1` and `SHOMEI_ISSUER='https://bad host'` both refuse to boot
naming the variable and the Dhall field. In `Server/Config.hs`: add `allowedClockSkewSeconds :: !(Maybe Int)` to `FileConfig` after
`:248`; merge it in `baseFromFile` beside `:367-368`; add `clockSkewEnv` modelled on
`keyRefreshIntervalEnv`, reading `SHOMEI_ALLOWED_CLOCK_SKEW_SECONDS` and rejecting negatives
with `"SHOMEI_ALLOWED_CLOCK_SKEW_SECONDS (Dhall field allowedClockSkewSeconds) must be >= 0"`;
apply it in `overlayCoreFromEnv` (`:575-579`). In `overlayFromEnvBoth` after `:443` call a
local `requireStringOrUri envName dhallField value` twice; it wraps `checkStringOrUri` and
fails with `ioError (userError (envName <> " (Dhall field " <> dhallField <> ") " <> reason <> ", got " <> show value))`.
Add `, allowedClockSkewSeconds : Optional Natural` to `config/shomei-types.dhall` after
`oauthIdTokenTtlSeconds` (`Optional`, so annotated files keep type-checking) and
`allowedClockSkewSeconds = Some 30` to `config/shomei.example.dhall`. In `deployment.md` add
after `:30` the row
`| SHOMEI_ALLOWED_CLOCK_SKEW_SECONDS | seconds of tolerance the verifier grants exp/nbf/iat (inherited by any downstream using shomei-jwt's verifyToken); must be ≥ 0 | 30 |`,
list `allowedClockSkewSeconds` at `:151`, and note at `:21-22` that a value containing `:` must
be an absolute URI. Tests in `ConfigSpec.hs` (its `setEnv`/`try loadConfigFromEnv` pattern,
`:65-75`): default 30; `"45"` is read; `"-1"` fails; `SHOMEI_ISSUER='https://bad host'` fails
mentioning `StringOrURI`; `shomei:prod` and `https://auth.example.com` pass.

Commit:

```text
feat(config): add allowedClockSkewSeconds and validate issuer and audience at boot

MasterPlan: docs/masterplans/8-trust-boundary-remediation-close-the-august-2026-security-and-performance-review.md
ExecPlan: docs/plans/53-harden-jwt-verification-and-make-the-signing-key-state-machine-atomic.md
Intention: intention_01m10kwqt9eedbjvk91rn726mq
```

### Milestone 3 — Exactly one active key, atomically, with every timestamp stamped

Scope: the migration, the domain record, both store interpreters, `shomei-jwt`'s key and
rotation modules, `Shomei.Server.Keys`, the admin CLI, and their tests; at the end a second
`active` row is a unique-violation error, `keys activate` is one transaction, and `keys list`
shows `revoked=`. Scaffold with `just new-migration shomei-signing-keys-one-active` (creates
`shomei-migrations/migrations/shomei/0032-shomei-signing-keys-one-active.sql` and appends it
to `manifest`); its body, in this order, is:

```sql
SET search_path TO shomei, pg_catalog;
ALTER TABLE shomei_signing_keys ADD COLUMN IF NOT EXISTS revoked_at timestamptz NULL;
-- Make the invariant true before declaring it: keep the row assembleKeys already treats as
-- the signer (greatest activated_at, NULL lowest); retire the rest (still published, trusted).
UPDATE shomei_signing_keys
SET status = 'retired', retired_at = now()
WHERE status = 'active'
  AND key_id <> (
    SELECT key_id FROM shomei_signing_keys WHERE status = 'active'
    ORDER BY activated_at DESC NULLS LAST, created_at DESC, key_id DESC
    LIMIT 1
  );
CREATE UNIQUE INDEX IF NOT EXISTS shomei_signing_keys_one_active
  ON shomei_signing_keys ((1)) WHERE status = 'active';
```

With zero or one active row the subquery makes the `UPDATE` a no-op. Rebuild afterwards.

`shomei-core`: add `revokedAt :: !(Maybe UTCTime)` as the last field of `StoredSigningKey`
(`SigningKey/Domain.hs:44-59`) and to `SigningKey/Store.hs`
`ReplaceActiveSigningKey :: StoredSigningKey -> UTCTime -> SigningKeyStore m ()` (haddock: in
one transaction retire every active key stamping `retired_at = t`, then insert the given key —
or promote the row with that `kid` — as active with `activated_at = t`) plus its helper. In
`InMemory.hs:1166-1180` make `UpdateSigningKeyStatus kid st t` also set the matching timestamp
to `Just t`, and implement the new operation as one `modifyWorld`. Fix the fixtures at
`shomei-postgres/test/Main.hs:1075,1100`.

`shomei-postgres/src/Shomei/SigningKey/Postgres.hs`: widen `KeyRow` to nine columns
(`contrazip9` is already used by `Session/RefreshToken/Postgres.hs:21`), add `revoked_at` to
every `SELECT` and the `INSERT`, and replace `updateStatusStmt` with:

```sql
UPDATE shomei.shomei_signing_keys
SET status = $2,
    activated_at = CASE WHEN $2 = 'active'  THEN $3 ELSE activated_at END,
    retired_at   = CASE WHEN $2 = 'retired' THEN $3 ELSE retired_at END,
    revoked_at   = CASE WHEN $2 = 'revoked' THEN $3 ELSE revoked_at END
WHERE key_id = $1
```

Implement `ReplaceActiveSigningKey k t` with `runTransaction` and two `Tx.statement`s:
`retireActiveStmt :: Statement UTCTime ()` (`UPDATE … SET status = 'retired', retired_at = $1
WHERE status = 'active'`) then `upsertActiveStmt :: Statement KeyRow ()` (the `INSERT` with
`ON CONFLICT (key_id) DO UPDATE SET status = 'active', activated_at = EXCLUDED.activated_at`),
passing `k {status = KeyActive, activatedAt = Just t}`. Tests beside `testPublishableSigningKeys`:
each transition stamps its column; a second active insert fails with
`DependencyUnavailable PostgreSQL` (the unique violation through `postgresUnavailable`);
`replaceActiveSigningKey` leaves one active and the old one `KeyRetired` with `retiredAt`.

`shomei-jwt`: in `Key/Jwt.hs` export `joseAlg :: SigningAlgorithm -> Alg`, set
`jwkAlg ?~ JWSAlg (joseAlg alg)` in `generateSigningKeyFor`, make `toStoredSigningKey` and
`toStoredSigningKeyFor` return `Either Text StoredSigningKey` (the `asPublicKey` `Nothing` case
is `Left ("key " <> kid <> " has no public projection; refusing to store private material as public")`),
and set `revokedAt = Nothing`; callers (`Rotation/Jwt.hs:47`, `Server/Keys.hs:179`,
`Admin/Keys.hs:57`, `Rotation/JwtSpec.hs:37`, `Key/JwtSpec.hs:29,37`, `Protection/JwtSpec.hs:165`)
use `either (throwIO . userError . Text.unpack) pure`. In `Protection/Jwt.hs:173-175` have
`publicJwkFromStored` set `jwkAlg` from `sk.algorithm` when the JSON lacks one (unknown text
leaves it absent), so pre-plan rows publish `alg` too. In `Rotation/Jwt.hs:43-50` replace
insert-then-retire with `replaceActiveSigningKey protected t`. Add to `Rotation/JwtSpec.hs`:
after `rotateSigningKey` over the fake with one active key, exactly one key is active, the old
one is `KeyRetired` with `retiredAt = Just t`, the new one has `activatedAt = Just t`, both
`kid`s are in `currentJwks` and every entry carries `"alg"`; and a revoked key's token is
refused — sign with A, verify against the `JWKSet` decoded from `currentJwks` (`Right`), set A
`KeyRevoked`, decode again, verify (`Left (TokenKeyNotFound (Just kidA))`).

`shomei-server`: in `Keys.hs:119-148` replace `newestActive` with a three-way case (`[one]`;
`[]` → `"no active signing key"`; several → a message naming the kids and
`shomei_signing_keys_one_active`, ending "retire all but one with shomei-admin keys retire"). In
`Admin/Keys.hs`: add `hasql-transaction` to the `shomei-admin` and `shomei-admin-test`
`build-depends`; add `runTx :: Pool -> Transaction a -> IO a`
(`Pool.use pool (Tx.transaction Tx.ReadCommitted Tx.Write t)`, dying like `runSess` but saying
`"another key became active concurrently; run keys list and retry"` on a `23505`); rewrite
`keysActivate` (`:71-81`) so the `pending` check stays outside and the writes are one `runTx`
running `retireActiveStmt` (`… WHERE status = 'active' RETURNING key_id`) then `setActiveStmt`,
printing the returned kids as `retired (auto)`; give `keysRevoke` (`:94-99`) a `setRevokedStmt`
stamping `revoked_at`; in `keysRewrap` (`:111-113`) encrypt every row in memory first, then
write all rows in one `runTx`; widen `KeyRow`, decoder, statements, and `keysList`
(`\trevoked=`). Add to `shomei-server/test/Admin/Main.hs`: after `testLifecycleOverlap`'s second
activation, `scalarInt pool "SELECT count(*) … WHERE status = 'active'"` is `1`; an `execSql`
setting the retired row back to `'active'` fails with `23505`; `keysRevoke` stamps
`revoked_at`; `keysRewrap` still moves every row.

Commit:

```text
fix(keys): make one active signing key a database invariant and activation atomic

MasterPlan: docs/masterplans/8-trust-boundary-remediation-close-the-august-2026-security-and-performance-review.md
ExecPlan: docs/plans/53-harden-jwt-verification-and-make-the-signing-key-state-machine-atomic.md
Intention: intention_01m10kwqt9eedbjvk91rn726mq
```

### Milestone 4 — The documentation is true again

Prose only. In `security.md` Tokens (`:14-21`) rewrite the first bullet: verifiers accept only
`ES256` and `RS256`; the `kid` header selects the verification key and an unknown or missing
`kid` is refused, never tried against every key; the verifier tolerates
`allowedClockSkewSeconds` (default 30) on `exp`/`nbf`/`iat`; access tokens carry `typ: at+jwt`;
JWKS entries carry `alg`. Add a bullet "Algorithm choice and timing": the ES256 default signs
through crypton's generic ECDSA, whose scalar multiplication is not constant-time and which
crypton documents as able to leak the private key under timing analysis; RS256 signs through
RSA blinding (`PKCS15.signSafer`); the review graded the channel plausible, not demonstrated;
recommend RS256 (`SHOMEI_SIGNING_ALG=RS256`, then `keys generate --alg RS256` and
`keys activate`) where an attacker can drive many mints against a co-located host; the default
stays ES256 until a constant-time ES256 exists in the dependency chain. Add `nbf`, `jti` to the
reserved list. In the rotation section (`:50-58`) state that one active key is a
database invariant (`shomei_signing_keys_one_active`), activation is one transaction, and every
transition stamps its timestamp. In `deployment.md:172-199` note that a concurrent second
`keys activate` fails with a clear message and `keys list` shows `revoked=`; in `api.md:497` say
each JWKS entry carries `alg`; add `## Unreleased` entries to the five touched packages'
changelogs (PVP major bumps). Finish with
`rg -n "kid.*identif|newest activat|tries each|allowedSkew" docs README.md`, fix what it finds,
and write Outcomes & Retrospective.

Commit:

```text
docs(security): document the ES256 timing trade-off, kid selection, JWKS alg, and the one-active invariant

MasterPlan: docs/masterplans/8-trust-boundary-remediation-close-the-august-2026-security-and-performance-review.md
ExecPlan: docs/plans/53-harden-jwt-verification-and-make-the-signing-key-state-machine-atomic.md
Intention: intention_01m10kwqt9eedbjvk91rn726mq
```


## Concrete Steps

All commands run from the repository root `/Users/shinzui/Keikaku/bokuno/shomei` inside
`nix develop`; database suites need the local PostgreSQL of `deployment.md`'s process-compose
stack. M1 step 1 — write `Verify/JwtSpec.hs` with only the cases that compile against today's
API (`none`, HS256, RS256-over-EC, future `iat` ±, string `roles`, two-element `aud`, integral
`iat`), register it, and run `cabal build all --enable-tests && cabal test shomei-jwt` before
any source edit. Expected on pre-fix code (paste the real output into Surprises & Discoveries):

```text
    alg none is refused:                              OK
    HS256 with the public key as secret is refused:   OK
    RS256 by an RSA key under the EC kid is refused:  OK
    a future iat within 30 s verifies:                FAIL  Left (TokenOtherError "iat in the future")
    a future iat beyond 30 s is refused:              OK
    a string-valued roles claim is TokenMalformed:    FAIL  expected Left, got Right
    a two-element aud is TokenAudienceInvalid:        FAIL  expected Left, got Right
    iat and exp are whole seconds:                    FAIL
```

The first three pass before and after: they pin holds REV-3 verified (jose excludes `none`;
HS256 matches only `OctKeyMaterial`; RS256 on EC material is `AlgorithmMismatch`). Then make
the edits, add the `kid`/`typ` cases, and repeat until every case is `OK`, with
`cabal test shomei-core shomei-servant shomei-server` still green. M2 — after the loader edits,
`cabal test shomei-server-config-test`, then one manual boot with the KEK exported,
`SHOMEI_ISSUER='https://bad host' PG_CONNECTION_STRING="$PG_CONNECTION_STRING" cabal run exe:shomei-server`,
which must print
`shomei-server: user error (SHOMEI_ISSUER (Dhall field issuer) contains ':' but is not a valid URI (RFC 7519 StringOrURI), got "https://bad host")`.

M3 step 1 — `just new-migration shomei-signing-keys-one-active` prints
`created shomei-migrations/migrations/shomei/0032-shomei-signing-keys-one-active.sql` and
`appended … to …/manifest`. Paste the SQL, run `just migration-check` and
`cabal build all --enable-tests`, and observe the pre-step once on a scratch copy of the dev
database (`createdb shomei_scratch && pg_dump "$PGDATABASE" | psql -q shomei_scratch`):

```bash
psql shomei_scratch -c "UPDATE shomei.shomei_signing_keys SET status='active' WHERE status='retired'"
DATABASE_URL="dbname=shomei_scratch" cabal run -v0 shomei-migrate -- up
psql shomei_scratch -c "SELECT left(key_id,6) kid, status, retired_at FROM shomei.shomei_signing_keys ORDER BY activated_at DESC NULLS LAST"
psql shomei_scratch -c "UPDATE shomei.shomei_signing_keys SET status='active' WHERE status='retired'"
```

```text
UPDATE 1
Applied 0032-shomei-signing-keys-one-active
 OcnLm3 | active  |
 7fQ2aX | retired | 2026-08-27 …
ERROR:  duplicate key value violates unique constraint "shomei_signing_keys_one_active"
```

M3 steps 2–5 — domain and ports, postgres, `shomei-jwt`, server and CLI, in that order, each
followed by `cabal build all --enable-tests && cabal test shomei-postgres shomei-jwt shomei-admin-test shomei-server-test`.
Then, with the KEK exported, `cabal run -v0 exe:shomei-admin -- keys generate`,
`… keys activate <new-kid>`, `… keys revoke <old-kid>`, `… keys list`, which print:

```text
generated pending ES256 key: 7fQ2aX…
activated 7fQ2aX…
retired (auto) OcnLm3…
revoked OcnLm3…
7fQ2aX…  KeyActive   created=… activated=Just … retired=Nothing revoked=Nothing
OcnLm3…  KeyRevoked  created=… activated=Just … retired=Just …  revoked=Just …
```

M4 — edit the docs, run the grep and `cabal test all`, update Progress and Outcomes, commit.


## Validation and Acceptance

Verifier (`cabal test shomei-jwt`, all `OK`): `iat` 10 s ahead verifies, 120 s ahead is refused;
a token signed by a key the JWKS lacks is `Left (TokenKeyNotFound (Just kid))` and one with no
`kid` is `Left (TokenKeyNotFound Nothing)` even when its signature would verify; `alg: none`,
HS256 with the public key, and RS256 under an EC `kid` are `TokenSignatureInvalid`;
`roles: "admin"` is `TokenMalformed`; `aud: ["shomei-clients", "other"]` is
`TokenAudienceInvalid`; `typ: JWT` on an access token is refused, absent `typ` accepted;
`iat`/`exp` are integers; JWKS entries carry `alg`; `rotateSigningKey` leaves one active key
with both timestamps stamped; a revoked key's token is refused.
`cabal test all` ends with every suite `All N tests passed`, including `IdTokenSpec`'s
`TokenAudienceInvalid` case and the servant and server E2E suites, which reach the verifier
through the unchanged `verifyToken`/`runTokenVerifierJwt` signatures. Configuration:
`shomei-server-config-test` proves the default 30, the override, the negative rejection, and
the malformed-issuer refusal while accepting `shomei:prod`; the Concrete Steps boot shows the
refusal for real. State machine:
the `psql` transcript shows a second active row refused by `shomei_signing_keys_one_active`;
`shomei-admin-test` proves one active row after two activations, a hand `UPDATE` to a second
active failing, `revoked_at` stamped, and rewrap moving every row; the CLI transcript shows
`retired (auto)` and `revoked=Just …`. On a running server with `SHOMEI_KEY_REFRESH_INTERVAL=5`,
after `keys activate`, `curl -s localhost:8080/.well-known/jwks.json | jq '.keys[] | {kid, alg}'`
lists both keys with `"alg": "ES256"`, and a token minted before the activation still returns
`200` — plan 29's zero-downtime property, unchanged. Documentation:
`rg -n "keeps identifying which" docs/user/security.md` finds the rewritten sentence, and
nothing under `docs/` claims newest-wins selection.


## Idempotence and Recovery

Source steps are ordinary edits; rebuilding and retesting is always safe. The migration is
idempotent by construction (`ADD COLUMN IF NOT EXISTS`, a no-op `UPDATE` once one key is active,
`CREATE UNIQUE INDEX IF NOT EXISTS`) and pg-migrate records it once; if `just new-migration`
runs twice, delete the second file and its `manifest` line. If the pre-step retired a key an
operator wanted active, set that row's `status` back to `'pending'` with `psql`, then
`shomei-admin keys activate <loser>`, which retires the winner in the same transaction.
Rolling the index back alone is `DROP INDEX shomei.shomei_signing_keys_one_active`; leave the
nullable `revoked_at` in place. A `keys activate` that dies mid-transaction leaves the table
untouched; a concurrent second activation fails with the `23505` message and changes nothing.
Keep the dev database's KEK (plan 32's Surprises): never run the CLI with a throwaway KEK
against a database you intend to boot again.


## Interfaces and Dependencies

Libraries: `jose ^>=0.13` (`Crypto.JWT`: `allowedSkew`, `stringOrUri`, `NumericDate`;
`Crypto.JOSE.JWS`: `validationSettingsAlgorithms`, `signatures`, `header`, `HasKid`, `HasTyp`;
`Crypto.JOSE.JWK.Store.VerificationKeyStore`; `Crypto.JOSE.JWK`: `jwkAlg`, `JWKAlg`);
`hasql-transaction ^>=1.0` (new for the `shomei-admin` executable and its test); crypton 1.1.4
(documentation only). No new packages. After M1, in `Shomei.SigningKey.Verify.Jwt`:

```haskell
data VerifierSettings = VerifierSettings
  { issuer :: !Issuer, audience :: !Audience, allowedClockSkew :: !NominalDiffTime, requireTokenType :: !Bool }
verifierSettingsFromConfig :: ShomeiConfig -> VerifierSettings
newtype KidSelectingKeys = KidSelectingKeys JWKSet -- VerificationKeyStore instance selecting by kid
verifyTokenWith :: VerifierSettings -> JWKSet -> Text -> IO (Either TokenError AuthClaims)
verifyToken :: JWKSet -> ShomeiConfig -> Text -> IO (Either TokenError AuthClaims) -- unchanged, as is runTokenVerifierJwt
checkStringOrUri :: Text -> Either Text ()
```

plus `Shomei.SigningKey.Sign.Jwt.wholeSeconds :: UTCTime -> UTCTime`; `TokenError` gains
`TokenKeyNotFound !(Maybe Text)`; `SigningKeyConfig` gains `allowedClockSkewSeconds :: !Int`;
`reservedClaimKeys` lists twelve names. After M2: `FileConfig.allowedClockSkewSeconds :: Maybe Int`;
env `SHOMEI_ALLOWED_CLOCK_SKEW_SECONDS`; Dhall `allowedClockSkewSeconds : Optional Natural`.
After M3: `StoredSigningKey.revokedAt :: Maybe UTCTime`;
`ReplaceActiveSigningKey :: StoredSigningKey -> UTCTime -> SigningKeyStore m ()` with
`replaceActiveSigningKey`; in `Shomei.SigningKey.Key.Jwt`
`toStoredSigningKey :: UTCTime -> JWK -> Either Text StoredSigningKey`,
`toStoredSigningKeyFor :: SigningAlgorithm -> UTCTime -> JWK -> Either Text StoredSigningKey`,
`joseAlg :: SigningAlgorithm -> Alg`; migration `0032-shomei-signing-keys-one-active.sql`;
index `shomei.shomei_signing_keys_one_active`. Out of scope, for follow-up: publishing
`pending` keys in the JWKS (REV-10 finding 3), the template's refresh on `TokenKeyNotFound`
(`docs/plans/59-…`), flipping `requireTokenType` to `True` (next minor release), and a maximum
`exp − iat` (REV-3 finding 7, not in the MasterPlan).


## Revision Note — 2026-08-27

Milestone 2 corrected the invalid-StringOrURI example from `shomei:prod` to
`https://bad host`. RFC 3986 makes the former a valid scheme/rootless-path URI, so the loader
accepts it and rejects only values that actually fail URI parsing; the Progress, discovery,
decision, work, concrete-step, and validation sections now state that contract consistently.
