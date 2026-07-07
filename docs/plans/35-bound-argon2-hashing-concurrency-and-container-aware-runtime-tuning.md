---
id: 35
slug: bound-argon2-hashing-concurrency-and-container-aware-runtime-tuning
title: "Bound Argon2 Hashing Concurrency and Container-Aware Runtime Tuning"
kind: exec-plan
created_at: 2026-07-07T17:22:22Z
master_plan: "docs/masterplans/6-operational-and-performance-hardening.md"
---

# Bound Argon2 Hashing Concurrency and Container-Aware Runtime Tuning

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.

This is **EP-3** of MasterPlan 6
(`docs/masterplans/6-operational-and-performance-hardening.md`, "Operational and Performance
Hardening"). It puts a configurable ceiling on how many Argon2id password hashes run at once
(bounding both the transient memory spike and the garbage-collector stalls the hashing causes
today), makes the Argon2 cost parameters operator-configurable without breaking existing
stored hashes, ships container-aware GHC runtime-system defaults in the deployment artifacts,
and adds a reproducible load test that demonstrates — before and after — what concurrent
logins do to the latency of the authenticated hot path. The code fix and the runtime tuning
ship together deliberately: the MasterPlan's acceptance (bounded hot-path latency under
concurrent logins) can only be evaluated with both in place.


## Purpose / Big Picture

Shōmei hashes passwords with Argon2id at healthy parameters (64 MiB memory, 3 iterations,
parallelism 1 — these are *good* and this plan keeps them as defaults). The problem is how
the hashing is *scheduled*. The Argon2 implementation is reached through crypton's
`foreign import ccall unsafe` (an "unsafe" foreign call runs on the calling capability with
no way for the runtime to interrupt it), so for the ~50–150 ms of each hash that capability
cannot reach a garbage-collection safepoint — and GHC's default (moving) collections are
stop-the-world, so **every** thread in the process can stall behind one password hash.
Each hash also transiently allocates 64 MiB: ten concurrent logins spike ~640 MB. Nothing
bounds that concurrency today. On top of this, the deployment sets no RTS options at all:
the executables are built with `-with-rtsopts=-N`, and `-N` detects *host* cores, so a
container with a 2-CPU quota on a 32-core node runs 32 capabilities and thrashes in GC.

After this plan, an operator can observe: (1) with 20 concurrent login loops hammering the
server, the p99 latency of a JWT-verified `GET /auth/me` stays within a small factor of its
idle latency, where before it degraded by an order of magnitude — measured by a committed,
re-runnable script whose before/after numbers are recorded in this plan; (2) at most
`SHOMEI_HASHING_MAX_CONCURRENCY` (default 2) hashes run at once, proven by a test that runs
16 concurrent hashes through the real interpreter and asserts the observed peak concurrency;
(3) the container entrypoint computes the CPU quota from the cgroup filesystem and starts the
server with `-N<quota> -A64m --nonmoving-gc`, logged at startup; (4) Argon2 memory/iterations/
parallelism are configurable, new hashes record their parameters in the stored hash string
(PHC-style), old hashes keep verifying forever, and a below-floor configuration prints a loud
warning at boot.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [ ] M1: `Argon2Params` record + `defaultArgon2Params` in
      `shomei-postgres/src/Shomei/Crypto.hs`; PHC-style hash encoding for new hashes;
      verification parses PHC and legacy 3-part formats.
- [ ] M1: round-trip and legacy-compatibility tests in the `shomei-postgres` suite (hash with
      new params, verify; verify a fixture legacy-format hash; verify old hashes after a
      params change).
- [ ] M1: params configurable via `ServerSettings` / Dhall / `SHOMEI_ARGON2_*` env; boot floor
      warning for weak params.
- [ ] M2: `HashingLimiter` (STM permit counter with peak tracking) in `Shomei.Crypto`;
      `runPasswordHasherCrypto` takes limiter + params; `VerifyPassword` becomes IO with
      `evaluate` inside the permit bracket.
- [ ] M2: `Env` gains the limiter; all `Env` construction sites updated; concurrency test
      (16 parallel hashes, peak ≤ limit) green.
- [ ] M3: `deploy/entrypoint.sh` computes CPU count from cgroup v2/v1 and exports `GHCRTS`;
      Dockerfile comment block updated; deployment docs updated with the reasoning and the
      cgroup caveat (verified or hedged — see M3).
- [ ] M4: `scripts/argon2-load-test.sh` committed; baseline (pre-change) numbers captured on a
      throwaway branch/stash; post-change numbers captured; relative acceptance evaluated and
      recorded in Outcomes.
- [ ] `nix fmt` clean; `cabal build all` / `cabal test all` green; MasterPlan 6 Progress and
      registry updated.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

(None yet.)


## Decision Log

Record every decision made while working on the plan.

- Decision: Keep Argon2id with memory 64 MiB, iterations 3, parallelism 1 as the **defaults**;
  this plan changes scheduling and configurability, not strength.
  Rationale: The July 2026 performance review rated the parameters good (at or above OWASP's
  recommended Argon2id configurations). Weakening them to "fix" latency would trade a
  scheduling bug for a security regression.
  Date: 2026-07-07

- Decision: Bound concurrency with a **hand-rolled STM permit counter** (`TVar Int` permits +
  `TVar Int` peak-in-use), not `Control.Concurrent.QSemN`.
  Rationale: Functionally identical for this use (acquire one permit, blocking; release in a
  bracket), but the TVar version lets the test suite read the *observed peak concurrency*
  directly, turning the acceptance ("never more than N at once") into a deterministic
  assertion instead of a timing heuristic. No new dependency (`stm` is already in the build).
  Date: 2026-07-07

- Decision: Default `SHOMEI_HASHING_MAX_CONCURRENCY` = **2**.
  Rationale: Two concurrent hashes bound the transient allocation at ~128 MiB and cap the
  number of capabilities that can be pinned in unsafe FFI simultaneously, while still
  sustaining ~13–40 logins/second at 50–150 ms per hash — far above any single-instance
  Shōmei deployment's login rate. Operators with beefier CPU/memory budgets raise it; the
  review suggested 2–4 and we pick the conservative end because the failure mode of
  too-small (slightly queued logins) is benign and the failure mode of too-large (global GC
  stalls, memory spikes) is exactly the bug this plan exists to fix.
  Date: 2026-07-07

- Decision: Both `HashPassword` **and** `VerifyPassword` acquire a permit, and `VerifyPassword`
  changes from a pure thunk to an IO action that forces the comparison with
  `Control.Exception.evaluate` *inside* the permit bracket.
  Rationale: Verification re-derives the full Argon2 hash — identical cost to hashing — and
  today it is interpreted as `pure (verifyPasswordArgon2id pw hash)`
  (`shomei-postgres/src/Shomei/Crypto.hs` line ~86), a lazy thunk forced later on whatever
  handler thread touches the `Bool`, i.e. at an unpredictable point *outside* any bound we
  install and possibly during response assembly. Forcing inside the bracket makes the permit
  actually cover the work.
  Date: 2026-07-07

- Decision: Make parameters changeable by storing them **in the hash string** (PHC-style
  `$argon2id$v=19$m=65536,t=3,p=1$<b64 salt>$<b64 digest>`) for new hashes, while verification
  also accepts the legacy `argon2id$<b64 salt>$<b64 digest>` format using the historical
  constants.
  Rationale: Today `verifyPasswordArgon2id` re-derives with a *compiled-in constant*
  (`argonOptions`), so simply making the constant configurable would break every existing
  credential the moment an operator changed a value — a catastrophic footgun. Parameters
  embedded per-hash (the industry-standard PHC string format) make verification
  self-describing: old hashes verify with old params forever, new hashes use the configured
  params, and rehash-on-login upgrades can be a future plan. The legacy format is pinned to
  the current constants (64 MiB / t=3 / p=1 / v13), which are the only values ever shipped.
  Date: 2026-07-07

- Decision: Enforce a **warning floor**, not a hard floor: memory < 19456 KiB (19 MiB) or
  iterations < 2 or parallelism < 1 prints a prominent boot warning but does not refuse to
  start.
  Rationale: 19 MiB / t=2 tracks the weakest OWASP-endorsed Argon2id configuration. Refusing
  to boot would break test rigs and resource-starved dev environments that legitimately want
  cheap hashing; a loud warning ("configured Argon2 parameters are below the recommended
  floor; passwords hashed with them are weaker") makes the trade-off explicit without taking
  the decision away from the operator.
  Date: 2026-07-07

- Decision: Set RTS defaults **in the container entrypoint via the `GHCRTS` environment
  variable** (computed from the cgroup), not by changing `-with-rtsopts` in the `.cabal`
  files.
  Rationale: The right `-N` is a property of the *deployment* (the cgroup quota), unknowable
  at compile time. `GHCRTS` is read by every executable built with `-rtsopts` (all Shōmei
  executables are), survives `exec`, and lets bare-metal users keep today's behavior
  untouched. The entrypoint is already the deployment's init logic
  (`deploy/entrypoint.sh` runs migrations and key bootstrap before `exec shomei-server`).
  Date: 2026-07-07

- Decision: State the cgroup claim carefully and verify it during M3: as of GHC 9.12, `-N`
  sizes capabilities from the processor count / CPU *affinity mask* (`sched_getaffinity` on
  Linux), which reflects cpuset pinning but **not** CFS bandwidth quotas — and Docker
  `--cpus` / Kubernetes CPU *limits* are CFS quotas. Therefore a quota-limited container sees
  all host cores. The plan verifies this empirically (M3 step) rather than trusting memory of
  the GHC ticket landscape; if a 9.12.4 behavior change is discovered, record it in Surprises
  and simplify the entrypoint accordingly.
  Rationale: The whole milestone rests on this claim; PLANS.md requires embedded knowledge to
  be verified, and an empirical check inside a `--cpus`-limited container is cheap.
  Date: 2026-07-07

- Decision: The load test is a **shell script driving the real server with `curl`**
  (`scripts/argon2-load-test.sh`), not a Haskell bench harness, and acceptance is **relative**
  (degradation factor before vs. after), never absolute milliseconds.
  Rationale: `curl` + `awk` exist in the dev shell and CI; a script against the real warp
  process measures the actual phenomenon (GC stalls crossing request boundaries), which an
  in-process criterion bench cannot see. Absolute numbers vary wildly across machines;
  the *ratio* of loaded to idle hot-path latency is machine-portable enough to be an
  acceptance criterion.
  Date: 2026-07-07


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

(To be filled during and after implementation.)


## Context and Orientation

The repository at `/Users/shinzui/Keikaku/bokuno/shomei` is a multi-package Haskell workspace
(GHC 9.12.4, GHC2024); build with `cabal build all`, test with `cabal test all`, format with
`nix fmt`, all inside `nix develop`; the dev database comes from `just create-database`.

**Where hashing lives.** `shomei-postgres/src/Shomei/Crypto.hs` implements Argon2id over the
`crypton` library and interprets the `PasswordHasher` port
(`shomei-core/src/Shomei/Effect/PasswordHasher.hs`, a two-operation GADT: `HashPassword`,
`VerifyPassword`). The current interpreter (lines ~83–86):

```haskell
runPasswordHasherCrypto :: (IOE :> es) => Eff (PasswordHasher : es) a -> Eff es a
runPasswordHasherCrypto = interpret_ \case
  HashPassword (PlainPassword pw) -> liftIO (hashPasswordArgon2id pw)
  VerifyPassword (PlainPassword pw) hash -> pure (verifyPasswordArgon2id pw hash)
```

Note `VerifyPassword` is a *pure thunk* — no IO, no bound, forced later wherever the Bool is
consumed. The parameters are the module constant `argonOptions` (lines ~35–43: Argon2id,
`memory = 64 * 1024` KiB, `iterations = 3`, `parallelism = 1`, Version13), and the stored
format is `"argon2id$<b64 salt>$<b64 digest>"` produced by `hashPasswordArgon2id` and parsed
by `verifyPasswordArgon2id`, which **re-derives with the constant options** — the reason
params are not trivially configurable today.

**Why one hash can stall everything.** crypton calls the C implementation via
`foreign import ccall unsafe "crypton_argon2_hash"` (crypton source,
`Crypto/KDF/Argon2.hs` line 157 — verified in the local dependency checkout). An `unsafe`
foreign call cannot be preempted: the Haskell thread occupies its capability until C returns
(~50–150 ms here). GHC's default collector is stop-the-world: a collection must sync *every*
capability, so one in-flight hash delays any GC — and therefore every other request — by up
to the whole hash duration. `-N` too high multiplies GC sync cost; concurrent hashes multiply
both the stall probability and the 64 MiB-per-hash transient footprint.

**Where the interpreter is installed.** `Shomei.Server.App.runAppIO`
(`shomei-server/src/Shomei/Server/App.hs`, line ~132) composes
`runPasswordHasherCrypto` into the server effect stack; the environment record `Env` (same
module) currently carries pool/config/key/jwks/http-manager. `Env` is constructed in
`Shomei.Server.Boot.buildEnv` and *literally* (record syntax) in several test/example
harnesses — find them all with `grep -rn "Env {envPool" --include=*.hs .` (currently:
`shomei-server/test/Shomei/Server/E2ESpec.hs`, `shomei-server/test/Admin/Main.hs`,
`examples/embedded-servant-app/test/Main.hs`, `examples/microservice-auth-stack/test/Main.hs`;
plus `buildEnv`). Adding a field to `Env` requires touching each.

**Deployment artifacts.** `deploy/entrypoint.sh` (copied into the image by the root
`Dockerfile`) runs `shomei-admin migrate`, ensures an active signing key, then
`exec shomei-server` — no RTS flags anywhere. All executables are built with
`ghc-options: -threaded -rtsopts -with-rtsopts=-N` (see `shomei-server/shomei-server.cabal`),
so RTS options *are* accepted at runtime, via `+RTS … -RTS` or the `GHCRTS` env var. The
reproducible image is built by `nix build .#dockerImage` (see `flake.module.nix`) and also
uses the entrypoint. There is also a dev `process-compose.yaml` at the repo root that runs
PostgreSQL + the server for local work — the load test targets a locally-run server, not the
container.

**Config layering** (`shomei-server/src/Shomei/Server/Config.hs`): defaults → optional Dhall
file (`SHOMEI_CONFIG`, rendered by `dhall-to-json` into the flat all-`Maybe` `FileConfig`) →
`SHOMEI_*` env vars. This plan appends fields to `ServerSettings`/`FileConfig` (append-only,
shared with plans 33/34 per MasterPlan 6's Integration Points).

**Terms.** *Capability*: one OS-thread-backed execution slot in GHC's runtime; `-N` sets the
count. *Safepoint*: a program point where a thread can be stopped for GC; unsafe FFI has
none. *`--nonmoving-gc`*: GHC's concurrent old-generation collector — old-gen collection runs
alongside mutators (young-generation collections remain brief stop-the-world pauses), which
shrinks exactly the long global pauses that pile up behind a pinned capability. *PHC string
format*: the `$argon2id$v=19$m=…,t=…,p=…$salt$hash` convention for self-describing password
hashes. *cgroup v2 `cpu.max`*: the file `/sys/fs/cgroup/cpu.max` containing `<quota> <period>`
(µs), or `max <period>` when unlimited; effective CPUs = ceil(quota / period).


## Plan of Work

### Milestone M1 — self-describing hashes and configurable Argon2 parameters

Scope: the PHC format, the params record, config plumbing, and the floor warning — with the
concurrency bound still absent. At the end, new hashes carry their parameters, every old hash
still verifies, and `SHOMEI_ARGON2_MEMORY_KIB=32768` observably changes newly-produced hash
strings.

In `shomei-postgres/src/Shomei/Crypto.hs`: introduce

```haskell
data Argon2Params = Argon2Params
  { memoryKiB :: !Int,      -- default 65536 (64 MiB)
    iterations :: !Int,     -- default 3
    parallelism :: !Int     -- default 1
  }

defaultArgon2Params :: Argon2Params
```

Rename the constant `argonOptions` to `legacyArgonOptions` (unchanged values — it now
documents the parameters implied by the legacy format) and add `toOptions :: Argon2Params ->
Argon2.Options` (always Argon2id, Version13). Change `hashPasswordArgon2id :: Argon2Params ->
Text -> IO PasswordHash` to emit
`"$argon2id$v=19$m=" <> m <> ",t=" <> t <> ",p=" <> p <> "$" <> b64 salt <> "$" <> b64 digest`.
Change `verifyPasswordArgon2id :: Text -> PasswordHash -> Bool` to dispatch on shape:
`Text.splitOn "$"` yielding `["", "argon2id", "v=19", "m=…,t=…,p=…", salt, digest]` → parse
the params and re-derive with them; the legacy `["argon2id", salt, digest]` → re-derive with
`legacyArgonOptions`; anything else → `False` (as today). Keep `constEq` for the comparison.
Parsing failures in a PHC-shaped string yield `False`, never a crash.

Add `argon2WarningFloor :: Argon2Params -> Maybe Text` (the OWASP-floor check from the
Decision Log) and call it from `Shomei.Server.Boot.main` right after config load, printing
any warning to stderr.

Config plumbing: `ServerSettings` gains `serverArgon2 :: !Argon2Params` (and M2's
`serverHashingMaxConcurrency :: !Int`); `FileConfig` gains optional `argon2MemoryKiB`,
`argon2Iterations`, `argon2Parallelism`; env overrides `SHOMEI_ARGON2_MEMORY_KIB`,
`SHOMEI_ARGON2_ITERATIONS`, `SHOMEI_ARGON2_PARALLELISM` via the existing `intEnvMaybe`.
Non-positive values are rejected at load with `ioError` (crypton itself would reject them
later with a `CryptoFailed`, but a boot-time message naming the variable is kinder).

Tests (extend the `shomei-postgres` suite, which already has direct `Shomei.Crypto`
coverage — locate with `grep -rn "hashPasswordArgon2id\|verifyPasswordArgon2id"
shomei-postgres/test`): (a) hash with `defaultArgon2Params`, string starts with
`"$argon2id$v=19$m=65536,t=3,p=1$"`, verifies true, wrong password false; (b) a **fixture**
legacy-format hash (generate one with the *current* code before editing, hard-code hash and
password into the test) verifies true after the change; (c) hash with
`Argon2Params 32768 2 1`, verify true — then verify the (a) and (b) hashes again, proving
mixed-params coexistence; (d) malformed PHC strings (`m=notanumber`) verify false.

### Milestone M2 — the hashing concurrency limiter

Scope: the permit counter, the interpreter change, `Env` threading, and the peak-concurrency
test. At the end, at most N hash/verify derivations run simultaneously no matter the request
concurrency.

In `Shomei.Crypto`, add:

```haskell
-- | A bounded-permit gate for Argon2 work: 'permits' counts free slots, 'peakInUse' records
-- the high-water mark of simultaneous holders (read by tests and future metrics).
data HashingLimiter = HashingLimiter
  { permits :: !(TVar Int),
    peakInUse :: !(TVar Int),
    limit :: !Int
  }

newHashingLimiter :: Int -> IO HashingLimiter

withHashingPermit :: HashingLimiter -> IO a -> IO a
-- bracket acquire/release; acquire = atomically (wait permits > 0, decrement, bump peak);
-- release = atomically (increment). Exception-safe via Control.Exception.bracket_.
```

Change the interpreter to

```haskell
runPasswordHasherCrypto ::
  (IOE :> es) => HashingLimiter -> Argon2Params -> Eff (PasswordHasher : es) a -> Eff es a
runPasswordHasherCrypto limiter params = interpret_ \case
  HashPassword (PlainPassword pw) ->
    liftIO (withHashingPermit limiter (hashPasswordArgon2id params pw))
  VerifyPassword (PlainPassword pw) hash ->
    liftIO (withHashingPermit limiter (evaluate (verifyPasswordArgon2id pw hash)))
```

`evaluate` (from `Control.Exception`) forces the verification to weak head normal form — a
`Bool`, so fully — *inside* the permit, fixing the escaping-thunk problem. Add fields
`envHashingLimiter :: !HashingLimiter` and `envArgon2Params :: !Argon2Params` to
`Shomei.Server.App.Env`, pass them at line ~132 of `runAppIO`, create the limiter in
`Boot.buildEnv` from `serverHashingMaxConcurrency` (env `SHOMEI_HASHING_MAX_CONCURRENCY`,
Dhall `hashingMaxConcurrency`, default 2, positive-checked), and update every literal `Env`
construction found by the grep in "Context and Orientation" (tests/examples use
`defaultArgon2Params` and a fresh `newHashingLimiter 2`). The boot log line gains
`hashing concurrency <n>`.

Test (in `shomei-postgres`'s suite, no database needed): build a limiter of 2, run 16
`Async`-style concurrent `withHashingPermit`-wrapped real hashes (use small params —
`Argon2Params 8192 1 1` — so the test is fast; the *limiter* is what is under test), wait for
all, then assert `readTVarIO peakInUse == 2` and that all 16 results verify. Repeat with
limit 1 asserting peak 1. Use `mapConcurrently` from `async` if present in the build plan,
else `forkIO` + `MVar` join (check `grep -rn "async" shomei-postgres/*.cabal`; do not add a
dependency for a test joinable with `MVar`s).

### Milestone M3 — container-aware RTS defaults

Scope: entrypoint logic, Dockerfile note, docs, and the empirical cgroup verification. At the
end, the container starts the server with an `-N` matching its CPU quota and the flags below,
and the deployment docs teach why.

Rewrite the tail of `deploy/entrypoint.sh` (POSIX sh; the image is `debian:stable-slim`):

```sh
# Container-aware GHC RTS defaults (EP-3 of the operational-hardening MasterPlan).
# GHC's -N sizes capabilities from the CPU affinity mask, which does NOT reflect
# cgroup CFS quotas (docker --cpus / k8s CPU limits) — verified against GHC 9.12.4.
# Compute the quota ourselves; fall back to nproc when unlimited.
cpus=""
if [ -f /sys/fs/cgroup/cpu.max ]; then                     # cgroup v2
  read -r quota period < /sys/fs/cgroup/cpu.max
  if [ "$quota" != "max" ]; then
    cpus=$(( (quota + period - 1) / period ))
  fi
elif [ -f /sys/fs/cgroup/cpu/cpu.cfs_quota_us ]; then      # cgroup v1
  quota=$(cat /sys/fs/cgroup/cpu/cpu.cfs_quota_us)
  period=$(cat /sys/fs/cgroup/cpu/cpu.cfs_period_us)
  if [ "$quota" -gt 0 ]; then
    cpus=$(( (quota + period - 1) / period ))
  fi
fi
[ -n "$cpus" ] || cpus=$(nproc)
[ "$cpus" -ge 1 ] || cpus=1

: "${GHCRTS:=-N$cpus -A64m --nonmoving-gc}"
export GHCRTS
echo "[entrypoint] starting shomei-server (GHCRTS=$GHCRTS)"
exec shomei-server
```

An operator-supplied `GHCRTS` wins (the `:=` default). The flag choices, restated in the
deployment docs (`docs/user/` — the deployment page; find it with `grep -rln "entrypoint"
docs/user docs`): `-N$cpus` sizes capabilities to the quota (stops the 32-capabilities-on-a-
2-CPU-limit GC thrash); `-A64m` enlarges the per-capability nursery so young-gen collections
are fewer (each one is a stop-the-world sync that can queue behind a pinned hash — fewer
syncs, fewer stall opportunities; cost: ~64 MiB × N baseline memory, acceptable next to the
Argon2 budget); `--nonmoving-gc` makes *old*-generation collection concurrent so the long
pauses — the ones that made hash-pinning visible at p99 — largely disappear. Also add the
same guidance as a comment block in the root `Dockerfile` (which is the non-reproducible
secondary path) and note that bare-metal/`cabal run` deployments keep plain `-N` unless the
operator sets `GHCRTS`.

**Verification step (do this, record output in Surprises):** on a machine with Docker and
> 2 cores, run a quota-limited container and print what GHC believes:

```bash
docker run --rm --cpus=2 haskell:9.12-slim ghc -e \
  'GHC.Conc.getNumProcessors >>= print'
```

If it prints the host core count, the claim holds as written. If it prints 2, GHC has grown
quota awareness — record the evidence, weaken the doc wording, and keep the entrypoint (it is
then merely redundant, not wrong). Then verify the entrypoint arithmetic in the same
container: `docker run --rm --cpus=2 debian:stable-slim sh -c 'cat /sys/fs/cgroup/cpu.max'`
should print `200000 100000` → cpus=2.

### Milestone M4 — the load test and the before/after measurement

Scope: a committed script and two recorded runs. The script `scripts/argon2-load-test.sh`
(new; make it executable) drives a locally-running server:

1. Signup a probe user and a set of 20 load users via `POST /auth/signup` (unique emails per
   run; the endpoint returns tokens so no email verification blocks it in the default dev
   config).
2. Log the probe user in once; keep its access token.
3. **Idle phase:** 200 sequential `GET /auth/me` requests with the bearer token, recording
   `curl -w '%{time_total}\n' -o /dev/null -s`; compute p50/p95/p99 with `sort -n | awk`.
4. **Load phase:** start 20 background `while` loops each doing `POST /auth/login` for its
   load user back-to-back for 60 seconds (every login = one Argon2 verification), then run
   the same 200-probe measurement concurrently; also record login throughput (count of 200
   responses across loops) and peak RSS of the server process (`ps -o rss= -p $SERVER_PID`
   sampled each second).
5. Print a summary block: idle p50/p95/p99, loaded p50/p95/p99, degradation factors
   (loaded/idle per percentile), logins/second, peak RSS.

Procedure: run it **twice** — once on the pre-plan commit (stash or a scratch worktree of
`master` before M1/M2 landed), once after — with the same machine, same
`SHOMEI_HASHING_MAX_CONCURRENCY=2`-capable build (the baseline build ignores the variable),
and for the "after" run also `GHCRTS="-N4 -A64m --nonmoving-gc"` to include M3's tuning.
Paste both summaries into Outcomes.

Acceptance (relative, per the Decision Log): the **p99 degradation factor** (loaded p99 ÷
idle p99) after must be at most **half** the before factor, and login throughput after must
be at least **80%** of before (queueing two-at-a-time must not collapse throughput — it
should barely change it, since the CPU work is identical). Peak RSS under load must be lower
after; report the numbers. If the before build is too noisy to show a stable factor on your
machine, increase the load loops to 40 and the probe count to 500 and note it.


## Concrete Steps

All from `/Users/shinzui/Keikaku/bokuno/shomei` in `nix develop`; dev database via
`just create-database`.

```bash
# M1
cabal build shomei-postgres && cabal test shomei-postgres
```

Expected new-test excerpt:

```text
  argon2 parameters
    new hashes are PHC-formatted and verify:          OK
    legacy-format fixture still verifies:             OK
    params change leaves old hashes verifiable:       OK
    malformed PHC strings verify False:               OK
```

```bash
# M2
cabal build all && cabal test all
```

Expected: everything green, including

```text
  hashing limiter
    peak concurrency never exceeds the limit (2): OK
    peak concurrency never exceeds the limit (1): OK
```

Boot check:

```bash
PG_CONNECTION_STRING="host=$PGHOST dbname=$PGDATABASE user=$(id -un)" \
SHOMEI_HASHING_MAX_CONCURRENCY=3 SHOMEI_ARGON2_MEMORY_KIB=8192 cabal run shomei-server
```

Expected stderr includes the floor warning (8 MiB < 19 MiB) and the concurrency:

```text
[shomei] WARNING: configured Argon2 parameters are below the recommended floor (m=8192KiB,t=3,p=1); passwords hashed with them are weaker
[shomei] hashing concurrency 3
[shomei] listening on :8080
```

```bash
# M3 verification (requires Docker, multi-core host)
docker run --rm --cpus=2 debian:stable-slim sh -c 'cat /sys/fs/cgroup/cpu.max'
```

Expected: `200000 100000`. Record the GHC probe result per M3.

```bash
# M4
./scripts/argon2-load-test.sh http://localhost:8080
```

Expected summary shape (numbers illustrative):

```text
idle    p50=2.1ms  p95=3.0ms  p99=4.2ms
loaded  p50=3.0ms  p95=6.1ms  p99=9.8ms
degradation p50=1.4x p95=2.0x p99=2.3x   logins/s=14.2   peak_rss=412MB
```

Finish: `nix fmt`, `cabal build all`, `cabal test all`, update living sections and
MasterPlan 6.


## Validation and Acceptance

1. **Compatibility is inviolable:** the legacy-fixture test proves a password hashed by the
   pre-plan code verifies after every change in this plan. If that test ever fails, stop and
   fix before anything else — a compatibility break here locks users out.
2. **Bounded concurrency is proven, not assumed:** the peak-in-use assertions (limit 1 and 2)
   pass under 16-way parallelism.
3. **Config observably works:** the boot transcript above shows the floor warning and the
   configured concurrency; hashing a new password with `SHOMEI_ARGON2_MEMORY_KIB=32768`
   (signup a user, then `psql -c "SELECT password_hash FROM shomei.shomei_password_credentials
   ORDER BY created_at DESC LIMIT 1"`) shows `m=32768` inside the stored string.
4. **The load test tells the story:** before/after summaries recorded in Outcomes satisfy the
   relative thresholds (p99 degradation factor halved; throughput ≥ 80%; lower peak RSS).
5. **The container does the right thing:** `docker run` of the built image on a
   `--cpus=2` host logs `GHCRTS=-N2 -A64m --nonmoving-gc` from the entrypoint.
6. `cabal build all` and `cabal test all` green; `nix fmt` clean.


## Idempotence and Recovery

All code steps are ordinary edits, safe to re-run. The stored-hash format change is
**forward-only but non-destructive**: hashes written by the new code are unreadable by the old
code, so if you must roll the binary back after new signups occurred, those users would need a
password reset — therefore land M1 together with its compatibility tests in one commit, and
note in the commit message that rollback across it affects only hashes created in between.
There is no migration and no schema change. The entrypoint change is inert outside containers
and overridable via a caller-supplied `GHCRTS`. The load-test script only creates throwaway
users in the dev database (`just create-database` re-creates a clean one at will) and may be
re-run freely; it must never be pointed at a production database (it says so in its header).


## Interfaces and Dependencies

No new Haskell dependencies (`stm`, `crypton`, `base`'s `Control.Exception` and `GHC.Conc`
are all in the build; verify `stm` is in `shomei-postgres`'s `build-depends` and add it there
if it was only in `shomei-server` — record in Surprises if so).

Must exist at the end:

- `Shomei.Crypto` (in `shomei-postgres`) exporting `Argon2Params (..)`,
  `defaultArgon2Params :: Argon2Params`, `HashingLimiter`, `newHashingLimiter :: Int -> IO
  HashingLimiter`, `withHashingPermit :: HashingLimiter -> IO a -> IO a`,
  `hashPasswordArgon2id :: Argon2Params -> Text -> IO PasswordHash`,
  `verifyPasswordArgon2id :: Text -> PasswordHash -> Bool` (PHC + legacy formats), and
  `runPasswordHasherCrypto :: (IOE :> es) => HashingLimiter -> Argon2Params ->
  Eff (PasswordHasher : es) a -> Eff es a`.
- `Shomei.Server.App.Env` with `envHashingLimiter` / `envArgon2Params`; `runAppIO` passing
  them.
- `ServerSettings` fields `serverArgon2 :: !Argon2Params`, `serverHashingMaxConcurrency ::
  !Int`; env vars `SHOMEI_ARGON2_MEMORY_KIB`, `SHOMEI_ARGON2_ITERATIONS`,
  `SHOMEI_ARGON2_PARALLELISM`, `SHOMEI_HASHING_MAX_CONCURRENCY`; matching optional Dhall
  `FileConfig` fields (append-only extension shared with plans 33/34).
- `deploy/entrypoint.sh` with the cgroup-aware `GHCRTS` default; updated deployment docs.
- `scripts/argon2-load-test.sh`, executable, self-documenting, with the measurement procedure
  in its header.

Cross-plan notes (MasterPlan 6 Integration Points): plan 36 fixes the in-flight metrics gauge
this plan's load test may read — if the load test runs before plan 36 lands, expect the gauge
drift plan 36 fixes and do not use the gauge for acceptance; the boot-time limiter creation
adds a line to `Boot.main` near where plan 34 forks its sweeper — both are additive.
