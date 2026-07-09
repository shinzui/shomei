---
id: 32
slug: encrypt-signing-private-keys-at-rest
title: "Encrypt Signing Private Keys at Rest"
kind: exec-plan
created_at: 2026-07-07T17:22:22Z
master_plan: "docs/masterplans/5-security-correctness-hardening-make-existing-guarantees-hold.md"
---

# Encrypt Signing Private Keys at Rest

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

Shōmei signs its access tokens (JWTs) with a private signing key. Today that private key
is stored in **plaintext** in PostgreSQL: the `private_key_jwk` column of
`shomei.shomei_signing_keys` is a plain `text` column (created by
`shomei-migrations/sql-migrations/2026-06-03-18-44-56-shomei-signing-keys.sql`), and
`toStoredSigningKey` in `shomei-jwt/src/Shomei/Jwt/Key.hs` serializes the *full* JWK —
including the private scalar `"d"` — into it. The consequence is stark: **anyone with read
access to the database (or a backup, a dump, a misconfigured replica) can forge valid
tokens for every user of every downstream service** that trusts Shōmei's JWKS. Hashing at
rest protects passwords and refresh tokens in this codebase; the single most powerful
secret in the system has no protection at all.

The fix is *envelope encryption*: the private JWK JSON is encrypted with an AEAD cipher
(authenticated encryption — confidentiality plus tamper detection) under a
**key-encryption-key (KEK)** that lives *outside* the database, supplied to the process as
the environment variable `SHOMEI_KEY_ENCRYPTION_KEY` (32 bytes, base64). A database read
then yields only ciphertext; forging tokens requires both the database *and* the
application environment. (Operators who want KMS/HSM-managed keys inject the KEK from
their secret manager — that integration layer sits above Shōmei and is explicitly out of
scope here.)

After this plan: with a KEK configured, every newly generated signing key is stored as
`enc:v1:<nonce>:<ciphertext>` in the existing column; a one-shot, idempotent
`shomei-admin keys encrypt-at-rest` command backfills existing plaintext rows; a
`shomei-admin keys rewrap` command rotates the KEK itself; the server decrypts transparently
at key load; a server that finds encrypted rows but has no KEK **refuses to start** with a
clear message (never silently serves without its keys), while a KEK-less server with only
plaintext rows keeps working (with a warning) so existing deployments do not break.
Decryption is written as a pure `StoredSigningKey -> Either KeyDecryptError JWK` function
so it composes with the centralized key loader that plan 29
(`docs/plans/29-publish-and-hot-reload-the-full-jwks-with-retired-keys.md`) introduces —
this plan must not create a second key-load path (MasterPlan integration point, restated
in full below).


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").

- [x] M1: `Shomei.Jwt.KeyProtection` module: KEK type + base64 parser, ChaCha20-Poly1305
      encrypt/decrypt of the private JWK text with kid-bound AAD, `enc:v1:` format,
      `decryptStoredSigningKey` pure composition function; unit tests (round-trip, tamper,
      wrong KEK, wrong kid, plaintext passthrough, format detection) pass. (2026-07-08)
- [x] M2: KEK loading from `SHOMEI_KEY_ENCRYPTION_KEY` in the server boot and the admin
      CLI env; server key loading decrypts (signer) and reads public material from
      `public_key_jwk` (JWKS/verifier need no KEK); boot policy (refuse / warn) enforced
      and tested. (2026-07-08)
- [x] M2: all insert paths encrypt when a KEK is present: server first-boot generation,
      `shomei-admin keys generate`, `Shomei.Jwt.Rotation` insert path. (2026-07-08)
- [x] M3: `shomei-admin keys encrypt-at-rest` (idempotent backfill) and
      `shomei-admin keys rewrap` (KEK rotation, old KEK via
      `SHOMEI_KEY_ENCRYPTION_KEY_OLD`) implemented with integration tests. (2026-07-08)
- [x] M4: end-to-end proof (plaintext deployment → backfill → rotate → rewrap, tokens
      verifying throughout) captured; `docs/user/security.md` + `docs/user/deployment.md`
      updated; `cabal test all` green. (2026-07-08)
- [x] Living sections updated; Outcomes & Retrospective written. (2026-07-08)


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- **Plan 29 had landed, and its loader was building the JWKS from *private* material.**
  `assembleKeys` converted every publishable row with `fromStoredSigningKey` (the private
  column) and then stripped it to public. That works only while rows are plaintext; under this
  plan it would have made publication depend on the KEK. Restructured so publication and the
  verifier set come from `publicJwkFromStored` and only the signer is decrypted — which is what
  the Decision Log had already called for, and is simply more correct regardless of encryption.
  The MasterPlan's "plan 29 owns the seam, plan 32 hooks into it" contract held: there was
  exactly one place to change.

- **The boot-policy warning only inspects *publishable* rows, so a plaintext `pending` key does
  not trigger it.** Observed live: with a KEK set, `keys generate` under `env -u
  SHOMEI_KEY_ENCRYPTION_KEY` wrote a plaintext pending row, and the next boot logged no
  "some signing keys are still unencrypted" warning, because `loadKeyMaterial` reads only
  `active`+`retired`. The warning does fire once that key is activated, and
  `keys encrypt-at-rest` covers *all* rows (it uses the CLI's `listAllKeys`), so nothing is
  silently left unprotected — but the notice arrives one step later than an operator might
  expect. Closing this properly needs a `ListAllSigningKeys` port operation; noted rather than
  scope-crept.

- **`shomei-admin` did not depend on the `shomei-server` library.** The KEK env-loading helper
  lives in `Shomei.Server.Keys`, so the CLI could not reach it. Added `shomei-server` to the
  executable's `build-depends` (an exe depending on its own package's library is legal and is
  what `shomei-admin-test` already did) rather than duplicating the parse-and-fail logic.

- **`keyEncryptionKeyFromBase64`'s error message originally hardcoded
  `SHOMEI_KEY_ENCRYPTION_KEY`,** which would be wrong when parsing
  `SHOMEI_KEY_ENCRYPTION_KEY_OLD` for a rewrap. The message is now variable-agnostic
  (`"is not a valid key-encryption key: …"`) and the caller prefixes the name it read:

  ```text
  user error (SHOMEI_KEY_ENCRYPTION_KEY is not a valid key-encryption key: it decodes to 31 bytes, not 32. Generate one with: head -c 32 /dev/urandom | base64)
  ```

- **`crypton`'s `Poly1305.Auth` already has a constant-time `Eq`** (`Data.ByteArray.constEq`),
  so comparing the computed tag against the stored one with `==` is safe; no manual `constEq`
  is needed. Confirmed by reading `crypton/Crypto/MAC/Poly1305.hs` (`instance Eq Auth`).

- **`keysRewrap` aborts with `exitFailure`, which a test must catch as an `ExitCode`
  exception.** That is how `testRewrapWithWrongOldKekModifiesNothing` asserts "zero rows
  modified" — otherwise the abort would take the test process down with it.

- **The first `protect → decrypt → sign → verify` test failed with `TokenExpired`,** not a
  crypto error: it minted claims at a fixed 2026-07-08T00:00Z epoch and the verifier checks
  expiry against the real clock. Fixed to use `getCurrentTime`, like the suite's other
  sign/verify specs. Worth knowing before blaming the cipher.

- **The dev database was left encrypted under a throwaway KEK and had to be restored.** After
  the M4 runbook, `shomei.shomei_signing_keys` held five `enc:v1:` rows whose KEK existed only
  in the session scratchpad — so the next plain `cabal run exe:shomei-server` would have
  *refused to boot*, exactly as designed. Recovery, per the plan's Idempotence section: delete
  the rows and let the next KEK-less boot regenerate one plaintext active key. Anyone repeating
  this runbook on a database they care about must keep the KEK.


## Decision Log

Record every decision made while working on the plan.

- Decision: AEAD cipher = **ChaCha20-Poly1305** (crypton's
  `Crypto.Cipher.ChaChaPoly1305`), 32-byte key, 12-byte random nonce per encryption,
  16-byte tag.
  Rationale: `crypton` (already a dependency of `shomei-jwt` and `shomei-postgres`) ships
  a dedicated, hard-to-misuse module for it, it is constant-time in pure software (no
  reliance on AES-NI being present/used correctly), and it is the same primitive class as
  AES-256-GCM with no relevant security difference at our scale. AES-256-GCM through
  crypton requires assembling `Crypto.Cipher.AES` + `Crypto.Cipher.Types.AEAD` by hand —
  more surface for mistakes, no benefit. The format is versioned (`v1`) precisely so a
  future cipher change is a new prefix, not a debate.
  Date: 2026-07-07

- Decision: Storage format is a **format-versioned single column** — the existing
  `private_key_jwk text` column holds either plaintext JWK JSON (legacy) or
  `enc:v1:<base64url nonce>:<base64url ciphertext-with-appended-tag>`.
  Rationale: plaintext JWK JSON always starts with `{`, so the `enc:v1:` prefix is an
  unambiguous, cheap discriminator; a single column means **no schema migration at all**
  (nothing to coordinate with the codd migration embed-at-compile-time machinery), a
  trivially incremental backfill (row-by-row UPDATE), and painless rollback semantics.
  Dedicated `nonce`/`ciphertext`/`format_version` columns were rejected: they buy
  queryability nobody needs for an opaque secret, at the cost of a migration and a
  three-way consistency invariant.
  Date: 2026-07-07

- Decision: The AEAD *associated data* (AAD — bytes that are authenticated but not
  encrypted) is the key's `kid` (`StoredSigningKey.keyId`).
  Rationale: binds each ciphertext to its row, so an attacker with database write access
  cannot swap ciphertexts between rows (e.g. re-labeling an old compromised key as the
  active one) without the decryption failing. Free to add, standard practice.
  Date: 2026-07-07

- Decision: The KEK is **not** a `ShomeiConfig` field; it is read directly from the
  environment (`SHOMEI_KEY_ENCRYPTION_KEY`) into a dedicated `KeyEncryptionKey` newtype
  with no `Show`/`ToJSON` instances, by the server boot and the admin CLI env setup.
  Rationale: `ShomeiConfig` derives `Show` and `ToJSON` (it is logged and serializable by
  design); a secret in that record is one debug line away from a log leak. The dedicated
  newtype makes accidental printing a type error.
  Date: 2026-07-07

- Decision: Boot policy — if **any** stored key row is encrypted and no KEK is configured,
  the server (and any admin command that needs private keys) **refuses to start** with
  `signing keys are encrypted at rest but SHOMEI_KEY_ENCRYPTION_KEY is not set`; if no row
  is encrypted and no KEK is set, it runs exactly as today but logs a one-line warning
  recommending encryption; if a KEK is set, plaintext rows are still readable (warn +
  recommend `keys encrypt-at-rest`) and all *writes* encrypt.
  Rationale: refusing on encrypted-without-KEK is the only safe option (the alternative is
  a server that cannot sign, or one that silently regenerates keys and orphans every
  outstanding token). Warn-and-run on plaintext keeps the feature strictly opt-in — no
  existing deployment breaks on upgrade — while the mixed-mode read tolerance is what
  makes the backfill non-atomic-safe: rows can be encrypted one at a time while a live
  server keeps loading both forms.
  Date: 2026-07-07

- Decision: JWKS publication and verifier construction read the **public** column
  (`public_key_jwk`) and never need the KEK; only the *signer* requires decrypting
  `private_key_jwk`.
  Rationale: minimizes the blast radius of the KEK dependency (a wrong KEK cannot break
  verification of outstanding tokens or the published JWKS, only signing) and is simply
  more correct — publication code had no business parsing private material in the first
  place. This refines plan 29's loader, which this plan coordinates with (see Interfaces).
  Date: 2026-07-07

- Decision: KEK rotation is an explicit offline command (`shomei-admin keys rewrap`,
  old KEK from `SHOMEI_KEY_ENCRYPTION_KEY_OLD`, new from `SHOMEI_KEY_ENCRYPTION_KEY`),
  not an online dual-KEK read path.
  Rationale: rows are few (signing keys, not user data), so a rewrap is milliseconds; a
  permanent two-KEK decryption path doubles the secret-handling surface forever to save
  one maintenance command. `rewrap` also encrypts any remaining plaintext rows, so it
  subsumes the backfill.
  Date: 2026-07-07

- Decision: Soft dependency on plan 29 handled per the MasterPlan: decryption is the pure
  function `decryptStoredSigningKey :: Maybe KeyEncryptionKey -> StoredSigningKey ->
  Either KeyDecryptError JWK` in `shomei-jwt`, and whichever loader exists calls it. If
  plan 29 has landed, hook it into `Shomei.Server.Keys.loadKeyMaterial` (the single load
  path it owns); if not, hook it into today's `bootstrapKeys` at the one
  `fromStoredSigningKey` call — and plan 29 later inherits the hook because it is
  reachable only via `shomei-jwt`'s conversion function. In no case does this plan add a
  second place that parses `private_key_jwk`.
  Date: 2026-07-07

- Decision (realized): plan 29 had landed, so the hook went into
  `Shomei.Server.Keys.loadKeyMaterial`, and that function was restructured so publication uses
  `publicJwkFromStored` while only the signer calls `decryptStoredSigningKey`.
  Rationale: as written by plan 29, the loader parsed the *private* column for every publishable
  key and then stripped it to public — which would have made the JWKS depend on the KEK. The
  refinement was already in this plan's Decision Log; implementing it also removed a smaller
  wrong (publication had no business touching private material).
  Date: 2026-07-08

- Decision: `Shomei.Server.App.Env` gains `envKek :: Maybe KeyEncryptionKey`.
  Rationale: `reloadKeys` (plan 29's periodic/SIGHUP refresh) must decrypt the signer, so the
  KEK has to outlive `buildEnv`. Re-reading the environment at reload time would work but could
  silently pick up a *different* KEK mid-process. `KeyEncryptionKey` has no `Show`/`ToJSON`, so
  carrying it in `Env` cannot leak it into a log line — unlike putting it in `ShomeiConfig`,
  which this plan's Decision Log already rejected for exactly that reason.
  Date: 2026-07-08

- Decision: `shomei-admin` (the executable) now depends on the `shomei-server` library.
  Rationale: `loadKekFromEnv`/`loadNamedKekFromEnv` live in `Shomei.Server.Keys`; duplicating
  the base64-parse-and-die logic in the CLI would create a second place for the KEK contract to
  drift. An executable depending on its own package's library is ordinary Cabal, and the
  `shomei-admin-test` suite already did it.
  Date: 2026-07-08

- Decision: `keyEncryptionKeyFromBase64` returns a variable-agnostic error; callers prefix the
  environment variable name.
  Rationale: `keys rewrap` parses two different variables. A hardcoded
  `SHOMEI_KEY_ENCRYPTION_KEY` in the message would misdirect an operator whose
  `SHOMEI_KEY_ENCRYPTION_KEY_OLD` was the malformed one.
  Date: 2026-07-08

- Decision: The boot-policy warning inspects only publishable rows; a plaintext `pending` key
  does not warn.
  Rationale: `loadKeyMaterial` lists exactly the rows it reads, and adding a "list every row"
  query would mean a new `SigningKeyStore` port operation for a warning. The exposure is
  bounded — `keys encrypt-at-rest` covers all rows, and the warning fires as soon as the key is
  activated. Recorded in Surprises & Discoveries as a known gap rather than fixed here.
  Date: 2026-07-08


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

**The purpose is met, and it is checkable in one query.** After
`shomei-admin keys encrypt-at-rest`, `SELECT count(*) … WHERE private_key_jwk LIKE '%"d"%'`
returns `0`: no private scalar survives anywhere in the table. A database read, a backup, or a
dump no longer yields the ability to forge tokens for every downstream service. Forging now
needs the database *and* the process environment.

Everything the plan promised exists: `enc:v1:` envelopes under ChaCha20-Poly1305 with kid-bound
AAD; a KEK type that cannot be printed; transparent decryption at load; an idempotent backfill;
an all-or-nothing KEK rewrap; a server that refuses to start on encrypted-rows-without-a-KEK and
merely warns on plaintext-without-a-KEK, so no existing deployment breaks on upgrade. No schema
migration was needed. All of it was observed against a live server, not only unit-tested.

**The decision that paid off most was making publication independent of the KEK.** Plan 29's
loader parsed the private column for every publishable key; this plan repointed publication and
the verifier key set at `public_key_jwk`. The consequence is that a wrong or missing KEK can stop
Shōmei minting *new* tokens but can never break verification of outstanding ones, and never
changes what `/.well-known/jwks.json` serves — demonstrated by the rewrap step, where a token
issued before the KEK rotation still returned `200` afterwards.

**Gaps, none blocking:**

- The boot warning inspects publishable rows only, so a plaintext `pending` key goes unremarked
  until it is activated. Fixing it properly wants a `ListAllSigningKeys` port operation.
- There is no `keys decrypt-at-rest`. Returning to plaintext means a rewrap-style pass or
  deleting and regenerating the keys — fine for development, and deliberately awkward for
  production, but the asymmetry is worth naming.
- Rollback ordering is load-bearing and only documented, not enforced: once rows are encrypted,
  an older binary cannot read them. `deployment.md` says to backfill only after the binary you
  would roll back *to* is running. Nothing checks this.
- `rotateSigningKeyFor` (the library rotation) still writes plaintext by default; encrypted
  deployments must call `rotateSigningKeyForWith`. It has no in-tree callers today
  (`rg -n "rotateSigningKey" --type haskell` finds only its own module and a comment), and
  `shomei-admin keys generate` — the path operators actually use — encrypts. But a library
  consumer who follows the older name silently writes a plaintext row into an encrypted table.
  Its haddock says so; nothing enforces it.

`rg -n "fromStoredSigningKey" --type haskell` now finds only its own definition and tests, which
is the check that no second load path was introduced.

**Lesson.** The plan's instruction to write decryption as a *pure* `StoredSigningKey -> Either
KeyDecryptError JWK` function, and its insistence that plan 29 keep exactly one stored→live
conversion point, meant this plan changed one call site rather than hunting for parsers of
`private_key_jwk`. The `rg` sweep the plan prescribed found no others. Cross-plan integration
contracts written before either plan is implemented actually work — when they name a function
signature rather than a vague seam.


## Context and Orientation

Shōmei is a multi-package Haskell (Cabal) project built inside a Nix devshell. Packages
touched: `shomei-jwt` (the only package that interprets key material; already depends on
`crypton`, the cryptography library — verify in `shomei-jwt/shomei-jwt.cabal`
`build-depends`), `shomei-server` (boot sequence + the `shomei-admin` operational CLI),
and tests. `shomei-core`/`shomei-postgres` treat key material as opaque `Text` and are
**unchanged** (the opacity is exactly what makes a single-column ciphertext format
drop-in).

Exact current state (verified against the working tree):

**The table** — `shomei-migrations/sql-migrations/2026-06-03-18-44-56-shomei-signing-keys.sql`:

```sql
CREATE TABLE IF NOT EXISTS shomei_signing_keys (
  key_id          text PRIMARY KEY,
  algorithm       text NOT NULL,
  public_key_jwk  text NOT NULL,
  private_key_jwk text NOT NULL,   -- plaintext JWK JSON including the private "d"
  status          text NOT NULL,
  created_at      timestamptz NOT NULL,
  activated_at    timestamptz NULL,
  retired_at      timestamptz NULL
);
```

**Serialization** — `shomei-jwt/src/Shomei/Jwt/Key.hs` lines 72–85: `toStoredSigningKey`
encodes the public projection into `publicKeyJwk` and **the full private key** into
`privateKeyJwk` (`enc k` where `k` is the complete JWK). Lines 94–99:
`fromStoredSigningKey :: StoredSigningKey -> Either Text JWK` — `Aeson.eitherDecodeStrict`
of `privateKeyJwk`; this is the single stored→live conversion point in the codebase.
`StoredSigningKey` itself is `shomei-core/src/Shomei/Domain/SigningKey.hs` (opaque `Text`
fields; core never imports jose).

**Read paths** (who parses `private_key_jwk` today — enumerate with
`rg -n "fromStoredSigningKey|privateKeyJwk" --type haskell`):
`Shomei.Server.Keys.bootstrapKeys` (`shomei-server/src/Shomei/Server/Keys.hs`, line ~47 —
loads the active key at boot; if plan 29 has landed this is `loadKeyMaterial`),
`Shomei.Jwt.Rotation.currentJwks` (`shomei-jwt/src/Shomei/Jwt/Rotation.hs`, lines 62–70 —
parses private JWKs only to immediately strip them for the public JWKS; this plan repoints
it at `public_key_jwk`), and tests.

**Write paths** (who inserts rows): `Shomei.Server.Keys.ensureActiveKey` (first-boot
generation → `insertSigningKey` effect), `Shomei.Jwt.Rotation.rotateSigningKeyFor`
(library rotation → `insertSigningKey`), and the admin CLI
`shomei-server/app/Shomei/Admin/Keys.hs` — `keysGenerate` (line ~44) builds the record
via `toStoredSigningKeyFor` and inserts with its module-local raw-SQL `insertKeyStmt`
(line ~214); the same module's other statements (`findByKidStmt` ~174, `listAllStmt`,
`listPublishableStmt` ~204, the status updates) read/write rows too. The admin CLI
deliberately uses raw `hasql` SQL instead of the effect stack (documented in its module
header) — this plan keeps that style for the new subcommands.

**Crypto inventory** — `crypton` provides `Crypto.Cipher.ChaChaPoly1305` (incremental
AEAD: `nonce12`, `initialize`, `finalizeAAD . appendAAD`, `encrypt`/`decrypt`,
`finalize` → 16-byte `Auth` tag), `Crypto.Random.getRandomBytes`, and
`Data.ByteArray.Encoding.convertToBase/convertFromBase` (`Base64URLUnpadded`) — all
already used elsewhere in the repo (`shomei-postgres/src/Shomei/Crypto.hs` is the local
style reference for crypton usage). Constant-time equality for the tag is handled inside
the AEAD `decrypt`+`finalize` comparison (use `Data.ByteArray.constEq` when comparing tags
manually).

**Admin CLI command tree** — `shomei-server/app/Admin.hs`: `keysParser` currently offers
`generate | activate | retire | revoke | list`; new subcommands register there. The CLI
builds its database pool/env in `shomei-server/app/Shomei/Admin/Env.hs`.

**KEK generation** (operator side): `head -c 32 /dev/urandom | base64` — 32 random bytes,
base64-encoded (44 characters); this is what `SHOMEI_KEY_ENCRYPTION_KEY` must contain.

Relationship to plan 29 (soft dependency, per the MasterPlan dependency graph): plan 29
centralizes key loading in `Shomei.Server.Keys.loadKeyMaterial` and adds hot reload. The
two plans touch the same seam; the reconciliation contract is in this plan's Decision Log
and Interfaces sections. This plan is implementable before or after plan 29.

Build/test commands (repository root, inside `nix develop`): `cabal build all`,
`cabal test all`; per-package `cabal test shomei-jwt`, `cabal test shomei-server` (the
server/admin suite provisions ephemeral databases). Live database: `just create-database`
or `cabal run shomei-admin -- migrate` (no new migration is added by this plan).


## Plan of Work

Four milestones: M1 is the pure cryptography module (fully testable in isolation), M2
threads the KEK through the server/CLI and all read/write paths, M3 adds the operational
commands (backfill, rewrap), M4 proves the story end-to-end and documents it.

### Milestone M1 — `Shomei.Jwt.KeyProtection`: the pure envelope

Scope: a new module in `shomei-jwt` (add to `exposed-modules` in
`shomei-jwt/shomei-jwt.cabal`) containing every byte of cryptography in this plan, with
exhaustive unit tests and zero dependencies on server/CLI code.

```haskell
-- | Envelope encryption of stored signing-key private material (at-rest protection).
--
-- Format v1 (single text column, versioned prefix):
--   "enc:v1:" <> base64url(nonce, 12 bytes) <> ":" <> base64url(ciphertext <> tag)
-- Cipher: ChaCha20-Poly1305; AAD = the key's kid, binding ciphertext to its row.
-- Plaintext legacy rows are JWK JSON (first byte '{') and are detected by prefix.
module Shomei.Jwt.KeyProtection
  ( KeyEncryptionKey,            -- abstract; no Show/ToJSON
    keyEncryptionKeyFromBase64,  -- :: Text -> Either Text KeyEncryptionKey
    KeyDecryptError (..),
    isEncryptedPrivateJwk,       -- :: Text -> Bool  ("enc:v1:" prefix)
    encryptPrivateJwk,           -- :: KeyEncryptionKey -> Text {-kid-} -> Text {-jwk json-} -> IO Text
    decryptPrivateJwk,           -- :: Maybe KeyEncryptionKey -> Text {-kid-} -> Text -> Either KeyDecryptError Text
    protectStoredSigningKey,     -- :: Maybe KeyEncryptionKey -> StoredSigningKey -> IO StoredSigningKey
    decryptStoredSigningKey,     -- :: Maybe KeyEncryptionKey -> StoredSigningKey -> Either KeyDecryptError JWK
    publicJwkFromStored,         -- :: StoredSigningKey -> Either Text JWK  (public column; never needs a KEK)
  )
where
```

Semantics to implement precisely:

- `keyEncryptionKeyFromBase64`: strict base64 decode (`convertFromBase Base64`), require
  exactly 32 bytes, else `Left` with a message naming the env var and the
  `head -c 32 /dev/urandom | base64` recipe.
- `encryptPrivateJwk kek kid jwkJson`: 12 random bytes via `getRandomBytes`;
  ChaCha20-Poly1305 `initialize kek nonce` → `finalizeAAD (appendAAD (utf8 kid) st)` →
  `encrypt (utf8 jwkJson)` → `finalize` tag; emit
  `"enc:v1:" <> b64url nonce <> ":" <> b64url (cipher <> tag)` (16-byte tag appended).
- `decryptPrivateJwk mKek kid stored`:
  - no `enc:v1:` prefix → `Right stored` when it parses as an object later (plaintext
    passthrough — return the text unchanged regardless of `mKek`);
  - prefix present and `mKek = Nothing` → `Left KeyEncryptedButNoKek`;
  - malformed structure (missing `:`, bad base64, nonce ≠ 12, ct < 16) →
    `Left (MalformedEncryptedKey <reason>)`;
  - tag mismatch (wrong KEK, tampered ciphertext, or wrong kid AAD) →
    `Left KeyDecryptFailed` — one constructor for all three, deliberately
    indistinguishable.
- `KeyDecryptError = KeyEncryptedButNoKek | MalformedEncryptedKey Text |
  KeyDecryptFailed | KeyJsonInvalid Text` (the last for post-decrypt JSON parse
  failures), with `Show`/`Eq`.
- `decryptStoredSigningKey mKek sk` = `decryptPrivateJwk mKek sk.keyId sk.privateKeyJwk`
  then `Aeson.eitherDecodeStrict` → `KeyJsonInvalid` on failure. **This is the
  composition function named in the MasterPlan integration point.**
- `protectStoredSigningKey`: `Nothing` → unchanged; `Just kek` → if already encrypted,
  unchanged (idempotent); else replace `privateKeyJwk` with the ciphertext form.
  `publicKeyJwk` is never encrypted.
- `publicJwkFromStored`: decode `sk.publicKeyJwk` (the mirror of `fromStoredSigningKey`
  for the public column).

Tests (new module in `shomei-jwt`'s tasty suite, registered like its existing specs):
round-trip (`decrypt (encrypt x) == Right x`) across several kids and key algorithms;
`isEncryptedPrivateJwk` on both forms; plaintext passthrough with and without a KEK;
no-KEK-on-encrypted → `KeyEncryptedButNoKek`; wrong KEK → `KeyDecryptFailed`; flipped
ciphertext byte → `KeyDecryptFailed`; same ciphertext presented under a different kid →
`KeyDecryptFailed` (the AAD test); nonce uniqueness smoke check (two encryptions of the
same plaintext differ); `protectStoredSigningKey` idempotence
(`protect (protect sk) == protect sk` up to the nonce — assert the already-encrypted case
returns the input unchanged); `decryptStoredSigningKey` end-to-end on a
`generateSigningKeyFor ES256` (and `RS256`) key: generate → `toStoredSigningKeyFor` →
protect → decrypt → sign/verify a claims round-trip with the recovered JWK using the
suite's existing sign/verify helpers.

Acceptance: `cabal test shomei-jwt` green with the new group.

### Milestone M2 — KEK plumbing and transparent decryption at load

Scope: the server and admin CLI learn the KEK; every read path decrypts (or avoids
private material); every write path encrypts; the boot policy is enforced.

1. KEK loading — in `shomei-server/src/Shomei/Server/Keys.hs` add:

   ```haskell
   -- | Read SHOMEI_KEY_ENCRYPTION_KEY (32 bytes, base64). Absent/empty -> Nothing;
   -- present but malformed -> refuse to start (never run half-configured).
   loadKekFromEnv :: IO (Maybe KeyEncryptionKey)
   ```

   (`lookupEnv`, then `keyEncryptionKeyFromBase64`, `ioError . userError` on `Left`.)
   Call it from `Shomei.Server.Boot.buildEnv` and from the admin CLI's env setup
   (`shomei-server/app/Shomei/Admin/Env.hs`), passing the result to the key code below.

2. Read path — thread `Maybe KeyEncryptionKey` into the key loader:
   - If plan 29 has landed: `loadKeyMaterial :: Maybe KeyEncryptionKey -> Pool -> IO
     (Either Text LoadedKeys)`; the signer conversion becomes
     `decryptStoredSigningKey mKek activeRow` (mapping `KeyDecryptError` into the `Left`
     text), and the verifier-set/JWKS construction switches to `publicJwkFromStored`
     (per the Decision Log, publication never needs the KEK).
   - If plan 29 has not landed: `bootstrapKeys :: Maybe KeyEncryptionKey ->
     SigningAlgorithm -> Pool -> IO (JWK, JWKSet)`, replacing its
     `fromStoredSigningKey stored` call with `decryptStoredSigningKey mKek stored`.
   - `Shomei.Jwt.Rotation.currentJwks`: switch its per-row conversion from
     `fromStoredSigningKey` to `publicJwkFromStored` — after which
     `fromStoredSigningKey`'s remaining callers are only the signer path and tests;
     keep the function but add a Haddock warning that encrypted rows must go through
     `decryptStoredSigningKey`.

3. Boot policy — in the same loader, before converting: if `mKek == Nothing` and any row
   `isEncryptedPrivateJwk`, fail with the exact message from the Decision Log; if
   `mKek == Nothing` and all rows plaintext, `hPutStrLn stderr` the recommendation
   warning; if `mKek /= Nothing` and any row is plaintext, warn recommending
   `shomei-admin keys encrypt-at-rest`.

4. Write paths — encrypt on insert everywhere a `StoredSigningKey` is persisted:
   - `Shomei.Server.Keys.ensureActiveKey`: after `toStoredSigningKeyFor`, apply
     `protectStoredSigningKey mKek` (the function is `IO` because of the nonce; the
     surrounding code is already in `Eff es` with `IOE`, use `liftIO`). Thread `mKek` in
     as a parameter.
   - `Shomei.Jwt.Rotation`: add `rotateSigningKeyForWith :: Maybe KeyEncryptionKey ->
     SigningAlgorithm -> Eff es JWK` that protects before `insertSigningKey`; keep
     `rotateSigningKeyFor` = `rotateSigningKeyForWith Nothing` for source compatibility
     and mark it Haddock-deprecated for encrypted deployments.
   - `shomei-server/app/Shomei/Admin/Keys.hs` `keysGenerate`: apply
     `protectStoredSigningKey` to the pending record before `insertKeyStmt`. Thread the
     `Maybe KeyEncryptionKey` from the admin env into the `keys*` functions that need it
     (only `keysGenerate` plus M3's new commands; the status-transition commands never
     touch key material).

5. Tests — `shomei-server` test suite (`shomei-server/test/`, which provisions ephemeral
   databases): (a) with a KEK, first-boot generation stores a `private_key_jwk` with the
   `enc:v1:` prefix (assert by raw SQL read) and the server's signer still produces
   verifiable tokens (drive whatever the E2E spec already does post-boot); (b) with
   encrypted rows and no KEK, boot fails and the error message names
   `SHOMEI_KEY_ENCRYPTION_KEY`; (c) no KEK + plaintext rows behaves exactly as today
   (regression); (d) JWKS construction succeeds with no KEK even when private material is
   encrypted (public-column independence).

Acceptance: `cabal test all` green; behavior matrix (a)–(d) pinned by tests.

### Milestone M3 — `keys encrypt-at-rest` and `keys rewrap`

Scope: the operational commands that move a real deployment from plaintext to encrypted
and rotate the KEK later.

1. In `shomei-server/app/Shomei/Admin/Keys.hs` add (module-local raw SQL, matching house
   style — an `UPDATE shomei.shomei_signing_keys SET private_key_jwk = $2 WHERE key_id =
   $1` statement plus the existing `listAllStmt`):

   ```haskell
   -- | Encrypt every plaintext private_key_jwk in place. Idempotent: encrypted rows
   -- are skipped. Requires SHOMEI_KEY_ENCRYPTION_KEY.
   keysEncryptAtRest :: KeyEncryptionKey -> Pool -> IO ()

   -- | Re-wrap every row under a new KEK: decrypt with the old, encrypt with the new;
   -- plaintext rows are simply encrypted with the new KEK. Requires both
   -- SHOMEI_KEY_ENCRYPTION_KEY (new) and SHOMEI_KEY_ENCRYPTION_KEY_OLD.
   keysRewrap :: KeyEncryptionKey {-old-} -> KeyEncryptionKey {-new-} -> Pool -> IO ()
   ```

   Both iterate `listAllKeys`, transform with M1 functions, `UPDATE` row-by-row, and
   print a summary (`encrypted 3 keys, skipped 1 already-encrypted`, `rewrapped 4 keys`).
   `keysRewrap` aborts with a clear error on the first `KeyDecryptFailed` (wrong old KEK)
   *before* writing anything: do the full decrypt pass in memory first, then the update
   pass, so a wrong `_OLD` value cannot half-rewrap the table.

2. Register the subcommands in `shomei-server/app/Admin.hs` `keysParser`
   (`command "encrypt-at-rest" …`, `command "rewrap" …`); their runners pull the KEK(s)
   from the environment (`loadKekFromEnv`, plus an analogous read of
   `SHOMEI_KEY_ENCRYPTION_KEY_OLD` for rewrap) and `die` with usage guidance when a
   required one is absent.

3. Integration tests (`shomei-server/test/Admin/Main.hs`, following its existing
   subcommand-test style): seed a plaintext key; run `keysEncryptAtRest`; assert the raw
   column now has the prefix and `decryptStoredSigningKey` recovers a working JWK; run it
   again → output reports 0 encrypted / all skipped and the column bytes are unchanged
   (idempotence). Then `keysRewrap` old→new; assert decryption fails with the old KEK and
   succeeds with the new; run rewrap with a *wrong* old KEK against a fresh copy → aborts,
   zero rows modified.

Acceptance: `cabal test shomei-server` green including the new admin cases.

### Milestone M4 — end-to-end proof and documentation

Scope: no new behavior; the operator story demonstrated live, then written down.

Execute the transcript in Validation and Acceptance against a real server + database and
paste the output there. Update `docs/user/security.md` (new "Signing-key encryption at
rest" section: threat model — database read no longer yields forgery; envelope scheme,
`enc:v1` format, kid-bound AAD; boot policy; explicit note that KMS/HSM integration is the
operator's layer above Shōmei — inject the KEK from your secret manager) and
`docs/user/deployment.md` (`SHOMEI_KEY_ENCRYPTION_KEY`, `SHOMEI_KEY_ENCRYPTION_KEY_OLD`,
generation recipe, migration runbook: set KEK → restart → `keys encrypt-at-rest` → verify;
rewrap runbook). Write the Outcomes & Retrospective.


## Concrete Steps

All commands from `/Users/shinzui/Keikaku/bokuno/shomei`, inside `nix develop`.

```bash
cabal build all
cabal test shomei-jwt            # M1
cabal test shomei-server         # M2, M3 (ephemeral databases)
cabal test all                   # sweep
```

Fallout sweeps after signature changes:

```bash
rg -n "fromStoredSigningKey|privateKeyJwk" --type haskell   # every read path — all must be accounted for
rg -n "toStoredSigningKey|insertSigningKey|insertKeyStmt" --type haskell   # every write path
rg -n "bootstrapKeys|loadKeyMaterial" --type haskell        # loader threading
```

Live end-to-end (M4):

```bash
just create-database
cabal run exe:shomei-server                      # plaintext boot; expect the "consider
                                                 # encrypting signing keys" warning line
# stop the server; generate a KEK and re-run everything under it
export SHOMEI_KEY_ENCRYPTION_KEY="$(head -c 32 /dev/urandom | base64)"
cabal run shomei-admin -- keys encrypt-at-rest
```

Expected:

```text
encrypted 1 key(s), skipped 0 already-encrypted
```

```bash
psql -d "$PGDATABASE" -tAc \
  "SELECT left(private_key_jwk, 7) FROM shomei.shomei_signing_keys"
```

Expected:

```text
enc:v1:
```

```bash
cabal run exe:shomei-server &                    # boots clean, no warning
curl -s -X POST http://localhost:8080/auth/signup -H 'Content-Type: application/json' \
  -d '{"email":"kek@example.com","password":"correct horse battery staple","displayName":"K"}' \
  | jq -r .token.accessToken > /tmp/tok
curl -s -o /dev/null -w '%{http_code}\n' http://localhost:8080/auth/me \
  -H "Authorization: Bearer $(cat /tmp/tok)"     # → 200 (signing + verifying through the envelope)

# negative check: KEK removed → refusal
kill %1
env -u SHOMEI_KEY_ENCRYPTION_KEY cabal run exe:shomei-server
```

Expected:

```text
shomei-server: user error (signing keys are encrypted at rest but SHOMEI_KEY_ENCRYPTION_KEY is not set)
```

```bash
# KEK rotation
export SHOMEI_KEY_ENCRYPTION_KEY_OLD="$SHOMEI_KEY_ENCRYPTION_KEY"
export SHOMEI_KEY_ENCRYPTION_KEY="$(head -c 32 /dev/urandom | base64)"
cabal run shomei-admin -- keys rewrap            # → "rewrapped 1 key(s)"
cabal run exe:shomei-server                      # boots and signs under the new KEK;
                                                 # the pre-rotation token still verifies (public keys unchanged)
```


## Validation and Acceptance

Acceptance is the full lifecycle, observed:

1. **Unit level (M1).** `cabal test shomei-jwt`: round-trip, tamper/wrong-KEK/wrong-kid
   rejection (`KeyDecryptFailed`), plaintext passthrough, no-KEK-on-encrypted
   (`KeyEncryptedButNoKek`), idempotent protection, and a protect→decrypt→sign→verify
   chain for both ES256 and RS256 keys.
2. **Server level (M2).** With a KEK: fresh boot stores `enc:v1:`-prefixed private
   material and issued tokens verify (HTTP `200` on `/auth/me`). Without a KEK against
   encrypted rows: boot refuses with the exact documented message. Without a KEK against
   plaintext rows: today's behavior plus a warning line. The served
   `/.well-known/jwks.json` is byte-equivalent whether or not the process holds the KEK.
3. **Operational level (M3).** `keys encrypt-at-rest` converts N plaintext rows, is a
   no-op on re-run, and never touches `public_key_jwk`. `keys rewrap` swaps KEKs
   all-or-nothing (a wrong old KEK modifies zero rows), after which the old KEK fails and
   the new succeeds.
4. **End to end (M4).** The Concrete Steps transcript reproduces: warning → backfill →
   `enc:v1:` in the column → clean boot → live signup/verify → refusal without KEK →
   rewrap → clean boot, with the pre-rotation token still verifying throughout (public
   material never changed).
5. **The security claim itself:** after backfill, `SELECT private_key_jwk FROM
   shomei.shomei_signing_keys` yields only `enc:v1:…` ciphertext — a database dump no
   longer contains a private scalar `"d"` anywhere
   (`psql … -c "SELECT count(*) FROM shomei.shomei_signing_keys WHERE private_key_jwk LIKE '%\"d\"%'"`
   returns `0`).

`cabal test all` green closes the plan.

### Executed transcript (2026-07-08)

`cabal test all -j1`: 12 of 12 suites PASS, exit 0. `shomei-jwt` gained 19 unit cases
(`KeyProtection`), `shomei-admin-test` gained 7 integration cases. Run against the dev database,
which already held five plaintext keys from plan 29's rotation runbook. Server binary from
`cabal list-bin exe:shomei-server`, port 8099.

**1. Plaintext deployment warns.**

```text
[shomei] warning: signing keys are stored unencrypted; set SHOMEI_KEY_ENCRYPTION_KEY and run 'shomei-admin keys encrypt-at-rest' to protect them
[shomei] listening on :8099
```

**2. Backfill, and its idempotence.**

```text
$ export SHOMEI_KEY_ENCRYPTION_KEY="$(head -c 32 /dev/urandom | base64)"
$ shomei-admin keys encrypt-at-rest
encrypted 5 key(s), skipped 0 already-encrypted
$ shomei-admin keys encrypt-at-rest
encrypted 0 key(s), skipped 5 already-encrypted

$ psql -tAq -d shomei -c "SELECT key_id, status, left(private_key_jwk,7) FROM shomei.shomei_signing_keys"
nuGfPxo…|retired|enc:v1:
OcnLm3J…|retired|enc:v1:
KoWTZm_…|revoked|enc:v1:
T2KaW0m…|retired|enc:v1:
LAJ3hT4…|active |enc:v1:
```

**The security claim, checked directly** — no private scalar `"d"` survives anywhere:

```text
$ psql -tAq -d shomei -c "SELECT count(*) FROM shomei.shomei_signing_keys WHERE private_key_jwk LIKE '%\"d\"%'"
0
```

**3. Clean boot under the KEK; signing and verifying through the envelope.**

```text
[shomei] listening on :8099          # no warning
signup token kid: LAJ3hT4R1SK8RHGBFyjP8df2KRlBXwf52Y_OlcNN2YM
/auth/me -> 200
jwks keys: 4
```

**4. Refusal, in both directions.** Exit code 1 in each case; the server never starts.

```text
# KEK removed
user error (signing keys are encrypted at rest but SHOMEI_KEY_ENCRYPTION_KEY is not set)

# wrong KEK
user error (signing key LAJ3hT4R1SK8RHGBFyjP8df2KRlBXwf52Y_OlcNN2YM did not decrypt: SHOMEI_KEY_ENCRYPTION_KEY is wrong, or the row was tampered with)
```

A malformed KEK is fatal too, rather than being silently ignored:

```text
user error (SHOMEI_KEY_ENCRYPTION_KEY is not a valid key-encryption key: it decodes to 31 bytes, not 32. Generate one with: head -c 32 /dev/urandom | base64)
```

**5. Rewrap is all-or-nothing, then rotates.**

```text
# wrong old KEK: aborts, md5 of all private columns unchanged
$ shomei-admin keys rewrap
shomei-admin: cannot decrypt key nuGfPxo… with SHOMEI_KEY_ENCRYPTION_KEY_OLD (KeyDecryptFailed); no rows were modified
exit=1
rows unchanged? YES

# real old KEK
$ shomei-admin keys rewrap
rewrapped 5 key(s)
exit=0
```

**6. After the rewrap: the old KEK is dead, the new one boots, and outstanding tokens live.**

```text
# old KEK
user error (signing key LAJ3hT4… did not decrypt: SHOMEI_KEY_ENCRYPTION_KEY is wrong, or the row was tampered with)

# new KEK
[shomei] listening on :8099
pre-rewrap token /auth/me -> 200     # public material never changed
fresh login /auth/me     -> 200      # signs under the new KEK
```

**Write paths.** `keys generate` with a KEK writes `enc:v1:`; without one it writes `{"crv":…`
(and — see Surprises & Discoveries — a plaintext *pending* row does not trip the boot warning,
because the loader reads only publishable rows).

Acceptance items 1–5 of this section all observed. The dev database was afterwards restored to a
single plaintext active key (see Surprises & Discoveries); a real deployment must keep its KEK.


## Idempotence and Recovery

There is **no schema migration** — the format lives inside the existing column — so
nothing needs codd coordination and there is no migration to roll back.

Every operation is idempotent or all-or-nothing by design: `protectStoredSigningKey`
skips already-encrypted input; `keys encrypt-at-rest` re-runs as a no-op; `keys rewrap`
validates the complete decrypt pass in memory before its first write. The backfill is
also safe against a *live* server: mixed plaintext/encrypted rows read fine (M2 boot
policy), and each row update is a single-statement atomic UPDATE.

Recovery paths, spelled out:

- **Lost KEK, server still running:** the loaded signer works until restart. Immediately
  generate + activate a *new* key (`keys generate`/`keys activate` work as long as the
  process has a KEK for the insert — if the KEK is truly lost, unset it, delete the
  encrypted rows, and generate fresh; outstanding tokens die, which is the honest outcome
  of losing the KEK). Back up the KEK like the database.
- **Wrong KEK deployed:** boot fails at signer decryption with `KeyDecryptFailed` — fix
  the env var; nothing was modified.
- **Roll back the feature:** to return a row to plaintext during development, decrypt via
  a `keys rewrap`-style pass (or simply delete dev keys and regenerate without a KEK).
  Production rollback of the *code* is safe as long as rows are plaintext; once rows are
  encrypted, older binaries cannot read them — so backfill (`encrypt-at-rest`) should
  happen only after the new binary is the one you would roll back *to*. State this in the
  deployment runbook.

Re-running any build/test command is always safe.


## Interfaces and Dependencies

Dependencies: `crypton` (ChaCha20-Poly1305, random bytes, base64) — already in
`shomei-jwt`'s `build-depends` (verify; add if the specific modules need it), `memory`
(`Data.ByteArray`) via crypton's ecosystem, `aeson`, `jose` — all existing. No new
packages. No database schema changes.

Definitions that must exist at the end (full module paths):

- `Shomei.Jwt.KeyProtection.KeyEncryptionKey` (abstract, no `Show`),
  `keyEncryptionKeyFromBase64 :: Text -> Either Text KeyEncryptionKey`,
  `KeyDecryptError (..)`, `isEncryptedPrivateJwk :: Text -> Bool`,
  `encryptPrivateJwk :: KeyEncryptionKey -> Text -> Text -> IO Text`,
  `decryptPrivateJwk :: Maybe KeyEncryptionKey -> Text -> Text -> Either KeyDecryptError Text`,
  `protectStoredSigningKey :: Maybe KeyEncryptionKey -> StoredSigningKey -> IO StoredSigningKey`,
  `decryptStoredSigningKey :: Maybe KeyEncryptionKey -> StoredSigningKey -> Either KeyDecryptError JWK`,
  `publicJwkFromStored :: StoredSigningKey -> Either Text JWK`.
- `Shomei.Server.Keys.loadKekFromEnv :: IO (Maybe KeyEncryptionKey)`; the key loader
  (`loadKeyMaterial` if plan 29 landed, else `bootstrapKeys`) takes
  `Maybe KeyEncryptionKey` and enforces the boot policy.
- `Shomei.Jwt.Rotation.rotateSigningKeyForWith :: (IOE :> es, SigningKeyStore :> es,
  Clock :> es) => Maybe KeyEncryptionKey -> SigningAlgorithm -> Eff es JWK`;
  `currentJwks` reads public material only.
- `Shomei.Admin.Keys.keysEncryptAtRest :: KeyEncryptionKey -> Pool -> IO ()` and
  `keysRewrap :: KeyEncryptionKey -> KeyEncryptionKey -> Pool -> IO ()`, wired as
  `shomei-admin keys encrypt-at-rest` / `keys rewrap` in `shomei-server/app/Admin.hs`;
  `keysGenerate` encrypts when a KEK is present.
- Environment contract: `SHOMEI_KEY_ENCRYPTION_KEY` (32 bytes base64; required iff any
  row is encrypted), `SHOMEI_KEY_ENCRYPTION_KEY_OLD` (rewrap only). Deliberately **not**
  part of `ShomeiConfig` (Decision Log).

Integration points with other plans (restated from the MasterPlan): plan 29
(`docs/plans/29-publish-and-hot-reload-the-full-jwks-with-retired-keys.md`) owns the
key-loading seam ("load all publishable keys, build signer + JWKS, refresh periodically");
this plan supplies the pure `decryptStoredSigningKey` / `publicJwkFromStored` functions
that loader calls per row, and must not create any second load path. If both plans are in
flight, reconcile on the loader's shape before either merges: the agreed contract is that
*all* parsing of `private_key_jwk` goes through `decryptStoredSigningKey`, and JWKS/
verifier construction uses `publicJwkFromStored`. Out of scope, restated: KMS/HSM
integration (the operator injects the KEK from their secret manager), encrypting other
tables (refresh/one-time tokens are already stored hashed), and multi-tenant KEKs.
