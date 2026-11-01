---
id: 70
slug: publish-shomei-events-to-kafka-through-a-transactional-outbox
title: "Publish Shomei events to Kafka through a transactional outbox"
kind: exec-plan
created_at: 2026-11-01T21:40:15Z
intention: "intention_01m6cgw3n0ep18ffcqf87te5a7"
provenance:
  created_by:
    model: "gpt-6.1-sol"
    harness: "codex-cli"
    at: 2026-11-01T21:40:15Z
  revisions:
    - model: "gpt-6.1-sol"
      harness: "codex-cli"
      at: 2026-11-01T21:44:12Z
      mode: "other"
      note: "Author trigger-backed Kafka outbox plan with external kafka-effectful migration prerequisite and linked Intention"
---

# Publish Shomei events to Kafka through a transactional outbox

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.
Record friction met while implementing in the friction-log bundle as it occurs (see FRICTION.md).


## Purpose / Big Picture

Operators will be able to publish newly committed Shōmei authentication and security events to Kafka by enabling database capture and starting a background relay. A transactional outbox is a database table holding messages awaiting delivery: an `AFTER INSERT` trigger on `shomei.shomei_auth_events` writes each message inside the transaction that inserted its audit event. Existing workflow transactions and publisher interpreters keep their current code and atomicity. Kafka network calls happen after commit, outside HTTP requests and database transactions.

The new `shomei-kafka` library supplies the message contract and relay using `kafka-effectful`. The user owns migrating that dependency to `rdkafka-hs` before implementation begins. This document authorizes planning only; implementation awaits that prerequisite and a subsequent instruction to start.

Success is observable by enabling capture, performing a registration, and consuming its audit events from a configured Kafka topic. During a broker outage, requests continue to commit and pending messages remain durable; after recovery, those messages arrive with their original event IDs. Delivery is at least once: retries after a crash may duplicate messages, and consumers deduplicate by event ID. Strict global or per-user ordering, historical backfill, consumers, schema-registry integration, multiple destinations, and exactly-once business effects are outside the initial scope.


## Progress

- [ ] M1: The user's migrated `kafka-effectful` release is verified against its registry and tags, and a representative Shōmei envelope can be published and consumed using that release in this toolchain.
- [ ] M2: Opt-in trigger capture and PostgreSQL outbox operations preserve commit/rollback behavior, recover abandoned claims, and retain pending payloads independently of audit retention.
- [ ] M3: `shomei-kafka` publishes versioned messages, waits for broker confirmation, and safely retries with deterministic tests for delivery and crash windows.
- [ ] M4: Standalone and embedded runtimes supervise the opt-in relay with bounded resources, safe configuration, capture controls, and bounded shutdown.
- [ ] M5: Real PostgreSQL/Kafka recovery checks, repository gates, operator documentation, and architectural records establish the complete behavior.

Handoff, 2026-11-01: plan created; no implementation has begun. The user will migrate `mori://shinzui/kafka-effectful/packages/kafka-effectful` to `mori://shinzui/rdkafka-hs/packages/rdkafka-hs`. Keep M1 open until the migrated dependency is available and its actual APIs and delivery/shutdown behavior have been checked.


## Surprises & Discoveries

(None yet.)


## Decision Log

2026-11-01: Capture at the existing audit table with an `AFTER INSERT` trigger. The user explicitly confirmed this approach. It covers ordinary publisher calls and direct unit-of-work inserts without rewriting existing workflow transactions; outbox failure aborts the originating transaction.

2026-11-01: Use the user's migrated `kafka-effectful`, backed by `rdkafka-hs`, and treat its availability as a prerequisite. Do not perform that cross-repository migration or pin the older client as part of this plan.

2026-11-01: Use at-least-once delivery with immutable event IDs, short database claims, and acknowledgments after broker confirmation. Retrying uncertain delivery preserves events across the PostgreSQL/Kafka boundary; consumers must handle duplicates. Partition keys provide routing locality without promising event order.

2026-11-01: Make capture a database-wide opt-in, initially disabled, controlled explicitly by an administrative command. Relay startup never silently changes capture state. This keeps Kafka-free installations from accumulating delivery rows and avoids conflicting replica settings toggling a shared database flag. Pausing a relay while capture stays enabled intentionally accumulates a backlog.

2026-11-01: Copy the payload and destination into the outbox at capture time. Pending delivery must survive audit retention and preserve its destination across configuration changes. Initial capture includes future audit inserts only, with no automatic replay of older rows.


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

The working directory is the repository root, `/Users/shinzui/Keikaku/bokuno/shomei` in the authoring environment. `cabal.project` lists the local Haskell packages; the project uses GHC 9.12.4. `shomei-core` contains transport-independent domain types and Effectful ports, which are interfaces interpreted by concrete implementations. `shomei-postgres` implements database persistence. `shomei-migrations` owns the embedded, ordered PostgreSQL migration manifest. `shomei-server` assembles the standalone runtime and exports the corresponding embedded-host boundary.

`shomei-core/src/Shomei/Audit/Event/Domain.hs` defines `AuthEvent`. `shomei-core/src/Shomei/Audit/Event/Codec.hs` exposes `projectAuthEvent`, mapping each event to user/session IDs, its stable snake_case event type, JSON payload, and occurrence time. The stored payload is the inner data record, not the tagged `AuthEvent` sum. `shomei-core/src/Shomei/Audit/Publisher/Store.hs` defines `publishAuthEvent`. `shomei-postgres/src/Shomei/Audit/Publisher/Postgres.hs` generates a random UUID and inserts the event through the exported `insertAuthEventStmt`.

`shomei-postgres/src/Shomei/Session/UnitOfWork/Postgres.hs` also calls that SQL statement directly inside registration, refresh rotation, password-reset/change, and revocation transactions. Other atomic stores can insert audit rows as well. The audit-table trigger covers all these paths. Preserve the existing persistence guarantees, including any workflows whose full behavior is not presently enclosed in one transaction; this feature extends each audit insert's atomic boundary rather than expanding workflow transactions.

`shomei-core/src/Shomei/Audit/Reader/Store.hs` defines `StoredAuthEvent`, including the stable `storedEventId`. Its PostgreSQL reader pages backward by occurrence timestamp and random UUID. That reader is an administrative query interface, not a reliable delivery cursor: timestamps and random IDs do not describe commit order, and a transaction can commit late. Discover work by pending outbox rows instead.

`shomei-migrations/migrations/shomei/manifest` currently ends at `0037-remembered-sessions.sql`. Allocate the next migration with `just new-migration`, rechecking the manifest when implementation starts. `shomei-migrations/src/Shomei/Migrations.hs` embeds it at compile time. `shomei-migrations/test/Main.hs` tests composition with another component and a hostile lookup path. `shomei-migrations/test-support/Shomei/Migrations/TestSupport.hs` exposes `withShomeiMigratedDatabase` for disposable real-PostgreSQL tests. `shomei-postgres/test/Main.hs` exercises real adapters and workflow transactions.

`shomei-server/src/Shomei/Server/Boot.hs` exports `installHostBackgroundTasks`, its stop action, and `buildEnv`. `shomei-server/src/Shomei/Server/Supervisor.hs` supplies retry loops but currently logs arbitrary exception rendering; Kafka failures must be classified before reaching that boundary. Runtime policy is loaded in `shomei-server/src/Shomei/Server/Config.hs`, the `Env` resource record lives in `shomei-server/src/Shomei/Server/App.hs`, and operator commands are rooted in `shomei-server/app/Admin.hs`. Configuration changes must update `config/shomei-types.dhall`, `config/shomei.example.dhall`, and the matching server tests.

Relevant existing architectural decisions were inspected. [ADR-7](../adr/0007-security-state-transitions-are-atomic-at-the-persistence-boundary.md) keeps security state and its audit tail atomic at persistence. [ADR-8](../adr/0008-runtime-configuration-is-open-strict-and-synchronized.md) requires strict configuration parsing and synchronized Dhall/Haskell keys. [ADR-10](../adr/0010-notification-delivery-is-a-bounded-background-responsibility.md) establishes bounded background work, although Kafka uses durable rows rather than the notifier's in-memory queue. [ADR-9](../adr/0009-transport-exception-text-is-never-persisted.md), [ADR-11](../adr/0011-runtime-secrets-stay-outside-printable-configuration.md), and [ADR-13](../adr/0013-credential-values-and-submitted-identifiers-do-not-cross-diagnostic-boundaries.md) require secret-free diagnostics and non-printable credentials. [ADR-17](../adr/0017-embedded-hosts-install-the-complete-runtime-boundary.md) requires standalone/embedded parity. [ADR-19](../adr/0019-migration-components-do-not-mutate-shared-namespace-state.md) requires schema-qualified SQL and transaction-local lookup paths. There is no existing Kafka/outbox ADR; record that durable decision during implementation through the profiled `docs/adr` workflow.

Dependency sources were located through Mori. At planning time, `mori://shinzui/kafka-effectful/packages/kafka-effectful` still declares `hw-kafka-client`; its producer API includes synchronous delivery and a bracketed producer interpreter. Registry metadata can lag source and releases. `rdkafka-hs` version `1.1.0.0` was verified on Hackage and upstream tags on 2026-11-01, but no future migrated `kafka-effectful` version is assumed here. Recheck both at M1. Native `librdkafka`, including the required version and headers, must match the chosen released client in both development and production builds.


## Plan of Work

### M1 — Verify the migrated dependency and message contract


After the user completes the migration and authorizes implementation, use Mori to locate the current dependency sources and compare the published Cabal metadata with upstream tags. Choose compatible released bounds; keep any necessary source pins identical between Cabal and Nix. Read the migrated producer implementation to establish whether success means enqueueing or broker acknowledgment, how delivery callbacks are driven, and how acquisition, timeout, asynchronous cancellation, and scope exit behave. Resolve a dependency gap before relying on it. In particular, an unbounded interpreter flush at scope exit cannot satisfy this plan's bounded shutdown contract.

Scaffold `shomei-kafka/shomei-kafka.cabal`, a license and changelog consistent with neighboring packages, and `shomei-kafka/src/Shomei/Audit/Kafka/Envelope.hs`. Add transport-independent outbox records and the store port under `shomei-core/src/Shomei/Audit/Outbox/Domain.hs` and `shomei-core/src/Shomei/Audit/Outbox/Store.hs`. The Kafka package depends on `shomei-core` and migrated `kafka-effectful`; concrete database operations remain in `shomei-postgres`, preventing a dependency cycle. Keep Kafka-specific types and dependencies out of core.

Specify envelope version 1 with JSON fields `schema_version` (integer 1), `event_id` (original UUID text), `event_type`, `occurred_at` (UTC ISO-8601), nullable `user_id` and `session_id`, and `payload` (the stored JSON object). Freeze it with representative codec tests and document additive evolution and unknown event types. Choose a stable record key at capture: user UUID if present, otherwise session UUID, otherwise event UUID, each prefixed with its kind. Do not reconstruct raw historical payloads or reread mutable domain rows. Publish and consume one representative envelope through the migrated dependency and real broker before expanding the relay. M1 acceptance is that the consumed ID, key, headers, and payload match the produced fixture, and broker failure produces a bounded classified failure.

### M2 — Add opt-in atomic capture and recoverable claims


Append one schema-qualified migration creating `shomei.shomei_auth_event_outbox`, a singleton `shomei.shomei_auth_event_outbox_config` record, and the audit-table trigger/function. The config starts disabled and stores the capture destination topic. An enabled config requires a valid non-empty topic. The trigger checks that state and copies the original event ID, type, IDs, occurrence time, raw payload, version, key, destination, and database capture time into the outbox. Enforce a unique event ID. Use invoker rights and qualified object names, with the migration's canonical `SET LOCAL search_path = pg_catalog, pg_temp;` preamble and an explicit safe function lookup path. Test the runtime database role's ability to execute the trigger. Do not edit previously applied migration bytes or change `insertAuthEventStmt` or its transaction callers.

Keep copied payload columns independent of the audit table: no cascading deletion or foreign key that would block audit retention. The outbox additionally stores attempt count, next-attempt time, a claim token, lease expiry, delivery time, and a closed failure reason. A lease is a temporary right to deliver a row; a fresh UUID claim token distinguishes the current owner from an expired worker. Use database time for lease calculations.

Implement `shomei-postgres/src/Shomei/Audit/Outbox/Postgres.hs`. Claim a bounded batch in a short transaction using `FOR UPDATE SKIP LOCKED`, which lets concurrent workers skip rows already being claimed. Return only eligible, undelivered rows for the relay's configured destination, replacing expired claims with a new token. Commit before calling Kafka. Completion and retry updates compare the event ID and claim token, so an obsolete worker cannot acknowledge or reschedule a newly claimed row. Pending scans never use a last-seen timestamp or maximum event ID. Keep the number claimed consistent with concurrency and lease length; do not claim a batch that will expire while waiting locally.

Test both publisher and unit-of-work insert paths, explicit rollback, deliberate trigger insertion failure, capture disabled/enabled, and migration reapplication. Test two workers claiming concurrently, lease expiry after interruption, stale-token updates affecting zero rows, and an older-occurrence-time transaction committing after a newer one. Delete an audit row with pending delivery and prove the copied message remains deliverable. M2 passes when these real PostgreSQL cases succeed without Kafka.

### M3 — Implement acknowledged Kafka delivery and retry


Implement `shomei-kafka/src/Shomei/Audit/Kafka/Publisher.hs` and `shomei-kafka/src/Shomei/Audit/Kafka/Relay.hs`. Expose a one-cycle relay function over the core outbox port and an acknowledged-send function; callers own resource lifetime and repetition. A cycle claims eligible work, sends the immutable envelope and stored key to its stored topic with schema/event metadata headers, and marks only broker-confirmed messages delivered. Merely entering the producer queue is insufficient. Configure idempotent production and all-replica acknowledgment through the verified dependency, while retaining consumer deduplication for cross-process retries.

Use a bounded send deadline shorter than the claim lease. Start with one in-flight send per worker; permit bounded batch claiming only when its full processing budget fits the lease. On timeout or uncertain delivery, leave the event retryable and retain its original ID and contents. Use capped exponential retry delays with jitter and a stored next-attempt time, so one repeatedly failing row does not block other eligible rows. Repeated failures remain pending and observable rather than being silently dropped at an attempt limit. Define stable reasons such as `connect_failed`, `timeout`, `auth_failed`, `queue_full`, and `delivery_failed`; do not persist free-form client errors or emit failure audit events that recursively feed the same outbox.

Use deterministic tests with a fake acknowledged-send boundary for success, rejection, timeout, partial batch success, cancellation, and failure after broker success but before database acknowledgment. A retry of that final case must reuse the exact event ID and envelope. M3 passes when these checks demonstrate no acknowledgment before confirmed delivery, no loss after interruption, and continued progress for other eligible messages.

### M4 — Integrate capture controls and bounded runtime resources


Add `shomei-server/app/Shomei/Admin/KafkaOutbox.hs` and wire `shomei-admin kafka-outbox enable --topic TOPIC`, `disable`, and `status --json` into `shomei-server/app/Admin.hs`. These commands use database operations without a running broker. Enabling the same topic and disabling repeatedly are idempotent. Disable stops future capture without discarding pending work. Status reports capture state/topic, pending and leased counts, oldest pending age, and a safe failure summary, including destination-specific backlog. The trigger observes the database flag when its insert executes; enabling capture does not retrospectively include audit inserts that already ran in in-flight transactions. Document this activation boundary. Changing capture topic affects future rows only; existing rows retain their old topic and require a relay serving that destination to drain them.

Add relay policy to server settings: disabled by default, bootstrap addresses, one topic, poll delay, claim/send/lease bounds, and retry policy. Reject unknown fields, invalid topics, nonpositive bounds, and inconsistent timing budgets before acquiring resources. Carry TLS/SASL credentials in non-printable runtime values beside public policy, with TLS and authentication configured through a documented supported mapping rather than arbitrary printable secret-bearing properties. Support a conspicuous lab-only plaintext setting for a local broker. Synchronize Haskell, Dhall schema/example, and configuration tests. Server boot does not enable, disable, or retarget database capture; a deliberately disabled relay can coexist with enabled capture.

Acquire a long-lived producer and a small dedicated database pool for the relay. Connect installation and cleanup through `installHostBackgroundTasks` and `HostBackgroundTasks.stopHostBackgroundTasks`, so embedded hosts receive the same worker. When relay policy is disabled, acquire no Kafka resources. When the broker is unavailable, HTTP serving remains available and the worker retries with backoff; malformed local policy still fails validation. Classify dependency exceptions before any general supervisor logs them, including exceptions on producer acquisition and release. Preserve asynchronous cancellation.

Shutdown stops new claims, bounds any in-flight wait and producer cleanup by the remaining existing shutdown budget, and releases the relay pool. Unconfirmed work remains recoverable when leases expire. Tests must cover actual dependency cleanup behavior, not just a mocked send timeout. Add runtime/configuration/admin tests to `shomei-server/test/Shomei/Server/ConfigSpec.hs`, `shomei-server/test/Shomei/Server/SupervisorSpec.hs`, and the relevant new test modules. M4 passes when disabled startup is broker-independent, outage/recovery does not stall requests, both runtime styles install and stop exactly one relay, and shutdown meets its configured bound.

### M5 — Prove recovery and complete packaging/documentation


Add a separately named real-broker integration suite, `shomei-kafka-integration`, under `shomei-kafka/test-integration/Main.hs`. Use a disposable PostgreSQL from the existing test-support library and a unique topic on a disposable Kafka-compatible broker. Include a bounded preflight when running this suite so absent infrastructure fails clearly instead of passing or hanging. Keep ordinary unit suites runnable without a broker; explicitly run the integration suite in a CI job with a broker. The integration suite must exercise the real trigger, PostgreSQL store interpreter, migrated producer, and consumer together. Prove registration emits its stored events, rollback emits none, broker recovery drains pending messages, and interrupted delivery can be recovered with the same IDs. Verify safe failure logs using synthetic credential sentinels.

Wire `shomei-kafka` into `cabal.project`, relevant `.cabal` dependencies, `mori.dhall`, and the separate `examples/embedded-with-en/cabal.project`. Update `flake.module.nix` to include the new local package, the same verified dependency versions as Cabal, and the native library in development and production. Add any new source inputs only where required and preserve their locked agreement. Ensure the production image contains the native runtime library. Update `.github/workflows/ci.yaml` for the explicit broker integration job and any ordinary-suite selection needed. Do not silently skip broker tests in the integration job.

Document the package in `README.md` and `shomei-kafka/README.md`; document configuration, activation, pause/recovery, duplicate handling, routing, backlog monitoring, and audit/outbox retention in `docs/user/deployment.md` and `docs/user/security.md`. Delivered outbox rows may be removed in bounded cleanup batches after seven days; pending/leased rows must never be removed by age. An extended outage can exhaust database disk and then cause request failures: the guarantee is isolation from Kafka latency, subject to database capacity. Explain how to disable future capture while preserving the backlog. Add per-package changelog entries. Create the outbox ADR and update affected ADRs using their stable IDs and strict profile/log validation.

M5 passes after the real recovery scenarios and repository gates below pass, with concise evidence recorded in this plan. Leave release publication to a separate release instruction.


## Concrete Steps

Run commands from the repository root unless a block states otherwise. First verify the external prerequisite; these commands discover current sources and released versions, and do not perform the migration:

```bash
mori registry search kafka
mori registry show shinzui/kafka-effectful --full
mori registry docs shinzui/kafka-effectful
mori registry show shinzui/rdkafka-hs --full
mori path mori://shinzui/kafka-effectful/packages/kafka-effectful
curl -fsSL https://hackage.haskell.org/package/kafka-effectful/preferred.json
curl -fsSL https://hackage.haskell.org/package/rdkafka-hs/preferred.json
git ls-remote --tags https://github.com/shinzui/kafka-effectful.git
git ls-remote --tags https://github.com/shinzui/rdkafka-hs.git
```

Inspect the resolved source's Cabal file and producer interpreter; record the selected migrated release, registry evidence, and matching tag in Interfaces and Dependencies before checking off M1. A release still declaring `hw-kafka-client` does not satisfy the prerequisite. Use Mori before consulting any further dependency API; never inspect or search `/nix/store`.

Create the additive migration once at M2:

```bash
nix develop --command just new-migration auth-event-kafka-outbox
nix develop --command just migration-check
```

Expect a new SQL file appended to the manifest, plus a successful manifest and namespace-policy check. On retry, edit the already-created file rather than allocate another migration for the same change.

Use these focused checks after the corresponding implementation exists:

```bash
nix develop --command cabal test shomei-core-test shomei-migrations-test shomei-postgres-test --test-show-details=direct --test-options='-j2'
nix develop --command cabal test shomei-kafka-test --test-show-details=direct
nix develop --command cabal test shomei-server-config-test shomei-admin-test shomei-server-test --test-show-details=direct --test-options='-j2'
```

At M1, add `scripts/test-kafka-outbox-integration.sh` and a `Justfile` recipe named `kafka-outbox-integration`. Its contract is to provision a disposable local broker (or use `SHOMEI_TEST_KAFKA_BROKERS` supplied explicitly), wait for readiness within a deadline, create unique test topics, run `cabal test shomei-kafka-integration --test-show-details=direct`, and clean up only the resources it created. Use the project's registered Redpanda tooling when appropriate after Mori lookup; permit an externally provisioned Kafka-compatible broker in CI. Add the recipe early so the representative M1 check and final M5 tests use the same path. Supply `rpk` or another verified broker client in the development shell for fixtures/inspection. The script must not stop a user's existing broker.

```bash
nix develop --command just kafka-outbox-integration
```

Expected result: the real roundtrip and, by M5, outage, rollback, and restart cases pass; failure to start/contact the test broker exits nonzero with a safe reason.

For a manual demonstration on a disposable, already configured Shōmei development database and local plaintext lab broker, create `shomei-auth-events-v1` on that broker, then run:

```bash
nix develop
export DATABASE_URL="$PG_CONNECTION_STRING"
cabal run exe:shomei-admin -- kafka-outbox enable --topic shomei-auth-events-v1
cabal run exe:shomei-admin -- kafka-outbox status --json
SHOMEI_KAFKA_ENABLED=true SHOMEI_KAFKA_BROKERS=localhost:9092 SHOMEI_KAFKA_TOPIC=shomei-auth-events-v1 SHOMEI_KAFKA_ALLOW_PLAINTEXT=true cabal run exe:shomei-server
```

These are new command/configuration names required by M4. Use the existing database and signing-key setup documented in `docs/user/deployment.md`; do not provision production credentials for this check. In a second terminal, create a fresh disposable account using the existing signup route:

```bash
curl --fail-with-body -sS -X POST http://localhost:8080/v1/auth/signup \
  -H 'content-type: application/json' \
  -d '{"loginId":"kafka-demo","email":"kafka-demo@example.com","password":"correct horse battery staple","displayName":"Kafka demo"}'
```

Consume records with the integration fixture's broker client and compare their event IDs with the audit rows. Expect version 1 `user_registered` and `session_started` messages; status should eventually show no pending rows. Run this signup once per fresh demo database or use a new login ID on repeat. The automated `just kafka-outbox-integration` command performs the complete write/consume/assert path with isolated accounts and topics; keep its fixture runnable without manual inspection. Record the exact broker-client inspection command used when implementing M5.

Run final gates after coherent implementation:

```bash
nix develop --command cabal build all
nix develop --command just build-embedded-with-en
nix develop --command just migration-check
nix develop --command cabal test all --test-options='-j2'
nix develop --command just kafka-outbox-integration
nix develop --command just adr-validate
nix build .#default
nix build .#dockerImage
nix fmt -- --fail-on-change
git diff --check
```

For `cabal test all`, run with the test broker available if it includes the explicitly named integration suite; the normal CI job should select broker-independent suites, with integration covered by its dedicated broker job. If flake sources omit new untracked files, stage only this work's reviewed new files before Nix evaluation. Expect successful builds/tests and an empty formatting diff. Do not broaden repeated checks after a passing final candidate unless further edits or failures invalidate the evidence.


## Validation and Acceptance

Acceptance requires observable behavior across the complete path. With capture disabled, ordinary authentication works without a broker and creates no outbox rows. With capture enabled, every committed audit insert creates exactly one durable outbox entry with the same event ID, including direct unit-of-work writes. Rolling back that transaction leaves neither row. Forcing the trigger's outbox insert to fail rolls back the associated state change rather than producing an unaudited or unqueued half-state.

With the relay enabled and a healthy broker, consume the specified JSON envelope and stable key, and match its event ID to the database. An old occurrence timestamp or late commit must still be delivered. Audit retention must not erase a pending payload. Unknown future event types remain publishable as their raw captured type/payload. Tests pin the envelope's JSON keys, null handling, timestamps, key precedence, and header encoding.

With the broker stopped, authentication continues to return its normal result and pending count grows; attempts use bounded time and backoff. On recovery, all committed pending IDs eventually appear and become delivered. Inject interruption before send, during send, and between broker confirmation and database acknowledgment. Restart or lease expiry recovers the work; the last case may produce duplicates with identical IDs. Two relay instances must make progress without stale owners marking another claim complete. No global or per-key event order is required.

Configuration and lifecycle tests prove opt-in defaults, strict Dhall/Haskell alignment, validated timing constraints, credential separation, no raw secret-bearing exception logs, and a bounded full shutdown including producer cleanup. Embedded and standalone runtimes exercise the same installer. Disable capture and prove future inserts are no longer queued while previous pending rows remain. Pause/restart only the relay and prove capture continues throughout. Repeated enable/disable commands must be safe; topic changes must not retarget already-captured messages.

The M1 real-envelope roundtrip is the early interaction check between the independently migrated dependency and Shōmei. The M5 real PostgreSQL/broker suite extends it to the atomicity and recovery guarantees. Record passing suite counts, dependency versions, broker type/version, and concise recovery observations under Progress when verified; do not mark any milestone complete from compilation alone.


## Idempotence and Recovery

Migration application uses the existing ledger and is repeatable; applied SQL history remains immutable. Start the new schema with capture disabled, making deployment safe for existing Kafka-free installations. Enable capture deliberately after topic/relay setup; no historical audit backfill is performed. Topic and broker access are operator-provisioned, not created on every production boot. Migration failure rolls back the additive database changes through the existing runner.

Relay cycles are repeatable because each captured ID is unique and completion requires the current claim token. A lost acknowledgment is retried with the same ID. Clock-based lease expiry uses database time, and pending work is independent of any in-process queue. Tests use isolated databases and unique topics and clean up only their own resources. A duplicate Kafka record is an expected recovery case, not grounds to delete pending rows without acknowledgment.

To pause publishing, disable the relay; to stop future capture, use `shomei-admin kafka-outbox disable`. Preserve pending rows in both cases. An older application binary can continue inserting audit rows because capture lives in the database trigger, provided its database role retains the required privileges. To abandon the feature, first disable capture and stop relays, then retain or export the backlog according to an explicit operator decision; do not automatically drop it or reverse an applied migration. Delivered-only bounded cleanup removes old delivery records without touching pending work. Explain database-capacity monitoring and destination-specific draining in the deployment guide.


## Interfaces and Dependencies

The external prerequisite is the user's released migration at `mori://shinzui/kafka-effectful/packages/kafka-effectful`, consuming `mori://shinzui/rdkafka-hs/packages/rdkafka-hs`, with the matching native dependency discovered through `mori://confluentinc/librdkafka/packages/librdkafka`. No migrated release number is selected yet. M1 must record the verified versions, exact APIs for broker-confirmed send and bounded producer lifecycle, and any immutable source fallback before feature implementation proceeds beyond the representative check. Use only dependencies compatible with Shōmei's GHC 9.12.4 toolchain; align Cabal and Nix rather than adding compatibility relaxations from memory.

`Shomei.Audit.Outbox.Domain` in `shomei-core/src/Shomei/Audit/Outbox/Domain.hs` owns transport-independent immutable `OutboxMessage`, current `OutboxClaim` with its token and expiry, retry policy, and safe failure reason types. A message carries its original UUID, envelope version, captured audit fields, stored destination, and stored partition key. `Shomei.Audit.Outbox.Store` in `shomei-core/src/Shomei/Audit/Outbox/Store.hs` owns an Effectful port with bounded destination-filtered claim, conditional delivered/retry updates, capture enable/disable, status, and bounded delivered-only cleanup. Conditional mutations report whether the token still owns the row; zero changed rows is a stale claim, not permission to retry a different mutation blindly. Supply a small deterministic fake for relay tests without weakening the real PostgreSQL concurrency tests.

`Shomei.Audit.Outbox.Postgres` in `shomei-postgres/src/Shomei/Audit/Outbox/Postgres.hs` interprets that port using the existing database effect and short transactions. `Shomei.Audit.Kafka.Envelope` owns wire encoding. `Shomei.Audit.Kafka.Publisher` uses the migrated Kafka effect for an acknowledged send. `Shomei.Audit.Kafka.Relay` coordinates one cycle over these ports, exposing a callable library API for embedded consumers. Its send boundary distinguishes confirmed success from retriable/uncertain failure; it never treats local enqueue success as delivery. Adopt concrete migrated dependency signatures at M1 and record the selected public signatures here before expanding implementation.

The initial operational contract has one destination per relay and one active capture topic per database. Multiple replicas may relay the same destination using the claim protocol. Changing brokers while a backlog exists is an operator-managed destination migration: a topic name alone does not identify a Kafka cluster. Keep the broker target stable until that backlog is drained, and document this limitation. Consumers deduplicate on event ID within their Shōmei deployment/source namespace.

There is no parent MasterPlan for this work. Preserve the generated plan frontmatter and Intention ID. Implementation commits use Conventional Commits and include `ExecPlan: docs/plans/70-publish-shomei-events-to-kafka-through-a-transactional-outbox.md` and `Intention: intention_01m6cgw3n0ep18ffcqf87te5a7` trailers. Cross-repository durable references use canonical Mori URIs. Maintain provenance with the skill's script, and use `agents/skills/exec-plan/FRICTION.md` to record material implementation friction if any arises.
