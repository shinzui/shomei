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

- [ ] M1: `Shomei.Jwt.KeyProtection` module: KEK type + base64 parser, ChaCha20-Poly1305
      encrypt/decrypt of the private JWK text with kid-bound AAD, `enc:v1:` format,
      `decryptStoredSigningKey` pure composition function; unit tests (round-trip, tamper,
      wrong KEK, wrong kid, plaintext passthrough, format detection) pass.
- [ ] M2: KEK loading from `SHOMEI_KEY_ENCRYPTION_KEY` in the server boot and the admin
      CLI env; server key loading decrypts (signer) and reads public material from
      `public_key_jwk` (JWKS/verifier need no KEK); boot policy (refuse / warn) enforced
      and tested.
- [ ] M2: all insert paths encrypt when a KEK is present: server first-boot generation,
      `shomei-admin keys generate`, `Shomei.Jwt.Rotation` insert path.
- [ ] M3: `shomei-admin keys encrypt-at-rest` (idempotent backfill) and
      `shomei-admin keys rewrap` (KEK rotation, old KEK via
      `SHOMEI_KEY_ENCRYPTION_KEY_OLD`) implemented with integration tests.
- [ ] M4: end-to-end proof (plaintext deployment → backfill → rotate → rewrap, tokens
      verifying throughout) captured; `docs/user/security.md` + `docs/user/deployment.md`
      updated; `cabal test all` green.
- [ ] Living sections updated; Outcomes & Retrospective written.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

(None yet.)


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


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

(To be filled during and after implementation.)


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
