---
id: 56
slug: bound-password-hashing-for-real-and-refuse-to-boot-on-unsafe-configuration
title: "Bound Password Hashing for Real and Refuse to Boot on Unsafe Configuration"
kind: exec-plan
created_at: 2026-08-27T03:23:49Z
intention: "intention_01m10kwqt9eedbjvk91rn726mq"
master_plan: "docs/masterplans/8-trust-boundary-remediation-close-the-august-2026-security-and-performance-review.md"
---

# Bound Password Hashing for Real and Refuse to Boot on Unsafe Configuration

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.

This is **EP-6** (Phase 2, no dependencies) of MasterPlan 8
(`docs/masterplans/8-trust-boundary-remediation-close-the-august-2026-security-and-performance-review.md`).
It closes the review's one operational high — the Argon2 hash that escapes the limiter built by
`docs/plans/35-bound-argon2-hashing-concurrency-and-container-aware-runtime-tuning.md` — and folds in
every "refuse to boot on a bad configuration" finding, because they share one test style. Per
MasterPlan 8's Integration Points it owns the configuration-strictness switch and the Dhall schema
(item 7), and it keeps Argon2 hashing *outside* any transaction: computed and forced before any store
is called, so `docs/plans/55-…`'s unit-of-work operations receive a finished hash (item 5).


## Purpose / Big Picture

Today a signup or password change hands the credential store an *unevaluated* Argon2 hash. The
64 MiB, ~100 ms derivation runs when hasql serializes the row: on the request thread, holding one of
ten pooled connections, in an uninterruptible foreign call, outside the permit
`SHOMEI_HASHING_MAX_CONCURRENCY` was meant to enforce. Ten concurrent signups pin ten connections and
allocate 640 MiB with no bound, and the test meant to catch this passes because it never looks at the
hash it measured. Separately, the server boots on configurations it cannot run: Argon2 parameters the
C core rejects (`p=16` with `m=64` KiB turns every signup into a `500`), a misspelled Dhall key
(`cookieSecue = False` is silently ignored), a typo in a WebAuthn policy (silently downgraded), and an
empty origin list (every passkey ceremony crashes). The Dhall schema lags the loader by twenty keys.

After this plan an operator can observe: (1) eight concurrent signups against a limiter of one are
serialized — a test forces every returned hash and shows the post-return forcing windows never
overlap; (2) `SHOMEI_ARGON2_PARALLELISM=16 SHOMEI_ARGON2_MEMORY_KIB=64` exits at boot naming the rule
it broke, and anything else the C core rejects fails a trial derivation before the pool exists;
(3) `cookieSecue = False`, `webauthnAttestation = "nope"`, or `webauthnOrigins = []` refuses to boot
naming the key; (4) `config/shomei-types.dhall` lists every loader key as an optional field and a test
fails whenever loader and schema drift; (5) `shomei_password_credentials (user_id)` is unique and
indexed, every pooled connection carries `statement_timeout` and `idle_in_transaction_session_timeout`,
and the sweeper runs on its own connection.


## Progress

- [x] (2026-08-27T20:30:00Z) M1: `hashPasswordArgon2id` forces the digest; `HashPassword` arm
      evaluates like the `Verify*` arms; `Argon2Failure`; rewritten limiter test (pre-fix false
      pass and regression failure recorded); load-test `SIGNUP_LOOPS`.
- [x] (2026-08-27T20:34:00Z) M2: `argon2HardFloor` in the loader and `shomei-admin`;
      `trialArgon2Derivation` in `Boot.main` before the pool is acquired.
- [ ] M3: `FileConfig` rejects unknown keys (silent acceptance observed first); strict WebAuthn enums
      on the Dhall path; `configSigningAlgorithm` returns `Either`; empty origins refused at boot and
      `originsOf` uses `NE.nonEmpty`; `SHOMEI_EMAIL_VERIFICATION_REQUIRED`.
- [ ] M4: `config/shomei-types.dhall` as `{ Type, default }`, every field `Optional`; the twenty
      lagging keys; example rewritten; ConfigSpec sync test.
- [ ] M5: migration (number allocated by `just new-migration`; `0029` at the time of writing) with the unique index; `acquirePool` sets both timeouts from `dbStatementTimeoutMs`
      (default 30 000); sweeper on a dedicated one-connection pool.
- [ ] `nix fmt`; `cabal build all --enable-tests`; `cabal test all`; CHANGELOG `Unreleased` entries;
      MasterPlan 8 Progress and registry; ADR distillation pass.


## Surprises & Discoveries

Found while writing this plan (2026-08-27) against HEAD `5dfd2a6` (code identical to `ee00382`):

- **The signing-algorithm loader already refuses bad text.** `normalizeSigningAlg`
  (`shomei-server/src/Shomei/Server/Config.hs:1126-1130`) errors for both `SHOMEI_SIGNING_ALG`
  (`:1116-1122`) and the Dhall key (`:308`). The silent `ES256` the review found (REV-2 finding 22) is
  `shomei-core/src/Shomei/Config.hs:484-486`, `either (const ES256) id`, reachable only by an embedding
  host that builds `ShomeiConfig` by hand. M3 fixes it there.
- **`SHOMEI_EMAIL_VERIFICATION_REQUIRED` is genuinely absent**: `grep -rn EMAIL_VERIFICATION
  --include='*.hs' .` finds nothing; only the Dhall key exists (`Server/Config.hs:191, 324`).
- **The lagging-key diff is exactly the review's twenty** (field names of `FileConfig` against the
  `key : Type` lines of the schema): the loader has 69 fields, the schema 49.

(Implementation discoveries go below this line.)

- **The pre-fix limiter suite is a confirmed false pass.** Before changing production code,
  `cabal test shomei-postgres --test-options='-p "hashing limiter"'` passed all four existing
  cases in 0.52 seconds, including `the PasswordHasher interpreter acquires a permit`; none forced
  the returned `PasswordHash`, so the suite did not observe where Argon2 actually ran.

  ```text
  hashing limiter: peak concurrency never exceeds the limit (1):     OK (0.52s)
  hashing limiter: peak concurrency never exceeds the limit (2):     OK (0.31s)
  hashing limiter: the PasswordHasher interpreter acquires a permit: OK
  hashing limiter: the dummy verification path is bounded too:       OK (0.02s)
  ```

- **The replacement test catches the escaped thunk and the fix bounds real memory.** Against the
  old interpreter it failed on overlapping post-return forcing windows. With the digest and
  `PasswordHash` forced under the permit, the same case passed in 0.06 seconds and the full
  73-case `shomei-postgres` suite passed. On the same local server and database, eight signup loops
  reduced peak RSS from 626 MB to 237 MB; the lower 20.2 signups/s is the intended back-pressure
  from a concurrency limit of two. The harness created and then removed 1,152 uniquely prefixed
  users, 1,154 sessions and refresh tokens, their audit rows, 140 probe attempts, and the generated
  test signing key.

  ```text
  pre-fix:  signups/s=37.3  signup_503s=0  peak_rss=626MB
  post-fix: signups/s=20.2  signup_503s=0  peak_rss=237MB
  ```

- **The pure hard floor and real implementation agree at the lane boundary.** The new PostgreSQL
  test observes both rejection for `Argon2Params 64 1 16` and success at
  `Argon2Params 128 1 16`; the suite now has 74 passing cases. With the rejected values supplied
  to the executable, configuration exits 1 with the `m ≥ 8 × p` rule and emits no `[shomei] db
  pool` line, proving the refusal happens before pool acquisition. `shomei-server-config-test`
  passes and `shomei-admin` rebuilds against the same check.


## Decision Log

- Decision: Force the *digest* with `evaluate` inside `hashPasswordArgon2id`, and also `evaluate` the
  returned `PasswordHash` in the interpreter's `HashPassword` arm.
  Rationale: The digest is the expensive value; a strict `ByteString` in weak-head normal form (WHNF —
  evaluated to its outermost constructor) is fully allocated, so forcing it runs the derivation there,
  inside the permit and before any store is called. Forcing only the `Text` would work but rests on a
  library invariant a reader must know. The interpreter-level `evaluate` mirrors the `Verify*` arms so
  the bound survives changes to the hashing function. Date: 2026-08-27
- Decision: A rejected derivation is a typed exception `Argon2Failure` thrown by `hashPasswordArgon2id`,
  converting crypton's `CryptoFailed` and the `ErrorCall` its C binding raises; `verifyPasswordArgon2id`
  stays pure.
  Rationale: The failure is a configuration error whose home is boot time, where `trialArgon2Derivation`
  catches it; at runtime it is unreachable after M2, and if it ever fires warp logs a named exception
  instead of `argon2: hash: internal error`. Verification's parameters come from strings this module
  wrote after boot validation. Date: 2026-08-27
- Decision: The Dhall schema uses record completion — the file evaluates to
  `{ Type = { field : Optional T, … }, default = { field = None T, … } }`, used as `Shomei::{ port = Some 9090 }`
  (`T::r` means `(T.default // r) : T.Type`).
  Rationale: Dhall never coerces `T` to `Optional T`, so any all-optional schema costs a `Some` per set
  field; `::` makes every omitted field `None` and type-checks `default` against `Type`, which lets later
  plans add keys without breaking every file. A closed record plus a shipped defaults record was
  rejected as a second source of truth for every default. Breaking for annotated files only; the loader
  is unchanged. Date: 2026-08-27
- Decision: One key, `dbStatementTimeoutMs` / `SHOMEI_DB_STATEMENT_TIMEOUT_MS`, default 30 000, sets
  both `statement_timeout` (PostgreSQL's cap on one statement's server-side execution time) and
  `idle_in_transaction_session_timeout`; 0 disables both.
  Rationale: Every Shōmei statement is single-row or a ≤1000-row indexed batch and takes milliseconds;
  30 s is two orders above the slowest legitimate one (a cold-cache sweeper batch) yet bounds how long a
  lock wait or runaway plan can hold a slot while other requests fail their 10 s acquisition. No
  transaction waits on anything but PostgreSQL (`Transaction` has no `MonadIO`), so an idle-in-transaction
  longer than a statement is a leaked connection and the same bound fits. The value has no relation to
  the Argon2 budget: hashing was never inside a statement — before M1 it ran client-side during parameter
  encoding while the connection was checked out but idle; after M1 it finishes before the store is
  called. Migrations use pg-migrate's own connection. Date: 2026-08-27
- Decision: The sweeper gets a dedicated one-connection pool rather than a pause between batches.
  Rationale: The finding is that a long drain *occupies a request slot*; a pause shortens the occupation
  but keeps it, a separate pool removes it with no new key. hasql-pool's default idleness timeout
  (10 min) closes the connection between hourly cycles. Cost: one connection in the `max_connections`
  budget. Date: 2026-08-27
- Decision: Validate Argon2 twice at boot — a pure rule in the loader and a real trial derivation in
  `Boot.main` before the pool is acquired.
  Rationale: The rule names the variable and the formula; the trial catches whatever else the C
  `validate_inputs` or the allocator refuses on this machine, costs one derivation (~100 ms at defaults),
  and doubles as the warm-up plan 35 found the first derivation needs. Date: 2026-08-27


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

The repository at `/Users/shinzui/Keikaku/bokuno/shomei` is a multi-package Haskell workspace (GHC
9.12.4); build with `cabal build all --enable-tests`, test with `cabal test all`, format with `nix fmt`,
all inside `nix develop`. Database tests start an ephemeral PostgreSQL themselves
(`Shomei.Migrations.TestSupport.withShomeiMigratedDatabase`). Architecture Decision Records: `docs/adr/`
does not exist (re-checked 2026-08-27) and no ADR in any registered Mori project concerns this work; if
the completion pass creates the bundle, follow `.claude/skills/exec-plan/ADR.md`.

**Where hashing lives.** `shomei-postgres/src/Shomei/Account/Password/Hash/Postgres.hs`. The derivation
is lazy today:

```haskell
-- Hash/Postgres.hs:168-172
hashPasswordArgon2id :: Argon2Params -> Text -> IO PasswordHash
hashPasswordArgon2id params pw = do
  salt <- getRandomBytes saltLen :: IO ByteString
  let digest = deriveArgon2 (toOptions params) (TE.encodeUtf8 pw) salt
  pure (PasswordHash (phcEncode params salt digest))
```

`PasswordHash` is `newtype PasswordHash = PasswordHash Text` (`shomei-core/src/Shomei/Account/Password/Domain.hs:30`),
so `pure` returns a thunk — an unevaluated expression, run when first inspected. The interpreter
(`:289-298`) wraps both verify arms in `evaluate` but the hash arm is bare:
`HashPassword (PlainPassword pw) -> liftIO (withHashingPermit limiter (hashPasswordArgon2id params pw))`
(`:290-291`). The thunk is forced when the credential store encodes the row —
`shomei-postgres/src/Shomei/Account/Credential/Postgres.hs:37-38` builds the tuple with
`passwordHashText pwHash` for `insertCredentialStmt`; `updatePasswordHashStmt` (`:136-145`) does the same
for reset and change. `deriveArgon2` (`:117-121`) turns crypton's `CryptoFailed` into `error`; crypton
itself raises `error "argon2: hash: internal error"` when the C core rejects the parameters
(`Crypto/KDF/Argon2.hs:131`, crypton 1.1.4; the C rule at `cbits/argon2/core.c:477-485` is `m_cost ≥ 8`,
`m_cost ≥ 8 × lanes`, `t_cost ≥ 1`, `lanes ≥ 1`). `withHashingPermit` (`:265-277`) is plan 35's STM
permit bracket (a permit is one slot in the limiter), `argon2WarningFloor` (`:94-106`) the OWASP warning
the boot prints, `dummyHashFor` (`:210-214`) the equal-cost miss-path hash. The limiter tests are
`shomei-postgres/test/Main.hs:1852-1911`; the one at `:1878-1896` forks eight `hashPassword` calls,
asserts `peak <= 2 && peak >= 1`, and discards the hashes unforced — so it passes today.

**Configuration.** `shomei-server/src/Shomei/Server/Config.hs` loads defaults → Dhall file → env.
`loadDhallFile` (`:272-283`) shells out to `dhall-to-json` and decodes into `FileConfig` (`:160-259`),
which `deriving anyclass (FromJSON)` — unknown keys are ignored. Argon2 values are only checked positive
(`:459-461`). `mergeWebAuthn` (`:895-915`) uses `parseUserVerification`/`parseAttestation` (`:980-996`),
which default on unrecognized text, while the env path (`:952-967`) errors. `originsEnv` (`:947-951`)
drops blanks, so `SHOMEI_WEBAUTHN_ORIGINS=","` yields `[]`. In `shomei-core/src/Shomei/Config.hs`,
`configSigningAlgorithm` (`:484-486`) silently defaults and `WebAuthnConfig.origins :: [Text]` (`:281`).
`shomei-webauthn/src/Shomei/WebAuthn/Ceremony.hs:216-217` is
`originsOf cfg = NE.fromList (map WA.Origin (origins cfg))`, a crash on `[]`. In
`shomei-server/src/Shomei/Server/Boot.hs`, `main` (`:85-148`) prints the Argon2 warning (`:94-96`), the
`validate*` helpers (`:158-205`) show the house style for refusing to boot, `installSweeper` (`:234-273`)
forks the sweeper on the request pool, and `buildEnv` (`:278-328`) acquires the pool and calls
`bootstrapKeys kek (configSigningAlgorithm cfg) pool`. `config/shomei-types.dhall` is a closed 49-key
record; `config/shomei.example.dhall` annotates itself `: Schema`. `docs/user/deployment.md` holds the
env table (`:9-57`), the hashing section (`:66-83`), the Dhall section (`:131-164`, whose note admits
the schema lags), and the sweeper section (`:305-373`). `shomei-server/test/Shomei/Server/ConfigSpec.hs`
(suite `shomei-server-config-test`) mutates env vars, so its cases run inline in one `testCase`.

**Persistence.** `shomei-postgres/src/Shomei/Persistence/Pool/Postgres.hs` builds the pool from size
and acquisition timeout only; hasql-pool 1.4 exposes `Hasql.Pool.Config.initSession :: Session () -> Setting`,
run on every new connection. `Maintenance/Postgres.hs:204-214` `drainTable` loops `Pool.use` until a
batch deletes nothing. Migration `shomei-migrations/migrations/shomei/0003-…sql` creates
`shomei_password_credentials` with `user_id uuid NOT NULL REFERENCES shomei_users(user_id)` and no
index; migrations are allocated with `just new-migration <slug>` (never hand-numbered), which creates
the file and appends it to the manifest. `acquirePool` is called from `Boot.buildEnv`,
`shomei-server/app/Shomei/Admin/Env.hs:50`, `shomei-postgres/test/Main.hs:425`, and
`shomei-server/test/Admin/Main.hs:108`. A *PHC string* is the self-describing
`$argon2id$v=19$m=…,t=…,p=…$salt$digest` hash format every stored credential uses.


## Plan of Work

### Milestone M1 — force the hash inside the permit

Scope: the derivation for a new password happens inside the limiter permit, before any database call,
and a test that forces its results proves it.

In `Hash/Postgres.hs` add a typed exception and make the hash function force its work (import
`Control.Exception (Exception, Handler (..), catches, throw, throwIO)` and `Crypto.Error (CryptoError)`;
change `deriveArgon2`'s `CryptoFailed e` branch to `throw e`; export `Argon2Failure (..)`):

```haskell
-- | The Argon2 implementation refused to derive — parameters its C core rejects. Unreachable
-- after boot validation ('trialArgon2Derivation'); named so a log line says why.
newtype Argon2Failure = Argon2Failure Text
  deriving stock (Show)

instance Exception Argon2Failure

hashPasswordArgon2id :: Argon2Params -> Text -> IO PasswordHash
hashPasswordArgon2id params pw = do
  salt <- getRandomBytes saltLen :: IO ByteString
  -- Forced HERE, inside whatever permit the caller holds: a strict ByteString in WHNF is fully
  -- allocated. Returned lazily, the derivation ran when hasql encoded the credential row.
  digest <-
    evaluate (deriveArgon2 (toOptions params) (TE.encodeUtf8 pw) salt)
      `catches` [ Handler \(ErrorCall msg) -> throwIO (Argon2Failure (Text.pack msg)),
                  Handler \(e :: CryptoError) -> throwIO (Argon2Failure (Text.pack (show e))) ]
  evaluate (PasswordHash (phcEncode params salt digest))
```

Make the interpreter's hash arm `liftIO (withHashingPermit limiter (hashPasswordArgon2id params pw >>= evaluate))`
and extend the comment above it: "`HashPassword` too — the 2026-08 review found this arm was the one
without `evaluate`, and the derivation ran during row encoding inside `Pool.use`."

Replace `testInterpreterHonorsTheLimiter` (`test/Main.hs:1878-1896`) with a test that forces every hash
and measures where the work happened (imports: `GHC.Clock (getMonotonicTimeNSec)`,
`GHC.Conc (getNumCapabilities)`, `Control.Exception (evaluate)`, `Data.List (tails)`):

```haskell
-- | Eight threads share one permit. After the interpreter returns, each forces its hash and times
-- that. Work inside the permit is serialized, so if the derivation escaped as a thunk the post-return
-- windows are where the Argon2 work runs — concurrent, overlapping, milliseconds instead of microseconds.
testInterpreterForcesTheHashInsideThePermit :: TestTree
testInterpreterForcesTheHashInsideThePermit =
  testCase "hashing limiter: the interpreter forces HashPassword inside its permit" do
    limiter <- newHashingLimiter 1
    dones <- replicateM 8 newEmptyMVar
    forM_ (zip [1 :: Int ..] dones) \(i, done) ->
      void $ forkIO do
        h <- runEff . runPasswordHasherCrypto limiter cheapParams $ hashPassword (PlainPassword ("pw" <> Text.pack (show i)))
        t0 <- getMonotonicTimeNSec
        let PasswordHash phc = h
        _ <- evaluate (Text.length phc)
        t1 <- getMonotonicTimeNSec
        putMVar done (i, h, t0, t1)
    results <- mapM takeMVar dones
    peak <- peakHashingConcurrency limiter
    assertBool "the interpreter never acquired a permit" (peak >= 1)
    assertBool ("interpreter allowed " <> show peak <> " concurrent hashes") (peak <= 1)
    let windows = [(t0, t1) | (_, _, t0, t1) <- results]
        overlap (a0, a1) (b0, b1) = a0 < b1 && b0 < a1
    caps <- getNumCapabilities
    when (caps >= 2) $
      forM_ [(a, b) | a : rest <- tails windows, b <- rest] \(a, b) ->
        assertBool ("post-return forcing windows overlap: " <> show (a, b)) (not (overlap a b))
    -- Capability-independent half: one cheap derivation sets the bar on this machine.
    w0 <- getMonotonicTimeNSec
    _ <- hashPasswordArgon2id cheapParams "warm"
    w1 <- getMonotonicTimeNSec
    forM_ results \(i, h, t0, t1) -> do
      assertBool ("hash " <> show i <> " was forced after the interpreter returned") ((t1 - t0) * 2 < (w1 - w0))
      assertBool ("hash " <> show i <> " must verify") (verifyPasswordArgon2id ("pw" <> Text.pack (show i)) h)
```

The unsafe foreign call cannot be preempted, so on one capability eight escaped derivations would
serialize by accident; hence the overlap half is guarded and the timing half is not (the suite runs
with `-N`). Also force the results in `testHashingLimiterBoundsConcurrency` (`:1861`) before reading
`peak`. **Before editing production code, run the existing test and record its false pass, then add the
new test and watch it fail** (Concrete Steps, step 1).

Extend `scripts/argon2-load-test.sh` with `SIGNUP_LOOPS` (default `0`): when set, the load phase runs
that many loops of `POST /v1/auth/signup` with unique emails instead of login loops (each signup is one
`HashPassword`); the summary gains `signups/s` and `signup_503s`. Record before/after peak RSS with
`SIGNUP_LOOPS=8`: before, RSS grows with the loop count (each in-flight signup holds 64 MiB outside the
bound); after, it plateaus near two hashes' worth. Do not gate on `signup_503s`: with ten connections
and a 10 s acquisition timeout, 503s need thousands of concurrent signups this harness cannot generate.

Commit:

```text
fix(postgres): force Argon2 hashing inside the limiter permit

hashPasswordArgon2id evaluated its digest lazily, so the 64 MiB derivation ran when hasql
encoded the credential row -- on a pooled connection, outside the bound. Force the digest
inside the permit, evaluate in the HashPassword arm like the Verify arms, name the C
core's rejection (Argon2Failure), and make the limiter test force every hash and assert
its post-return forcing windows never overlap. SIGNUP_LOOPS added to the load test.

MasterPlan: docs/masterplans/8-trust-boundary-remediation-close-the-august-2026-security-and-performance-review.md
ExecPlan: docs/plans/56-bound-password-hashing-for-real-and-refuse-to-boot-on-unsafe-configuration.md
Intention: intention_01m10kwqt9eedbjvk91rn726mq
```

### Milestone M2 — refuse to boot on Argon2 parameters the implementation rejects

Scope: a parameter set the C core rejects fails the boot naming the variable and the rule; anything
else it rejects fails a trial derivation before the pool exists. In `Hash/Postgres.hs` add and export:

```haskell
-- | @Nothing@ when the reference implementation accepts the parameters, otherwise why not. Mirrors
-- crypton's C @validate_inputs@; each value must also fit the Word32 the binding passes, or
-- 'toOptions' silently wraps it.
argon2HardFloor :: Argon2Params -> Maybe Text
argon2HardFloor p
  | any (> 4294967295) [p.memoryKiB, p.iterations, p.parallelism] = Just "every Argon2 parameter must fit in 32 bits"
  | p.iterations < 1 = Just "iterations must be at least 1"
  | p.parallelism < 1 = Just "parallelism must be at least 1"
  | p.memoryKiB < max 8 (8 * p.parallelism) =
      Just ("memoryKiB must be at least 8 × parallelism and at least 8; got m=" <> tshow p.memoryKiB <> " KiB for p=" <> tshow p.parallelism <> " (needs " <> tshow (max 8 (8 * p.parallelism)) <> ")")
  | otherwise = Nothing
  where
    tshow = Text.pack . show

-- | Derive once with the configured parameters so a set the C core (or the allocator) refuses fails
-- the boot rather than every signup. One derivation's cost; also warms the arena.
trialArgon2Derivation :: Argon2Params -> IO (Either Argon2Failure ())
trialArgon2Derivation params = try (void (hashPasswordArgon2id params "shomei boot trial"))
```

In `Server/Config.hs` `overlayFromEnvBoth`, after the three `requirePositive` Argon2 lines (`:459-461`),
add `for_ (argon2HardFloor argon2) \why -> ioError (userError ("SHOMEI_ARGON2_* (Dhall fields argon2*) are rejected by the Argon2 implementation: " <> Text.unpack why))`.
In `Boot.main`, immediately after the warning-floor `traverse_` (`:94-96`):

```haskell
  trialArgon2Derivation settings.serverArgon2 >>= \case
    Right () -> pure ()
    Left (Argon2Failure why) -> do
      hPutStrLn stderr ("[shomei] FATAL: the Argon2 implementation rejected the configured parameters (m=" <> show settings.serverArgon2.memoryKiB <> "KiB,t=" <> show settings.serverArgon2.iterations <> ",p=" <> show settings.serverArgon2.parallelism <> "): " <> Text.unpack why)
      exitFailure
```

Apply the same check in `shomei-server/app/Shomei/Admin/Env.hs` `argon2FromEnv` (`users create` hashes
with these values). ConfigSpec `argon2Settings` gains `SHOMEI_ARGON2_PARALLELISM=16` with
`SHOMEI_ARGON2_MEMORY_KIB=64` → `expectUserErrorNaming "SHOMEI_ARGON2_MEMORY_KIB"`, and `m=8,p=1`
accepted. `shomei-postgres/test/Main.hs` gains `testArgon2HardFloorMatchesTheImplementation`: for
`Argon2Params 64 1 16` both `argon2HardFloor` is `Just` and `trialArgon2Derivation` is `Left`; for the
boundary `Argon2Params 128 1 16` both succeed. Update the three Argon2 rows of the env table in
`deployment.md` ("Must be positive" → the rule) and the hashing section.

Commit:

```text
feat(server): refuse to boot on Argon2 parameters the implementation rejects

The loader only checked positivity; crypton's C core requires m >= 8 and m >= 8*p and
turned a rejection into an ErrorCall on every signup. Encode the rule as argon2HardFloor
(with a 32-bit range check, since toOptions truncates), apply it in the loader and
shomei-admin, and run one trial derivation in Boot.main before the pool is acquired.

MasterPlan: docs/masterplans/8-trust-boundary-remediation-close-the-august-2026-security-and-performance-review.md
ExecPlan: docs/plans/56-bound-password-hashing-for-real-and-refuse-to-boot-on-unsafe-configuration.md
Intention: intention_01m10kwqt9eedbjvk91rn726mq
```

### Milestone M3 — configuration strictness

Scope: an unknown Dhall key, a misspelled WebAuthn policy, an unparseable signing algorithm, and an
empty origin list each refuse to boot; `SHOMEI_EMAIL_VERIFICATION_REQUIRED` exists.

*Unknown keys.* Replace `deriving anyclass (FromJSON)` on `FileConfig` with a manual instance (import
`Data.Aeson (Options (..), defaultOptions, genericParseJSON)`); absent keys stay optional because aeson
accepts an omitted `Maybe` field. A file annotated with the Dhall schema is refused earlier by Dhall
itself; this covers the unannotated files the loader also accepts. **Observe the silent acceptance
first** (Concrete Steps, step 3).

```haskell
instance FromJSON FileConfig where
  parseJSON = genericParseJSON defaultOptions {rejectUnknownFields = True}
```

*WebAuthn enums.* Replace `parseUserVerification`/`parseAttestation` with
`parseUserVerificationPolicy :: Text -> Text -> IO UserVerificationPolicy` and
`parseAttestationPolicy :: Text -> Text -> IO AttestationPolicy`, shaped exactly like `parseSameSite`
(`:1068-1072`: lower-case, strip, `ioError` naming the label and the accepted values). In `baseFromFile`
pre-parse them beside the other enums (`:308-312`) and pass the two `Maybe` results into `mergeWebAuthn`,
whose `userVerification`/`attestation` lines become `fromMaybe baseUv uvFile` / `fromMaybe baseAtt attFile`;
`uvEnv`/`attestationEnv` call the same parsers with env-var labels.

*Signing algorithm.* In `shomei-core/src/Shomei/Config.hs` change `configSigningAlgorithm` to
`ShomeiConfig -> Either Text SigningAlgorithm` (`= signingAlgorithmFromText cfg.signingKeyConfig.algorithm`)
and its comment to say a bad value is a boot error. In `Boot.buildEnv`, before `bootstrapKeys`:
`alg <- either (\why -> hPutStrLn stderr ("[shomei] FATAL: signingKeyConfig.algorithm: " <> Text.unpack why) >> exitFailure) pure (configSigningAlgorithm cfg)`.
In `shomei-servant/src/Shomei/Servant/Oidc.hs:79` render
`either (const []) (\a -> [signingAlgorithmToText a]) (configSigningAlgorithm cfg)` — unreachable after
boot, but total. Rewrite `shomei-jwt/test/Shomei/SigningKey/Sign/RsaCustomClaimSpec.hs:73-77` to assert
`Right RS256` and `Left` for `"nope"`.

*Empty origins.* In `overlayFromEnvBoth`, after `cfg <- overlayCoreFromEnv …` (`:440`); `WebAuthnConfig`
is read by destructuring, not dot syntax (see the note at `:891-894`):

```haskell
  let WebAuthnConfig {origins = originList} = cfg.webauthnConfig
  when (null originList) $
    ioError (userError "SHOMEI_WEBAUTHN_ORIGINS (Dhall field webauthnOrigins) must list at least one origin; an empty list would fail every passkey ceremony")
```

In `Ceremony.hs` make `originsOf :: WebAuthnConfig -> Maybe (NonEmpty WA.Origin)` with `NE.nonEmpty`, and
in both complete steps bind it *first* in the `Either` block:
`allowed <- maybe (Left (WebAuthnOtherError "no allowed WebAuthn origins are configured")) Right (originsOf cfg)`.
Add to `shomei-webauthn/test/Shomei/WebAuthn/CeremonySpec.hs` a case running `completeRegistrationCeremony`
with `defaultWebAuthnConfig {origins = []}` on a garbage credential, expecting exactly that `Left` — the
check precedes decoding and nothing crashes.

*Email verification.* In `overlayNotifierFromEnv` (`:750-765`) add
`evr <- boolEnv "SHOMEI_EMAIL_VERIFICATION_REQUIRED"` and
`emailVerificationRequired = fromMaybe base.emailVerificationRequired evr`; add the env-table row in
`deployment.md`. ConfigSpec gains inline cases, each writing its own temp Dhall file like `configPath`:
unknown key → `expectUserErrorNaming "invalid SHOMEI_CONFIG"`; `webauthnAttestation = "nope"` → naming
`webauthnAttestation`; `webauthnOrigins = ([] : List Text)` and `SHOMEI_WEBAUTHN_ORIGINS=","` → naming
`webauthnOrigins`; `SHOMEI_EMAIL_VERIFICATION_REQUIRED=true` → `cfg.notifierConfig.emailVerificationRequired @?= True`.

Commit:

```text
feat(config): refuse unknown Dhall keys, enum typos, and empty WebAuthn origins at boot

FileConfig rejects unknown fields; the Dhall path parses the WebAuthn policies as strictly
as the env path; configSigningAlgorithm returns Either and buildEnv refuses a bad value
(the loader already did); an empty origin list is a boot error and originsOf uses
NE.nonEmpty; SHOMEI_EMAIL_VERIFICATION_REQUIRED closes the MasterPlan 5 follow-up.

MasterPlan: docs/masterplans/8-trust-boundary-remediation-close-the-august-2026-security-and-performance-review.md
ExecPlan: docs/plans/56-bound-password-hashing-for-real-and-refuse-to-boot-on-unsafe-configuration.md
Intention: intention_01m10kwqt9eedbjvk91rn726mq
```

### Milestone M4 — an open Dhall schema that cannot drift from the loader

Scope: every loader key is an optional field of the schema, the example uses it, and a test fails when
the two disagree. Later plans (`docs/plans/53-…`, `57-…`, `58-…`) add their keys to this file. The rule
for every plan: **a loader key is added to `config/shomei-types.dhall` and to `docs/user/deployment.md`
in the same commit**; M4's test enforces the first half.

Rewrite `config/shomei-types.dhall` as record completion, keeping every existing comment. Each existing
field keeps its base type wrapped in `Optional` (`List Text` becomes `Optional (List Text)`; fields
already `Optional` stay as they are):

```dhall
-- Every field is optional; an absent field falls back to the built-in default, and any SHOMEI_*
-- variable overrides the file. Use record completion so omitted fields become None:
--     let Shomei = ./shomei-types.dhall in Shomei::{ databaseUrl = Some "host=… dbname=shomei" }
let Type =
      { issuer : Optional Text
      , databaseUrl : Optional Text
      , port : Optional Natural
      -- … every existing field, then the twenty new ones, e.g. …
      , signingAlgorithm : Optional Text         -- "ES256" | "RS256"
      , csrfAllowedOrigins : Optional (List Text)
      , sweepEnabled : Optional Bool
      }
let default = { issuer = None Text, databaseUrl = None Text, port = None Natural {- … one None per field … -} }
in { Type, default }
```

The twenty keys to add, from the diff of `FileConfig` against the file: `dbPoolSize`,
`dbPoolAcquisitionTimeoutMs`, `sweepEnabled`, `sweepIntervalSeconds`, `sweepBatchSize`,
`sweepDeadSessionGraceDays`, `sweepOneTimeTokenGraceDays`, `sweepCeremonyGraceMinutes`,
`loginAttemptRetentionDays`, `authEventRetentionDays`, `argon2MemoryKiB`, `argon2Iterations`,
`argon2Parallelism`, `hashingMaxConcurrency`, `signingAlgorithm`, `keyRefreshIntervalSeconds`,
`tokenTransport`, `cookieSecure`, `cookieSameSite`, `csrfAllowedOrigins`. Rewrite
`config/shomei.example.dhall` as `let Shomei = ./shomei-types.dhall in Shomei::{ … }` setting a curated
subset with `Some` (`databaseUrl`, `port`, `publicBaseUrl`, `webauthnRpId`, `webauthnOrigins`,
`notifierTransport`, `defaultRoles`, `oidcEnabled`), comments kept. `dhall-to-json` renders `None` as
`null`, which aeson reads as `Nothing`, so the loader is unchanged.

Add `deriving anyclass (ToJSON)` to `FileConfig` and, in `ConfigSpec.hs`, an inline case (add `aeson`,
`directory`, and `process` to `shomei-server-config-test`'s `build-depends`):

```haskell
-- | Rendering `Schema::{=}` through dhall-to-json yields an object whose keys are the schema's fields
-- (and type-checks default against Type); decoding `{}` into FileConfig and re-encoding yields the
-- loader's. The two sets must be equal.
dhallSchemaMatchesFileConfig :: Assertion
dhallSchemaMatchesFileConfig = do
  schema <- makeAbsolute "../config/shomei-types.dhall" -- cabal test runs in shomei-server/
  writeFile schemaProbePath ("(" <> schema <> ")::{=}")
  rendered <- readProcess "dhall-to-json" ["--file", schemaProbePath] ""
  dhallKeys <- either assertFailure (pure . KeyMap.keys) (eitherDecodeStrict' (TE.encodeUtf8 (Text.pack rendered)) :: Either String (KeyMap Value))
  blank <- either assertFailure pure (eitherDecodeStrict' "{}" :: Either String FileConfig)
  loaderKeys <- case toJSON blank of
    Object o -> pure (KeyMap.keys o)
    _ -> assertFailure "FileConfig did not encode as an object"
  Set.fromList dhallKeys @?= Set.fromList loaderKeys
```

In `deployment.md`'s Dhall section delete the "closed record" note, show the `Shomei::{ … }` form, and
drop the hand-maintained key enumeration (the thing that drifted) in favour of "the schema is the key list".

Commit:

```text
feat(config)!: widen the Dhall schema to optional fields and sync it with the loader

config/shomei-types.dhall becomes { Type, default } with every field Optional, adds the
twenty keys the loader accepted but the schema could not express, and the example uses
record completion. A ConfigSpec case renders Schema::{=} and asserts its keys equal
FileConfig's, so a loader key added without a schema key fails the suite.

BREAKING CHANGE: a config file annotated with the old closed type must switch to
`Shomei::{ field = Some value, … }`; unannotated files are unaffected.

MasterPlan: docs/masterplans/8-trust-boundary-remediation-close-the-august-2026-security-and-performance-review.md
ExecPlan: docs/plans/56-bound-password-hashing-for-real-and-refuse-to-boot-on-unsafe-configuration.md
Intention: intention_01m10kwqt9eedbjvk91rn726mq
```

### Milestone M5 — one credential per user, statement timeouts, a sweeper connection of its own

Scope: the persistence findings. This milestone adds a loader key and, per M4's rule, adds it to the
schema and to `deployment.md` in the same commit.

*Migration.* Run `just new-migration unique-password-credential-per-user`; it creates
`shomei-migrations/migrations/shomei/0029-unique-password-credential-per-user.sql` and appends it to
the manifest. Body:

```sql
SET search_path TO shomei, pg_catalog;

-- One password credential per user is the invariant every workflow assumes: signup creates
-- exactly one, and password reset and change run UPDATE … WHERE user_id = $1 expecting to
-- touch exactly one row. Stating it as a UNIQUE index also gives that UPDATE the index it
-- lacked. A second credential for one user can only have arrived out of band; the migration
-- refuses to apply until it is removed.
CREATE UNIQUE INDEX IF NOT EXISTS shomei_password_credentials_user_id_key
  ON shomei_password_credentials (user_id);
```

Operators with a populated database check first with `SELECT user_id, count(*) FROM
shomei.shomei_password_credentials GROUP BY user_id HAVING count(*) > 1;` (expected: no rows); the
build holds a `SHARE` lock on the table for its duration (REV-6 finding 4). Test in
`shomei-postgres/test/Main.hs`: `testCredentialUniquePerUser` seeds a user and one credential via
`execSql`, runs a second `INSERT` for the same `user_id` through `Pool.use`, asserts `Left` whose `show`
mentions `23505` or the index name, and checks
`scalarInt pool "SELECT count(*) FROM pg_indexes WHERE schemaname = 'shomei' AND indexname = 'shomei_password_credentials_user_id_key'" >>= (@?= 1)`.

*Statement timeouts.* Change `Pool/Postgres.hs` (`ms` is an `Int` rendered with `show`, never operator
text; migrations run on pg-migrate's own connection and are unaffected):

```haskell
-- | @statementTimeoutMs@ is applied to every pooled connection as PostgreSQL's @statement_timeout@
-- and @idle_in_transaction_session_timeout@, so a hung statement or a leaked transaction releases
-- its pool slot instead of holding it; 0 disables both.
acquirePool :: Int -> DiffTime -> Int -> Text -> IO Pool
acquirePool size acquisitionTimeout statementTimeoutMs connStr =
  Pool.acquire
    ( Config.settings
        [ Config.staticConnectionSettings (Settings.connectionString connStr),
          Config.size size,
          Config.acquisitionTimeout acquisitionTimeout,
          Config.initSession (Session.sql (sessionSetup (max 0 statementTimeoutMs)))
        ]
    )
  where
    sessionSetup ms = BC.pack ("SET statement_timeout = " <> show ms <> "; SET idle_in_transaction_session_timeout = " <> show ms)
```

Add `serverDbStatementTimeoutMs :: !Int` to `ServerSettings` with an exported
`defaultDbStatementTimeoutMs = 30000`, the `FileConfig` field `dbStatementTimeoutMs :: !(Maybe Int)`, env
`SHOMEI_DB_STATEMENT_TIMEOUT_MS` via `intEnv`, `requireNonNegative`, and the schema field
`dbStatementTimeoutMs : Optional Natural` (M4's test fails until it is there). Update the four
`acquirePool` call sites: `buildEnv` passes the setting and its log line becomes
`[shomei] db pool: size 10, acquisition timeout 10000ms, statement timeout 30000ms`; `Admin/Env.hs` and
both test harnesses pass `defaultDbStatementTimeoutMs` (imported from `Shomei.Server.Config`, which
`Admin/Env.hs` already imports). Test `testPoolStatementTimeoutIsApplied`: inside
`withShomeiMigratedDatabase`, `acquirePool 1 10 200 connStr`, then
`Pool.use pool (Session.sql "SELECT pg_sleep(1)")` asserts `Left` whose `show` contains `57014` or
`statement timeout`; then `Session.sql "BEGIN" >> liftIO (threadDelay 400_000) >> Session.sql "SELECT 1"`
asserts `Left` containing `25P03` (the idle-in-transaction guard; hasql-pool discards that connection
afterwards). Add the env-table row and a paragraph under "Sizing the connection pool".

*Sweeper.* In `Boot.installSweeper` acquire
`sweepPool <- acquirePool 1 (millisToDiffTime settings.serverDbPoolAcquisitionTimeoutMs) settings.serverDbStatementTimeoutMs settings.serverConnStr`,
pass it to `sweepOnce` instead of `env.envPool`, extend the log line with `, on its own connection`, and
return `Pool.release sweepPool` (`installSweeper :: ServerSettings -> Env -> IO (IO ())`) so `main`
releases it after `Pool.release env.envPool`. `shomei-admin sweep` keeps its own pool. Document in the
sweeper section that the connection counts one extra toward `max_connections` and is closed by the
idleness timeout between cycles.

Commit:

```text
feat(postgres): unique credential per user, statement timeouts, dedicated sweeper connection

Migration 0029 adds shomei_password_credentials_user_id_key, stating the one-credential
invariant and indexing UpdatePasswordHash. acquirePool applies statement_timeout and
idle_in_transaction_session_timeout from dbStatementTimeoutMs (default 30 s; schema and
deployment.md updated in this commit). The sweeper drains on a one-connection pool of its
own instead of a request slot.

MasterPlan: docs/masterplans/8-trust-boundary-remediation-close-the-august-2026-security-and-performance-review.md
ExecPlan: docs/plans/56-bound-password-hashing-for-real-and-refuse-to-boot-on-unsafe-configuration.md
Intention: intention_01m10kwqt9eedbjvk91rn726mq
```


## Concrete Steps

All commands run from `/Users/shinzui/Keikaku/bokuno/shomei` inside `nix develop`. Boot checks need the
dev database (`just create-database`) and a KEK: `export SHOMEI_KEY_ENCRYPTION_KEY=$(head -c 32 /dev/urandom | base64)`.
Let `PG=PG_CONNECTION_STRING="host=$PGHOST dbname=$PGDATABASE user=$(id -un)"` stand for that variable below.

Step 1 (M1, before editing). Record the false pass:

```bash
cabal test shomei-postgres --test-options='-p "hashing limiter"'
```

```text
  hashing limiter: peak concurrency never exceeds the limit (1):     OK (0.52s)
  hashing limiter: peak concurrency never exceeds the limit (2):     OK (0.31s)
  hashing limiter: the PasswordHasher interpreter acquires a permit: OK
  hashing limiter: the dummy verification path is bounded too:       OK (0.01s)
```

Add the new test, run it against the unmodified interpreter, and record the failure — it reads
`post-return forcing windows overlap: (…)` or `hash 3 was forced after the interpreter returned`. Apply
the M1 edits and re-run; expected `hashing limiter: the interpreter forces HashPassword inside its permit: OK (0.05s)`.
Mutation check: delete both `evaluate`s, confirm the test fails again, restore. Then
`cabal test shomei-postgres` (all green) and the load-test run per M1, numbers into Outcomes.

Step 2 (M2). `cabal build all --enable-tests && cabal test shomei-postgres shomei-server-config-test`, then:

```bash
$PG SHOMEI_ARGON2_PARALLELISM=16 SHOMEI_ARGON2_MEMORY_KIB=64 cabal run shomei-server
```

```text
shomei-server: user error (SHOMEI_ARGON2_* (Dhall fields argon2*) are rejected by the Argon2 implementation: memoryKiB must be at least 8 × parallelism and at least 8; got m=64 KiB for p=16 (needs 128))
```

Exit status 1 and no `[shomei] db pool` line (the pool was never acquired). Temporarily comment out the
loader check and repeat to see the trial fire — `[shomei] FATAL: the Argon2 implementation rejected the
configured parameters (m=64KiB,t=3,p=16): argon2: hash: internal error` — then restore it.

Step 3 (M3, before editing). Observe the silent acceptance:

```bash
printf '{ cookieSecue = False }\n' > /tmp/typo.dhall
SHOMEI_CONFIG=/tmp/typo.dhall $PG cabal run shomei-server
```

Today this prints `[shomei] listening on :8080` with cookies still `Secure`. After the M3 edits (aeson's
wording, from `Data/Aeson/Types/FromJSON.hs:1418-1419`):

```text
shomei: could not decode rendered Dhall config /tmp/typo.dhall: Error in $: parsing FileConfig failed, unknown fields: ["cookieSecue"]
shomei-server: user error (invalid SHOMEI_CONFIG: /tmp/typo.dhall)
```

Repeat with `{ webauthnAttestation = "nope" }` (expect `webauthnAttestation (config file) must be
none|direct, got nope`), `{ webauthnOrigins = ([] : List Text) }`, and `SHOMEI_WEBAUTHN_ORIGINS=","`
(expect `must list at least one origin`). Then `cabal test shomei-server-config-test shomei-webauthn shomei-jwt`.

Step 4 (M4). `dhall-to-json --file config/shomei.example.dhall` must print an object with every key,
`null` for the omitted ones (`--file config/shomei-types.dhall` itself fails: a record holding a type is
not JSON-renderable, which is expected). Then `cabal test shomei-server-config-test`; the case name stays
`Dhall file is loaded and env vars override it: OK`. Mutation check: delete one `Type` field and expect
`expected: fromList [...,"cookieSameSite",...] but got: fromList [...]`; restore.

Step 5 (M5). `just new-migration unique-password-credential-per-user`, fill the body,
`just migration-check`, then `cabal build all --enable-tests && cabal test all`. Boot check with
`$PG cabal run shomei-server`:

```text
[shomei] schema migrations applied: 29 migrations
[shomei] db pool: size 10, acquisition timeout 10000ms, statement timeout 30000ms
[shomei] hashing concurrency 2, argon2 m=65536KiB,t=3,p=1
[shomei] sweeper: every 3600s, audit retention disabled (retain forever), on its own connection
[shomei] listening on :8080
```

Finish: `nix fmt`, `cabal build all --enable-tests`, `cabal test all`; update this plan's living
sections, MasterPlan 8's three EP-6 Progress boxes and registry row, the CHANGELOG `Unreleased` sections
of shomei-core, shomei-postgres, shomei-webauthn, shomei-servant, shomei-server, and shomei-migrations;
then the ADR distillation pass.


## Validation and Acceptance

1. **The bound covers the work.** `hashing limiter: the interpreter forces HashPassword inside its
   permit` passes, and demonstrably failed before the fix and under the mutation that removes the
   `evaluate`s; the existing four limiter cases stay green.
2. **Bad Argon2 refuses to boot.** The Step 2 transcript plus ConfigSpec's new assertions. A deployment
   at the defaults boots as before, one derivation (~100 ms) slower.
3. **Bad configuration refuses to boot.** The Step 3 transcripts for an unknown key, an enum typo, and
   empty origins from file and environment; `RsaCustomClaimSpec` asserts `Left`; `CeremonySpec` proves
   an empty origin list yields `WebAuthnOtherError`, not a crash; `SHOMEI_EMAIL_VERIFICATION_REQUIRED=true`
   is visible in the loaded config.
4. **The schema cannot drift.** `dhall-to-json` renders the example; the ConfigSpec sync case passes and
   fails under the one-field mutation; `config/shomei.example.dhall` boots the server.
5. **Persistence.** `testCredentialUniquePerUser` and `testPoolStatementTimeoutIsApplied` pass; the Step 5
   transcript shows 29 migrations, the statement timeout, and the sweeper's own connection;
   `psql -c "\d shomei.shomei_password_credentials"` lists `shomei_password_credentials_user_id_key UNIQUE (user_id)`.
6. `nix fmt` clean; `cabal build all --enable-tests` and `cabal test all` green; every new key appears in
   `config/shomei-types.dhall` and `docs/user/deployment.md` in the commit adding it.


## Idempotence and Recovery

Every code edit is an ordinary, re-runnable change. M1 changes no stored format — hashes produced after
it are the same PHC strings — so rolling it back is safe. M2 and M3 only add refusals; a deployment they
refuse was already broken at runtime (`500`s, ignored keys, crashing ceremonies), and the recovery is the
message printed. M4 is the one breaking edit: an operator file annotated `: ./shomei-types.dhall` fails
Dhall type-checking until rewritten as `Shomei::{ … }` with `Some`; unannotated files and every
environment variable keep working, and the loader is unchanged, so dropping the annotation is a stopgap.
M5's migration is additive and guarded with `IF NOT EXISTS`; it fails, harmlessly and before changing
anything, if a user has two credentials — remove the duplicate and re-run `just migrate`. The statement
timeout can be disabled with `SHOMEI_DB_STATEMENT_TIMEOUT_MS=0` if a legitimate statement ever exceeds
it; the sweeper's extra connection goes away with `SHOMEI_SWEEP_ENABLED=false` plus an external
`shomei-admin sweep`. `just new-migration` refuses an existing slug, so re-running Step 5 is safe.


## Interfaces and Dependencies

No new Haskell dependencies; `shomei-server-config-test` gains `aeson`, `directory`, and `process` in
`build-depends` (all already in the build plan) and, like the loader, needs `dhall-to-json` (dhall-json
1.7.12 in the dev shell). Dependency facts verified in source via Mori: crypton 1.1.4
(`mori registry show kazu-yamamoto/crypton`) — `Crypto.KDF.Argon2.hash` returns `CryptoFailed` only for
salt and output length and calls `error` on a non-zero C result; `cbits/argon2/core.c` `validate_inputs`
enforces `m_cost ≥ 8`, `m_cost ≥ 8 × lanes`, `t_cost ≥ 1`, `lanes ≥ 1`; the FFI import is `unsafe`.
hasql-pool 1.4.2 (`mori registry show hasql/hasql`) — `Hasql.Pool.Config.initSession :: Session () -> Setting`
runs once per new connection. aeson (`mori registry show haskell/aeson`) — `rejectUnknownFields` fails
with `parsing <Type> failed, unknown fields: [...]`.

Must exist at the end:

- `Shomei.Account.Password.Hash.Postgres` (shomei-postgres) additionally exporting `Argon2Failure (..)`,
  `argon2HardFloor :: Argon2Params -> Maybe Text`, and
  `trialArgon2Derivation :: Argon2Params -> IO (Either Argon2Failure ())`; `hashPasswordArgon2id` returns
  a fully forced hash and throws `Argon2Failure`.
- `Shomei.Persistence.Pool.Postgres.acquirePool :: Int -> DiffTime -> Int -> Text -> IO Pool`.
- `Shomei.Config.configSigningAlgorithm :: ShomeiConfig -> Either Text SigningAlgorithm`.
- `Shomei.Server.Config`: `FileConfig` with a strict `FromJSON` and a `ToJSON`, field `dbStatementTimeoutMs`;
  `ServerSettings.serverDbStatementTimeoutMs`; exported `defaultDbStatementTimeoutMs :: Int`; env vars
  `SHOMEI_EMAIL_VERIFICATION_REQUIRED` and `SHOMEI_DB_STATEMENT_TIMEOUT_MS`; strict
  `parseUserVerificationPolicy`, `parseAttestationPolicy`.
- `Shomei.Server.Boot.installSweeper :: ServerSettings -> Env -> IO (IO ())`; `main` runs the Argon2 trial
  before `buildEnv`; `buildEnv` refuses a bad signing algorithm.
- `Shomei.WebAuthn.Ceremony.originsOf :: WebAuthnConfig -> Maybe (NonEmpty WA.Origin)`.
- `config/shomei-types.dhall` evaluating to `{ Type, default }` with 70 optional fields (69 today plus
  `dbStatementTimeoutMs`); `config/shomei.example.dhall` using `Shomei::{ … }`.
- Migration `0029-unique-password-credential-per-user.sql`, listed in the manifest.

Cross-plan notes (MasterPlan 8 Integration Points 5 and 7): `docs/plans/55-…`'s
`CompletePasswordReset`/`CompletePasswordChange` take a `PasswordHash` computed and forced by this plan's
interpreter before the unit of work begins — nothing here runs inside a transaction. `docs/plans/53-…`
(`allowedClockSkewSeconds`), `57-…` (secret relocation), and `58-…` (`trustedProxies` and the per-IP
knobs) each add their keys to `Type` and `default` in `config/shomei-types.dhall` and to `deployment.md`
in the same commit; M4's ConfigSpec case turns forgetting the schema half into a failing test. If one
lands before M4, it adds its key to the closed record and M4 wraps it in `Optional` like the rest.
