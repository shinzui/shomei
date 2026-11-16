---
id: 73
slug: fix-operator-papercuts-in-admin-commands-and-server-metrics
title: "Fix operator papercuts in admin commands and server metrics"
kind: exec-plan
created_at: 2026-11-16T05:09:48Z
intention: "intention_01m7hc4aspej5rapxfktdnavgp"
provenance:
  created_by:
    model: "gpt-6.1-sol"
    harness: "codex-cli"
    at: 2026-11-16T05:09:48Z
  revisions:
    - model: "gpt-6.1-sol"
      harness: "codex-cli"
      at: 2026-11-16T05:19:38Z
      mode: "implement"
      note: "Implement admin validation, safe configuration failures, no-op conversion, and metrics readability"
---


# Fix operator papercuts in admin commands and server metrics

This ExecPlan is a living document. Keep Progress, Surprises & Discoveries, Decision Log, and Outcomes & Retrospective current during implementation. Follow `agents/skills/exec-plan/PLANS.md`, `agents/skills/exec-plan/ADR.md`, and `agents/skills/exec-plan/FRICTION.md` for updates, durable decisions, and implementation friction.


## Purpose / Big Picture

Fix all six operator-facing defects in [issue #8](https://github.com/shinzui/shomei/issues/8), including its comment about audit filter typos. Operators will see accurate revocation guidance, required redirect arguments in help, useful failures for unknown audit types, successful keyless TOTP conversion when no legacy data remains, concise configuration errors, and readable, documented metrics. This plan creates no new authentication capability; it improves the existing administrative and server interfaces. Completion is demonstrated through actual executable output, database fixtures, and metrics responses.


## Progress

- [x] Milestone 1 (2026-11-16): Required/repeated redirects, direct-call validation, all four audit parsers, known empty queries, and lifetime-independent revocation guidance pass in the 36-test admin suite. All 293 core tests pass, including unique vocabulary coverage and projection/decoding of every constructor fixture.
- [x] Milestone 2 (2026-11-16): Subprocess tests prove empty/bound keyless no-ops, malformed-key no-ops, offline/version guards, missing/malformed/wrong-key rejection, correct-key conversion and keyless rerun. Both binaries produce safe single-line configuration failures, including converter and notifier-secret failures. The config suite and all 100 PostgreSQL tests pass.
- [x] Milestone 3 (2026-11-16): All 57 server tests pass, including empty/populated WAI metrics responses, six metadata families, ordered decimal buckets and infinity/count equality. Operator guides, changelogs, ADR-8 and ADR-20 are updated. Full `cabal test all`, `cabal build all`, formatting, whitespace and strict ADR checks pass.

Implementation and validation are complete. Concurrently committed plan 71 remains untouched.


## Surprises & Discoveries

Discovery (2026-11-16): The server executable has no help parser; normal help acceptance applies to the existing admin CLI. Server configuration failures are tested by invoking its existing argument-free startup. No new server command interface is introduced.


## Decision Log

Decision (2026-11-15): Include the issue's audit-filter comment in acceptance. A misspelled event type returning an empty successful result is part of the reported operator problem, not a separate feature.

Decision (2026-11-15): Remove the parenthetical default lifetime from the revocation warning, leaving “note: tokens already issued to this account remain valid until they expire”. Current deployment configuration cannot establish the expiration time of previously issued tokens. This avoids presenting the current machine-token lifetime as a historical guarantee.

Decision (2026-11-15): Validate CLI audit type names against the binary's known event vocabulary. Do not change the storage reader or HTTP audit filter semantics. The CLI will document this version-specific vocabulary; a rolling deployment requiring newer event filters needs a matching admin binary.

Decision (2026-11-15): Treat decimal bucket labels and HELP metadata as an operator readability contract. Scientific notation is not evidence of an invalid Prometheus scrape, and HELP lines are optional in the text format. Preserve metric names, units, boundaries, values, and the existing content type.


## Outcomes & Retrospective

Completed 2026-11-16. All six operator defects are fixed without changing schemas, stored event names, HTTP audit filter semantics, token lifetimes, encryption formats, or numerical histogram boundaries. Executable subprocess coverage verifies observable output and redaction; temporary PostgreSQL fixtures verify no-op and real conversion safeguards. The public event vocabulary is checked against the same constructor fixtures used for projection and reconstruction.

`nix develop --command cabal test all --test-options='-j2' --test-show-details=direct` passed every configured suite. After final test-fixture and early notifier-validation refinements, `cabal build all` and the core/admin/config/server suites passed again (293/36/1/57 tests respectively); the unchanged PostgreSQL suite retains its 100-test passing result. `nix fmt -- --fail-on-change`, `git diff --check`, and strict profiled ADR validation passed. No implementation friction entries were recorded under this plan, and none remain to triage.

ADR distillation updated ADR-8 with the typed, redacted configuration boundary and ADR-20 with the keyless offline no-op rule. Exact finite histogram `le` labels change spelling and can create new Prometheus series; the changelog calls out exact-label dashboard adjustments. No release/version bump was made.


## Context and Orientation

This is a multi-package Haskell project. `shomei-core` owns authentication configuration and event types. `shomei-postgres` persists them. `shomei-server` supplies the standalone server library, `shomei-server` executable, and `shomei-admin` executable. Cabal is the build/test tool; `nix develop` supplies the pinned compiler, PostgreSQL, Dhall converter, and formatters. Test databases are temporary instances created by `withShomeiMigratedDatabase` from `shomei-migrations:test-support`; do not point regression tests at a real deployment. Limit test concurrency to two to avoid exhausting temporary PostgreSQL instances.

`shomei-server/app/Admin.hs` parses commands before calling `loadAdminEnv` in `shomei-server/app/Shomei/Admin/Env.hs`. That loader requires `DATABASE_URL`, reads the deployment's core policy through `loadCoreConfig`, checks password-hashing settings, then acquires a pool. Server startup in `shomei-server/src/Shomei/Server/Boot.hs` instead calls `loadConfig` from `shomei-server/src/Shomei/Server/Config.hs`; the executable wrapper is `shomei-server/app/Main.hs`. Configuration rejection currently often uses `ioError (userError ...)`, so an uncaught exception produces the compiler runtime's diagnostic and stack information. `loadDhallFile` also runs an external `dhall-to-json` process and can fail before JSON decoding. The startup error solution must cover that path as well as environment validation.

`shomei-server/app/Shomei/Admin/ServiceAccounts.hs` emits the fixed five-minute note in `runServiceAccounts`. Actual machine policy is `ShomeiConfig.machineTokenConfig.machineTokenTTL` in `shomei-core/src/Shomei/Config.hs`. A machine token is a signed access credential with its own expiration time. Revoking the account prevents future issuance; this plan changes no token verification or revocation semantics.

`shomei-server/app/Shomei/Admin/OAuthClients.hs` uses `many` for `--redirect-uri`, then `parseRedirectUris` rejects an empty list at execution time. A redirect URI is an exact permitted callback URL for the authorization-code flow. Change parser cardinality to one-or-more while preserving direct-call validation. The existing parser library is `mori://pcapriotti/optparse-applicative/packages/optparse-applicative`. Mori located its local README and source; its combinators support repeated arguments through `many` and `some`. No dependency version or pin changes are required.

`shomei-server/app/Shomei/Admin/Audit.hs` shares `filtersParser` across `events`, `user`, `session`, and `count`; `toQuery` currently passes `fTypes` through as arbitrary text. The audit trail is the persisted sequence of security events. Its stable wire names, such as `login_failed`, are mapped by `projectAuthEvent` and `reconstructAuthEvent` in `shomei-core/src/Shomei/Audit/Event/Codec.hs`; constructors and payloads live in `shomei-core/src/Shomei/Audit/Event/Domain.hs`. `shomei-core/test/Shomei/Audit/Event/CodecSpec.hs` already enumerates representative constructors and known names. `shomei-core/src/Shomei/Audit/Reader/Store.hs` intentionally accepts arbitrary text filters; keep that persistence contract.

TOTP means time-based one-time password, an authenticator-app second factor. Its encrypted database envelope has a version: 0 is legacy, 1 binds the ciphertext to the credential and user. In `shomei-server/app/Admin.hs`, `TotpMigrateEnvelopes` already counts legacy/invalid rows, but loads the encryption key before checking whether conversion is unnecessary. `shomei-postgres/src/Shomei/Mfa/Totp/Postgres.hs` exposes version inspection and resumable batches. Existing converter regression coverage is in `shomei-postgres/test/Main.hs`.

`shomei-server/src/Shomei/Server/Observability/Metrics.hs` maintains counters, an in-flight gauge (current active requests), and a duration histogram (cumulative counts at fixed time boundaries). `exportMetrics` emits TYPE metadata but no HELP descriptions, and uses `tshow` for floating-point `le` labels. `le` is a bucket's inclusive upper bound in seconds. Existing metrics tests are in `shomei-server/test/Shomei/Server/MiddlewareSpec.hs`. The authoritative [Prometheus exposition specification](https://prometheus.io/docs/instrumenting/exposition_formats/) defines HELP escaping, metadata grouping, ascending buckets, and the requirement that the `+Inf` bucket equal the histogram count. Decimal formatting is this issue's readability requirement.

Relevant ADRs were discovered by scanning local filenames/headings. [ADR-8](../adr/0008-runtime-configuration-is-open-strict-and-synchronized.md) requires strict synchronized configuration: error presentation must not make invalid input acceptable. [ADR-11](../adr/0011-runtime-secrets-stay-outside-printable-configuration.md) keeps secrets outside printable configuration. [ADR-13](../adr/0013-credential-values-and-submitted-identifiers-do-not-cross-diagnostic-boundaries.md) prevents secrets from reaching diagnostics; do not print arbitrary subprocess errors or raw configuration values. [ADR-20](../adr/0020-totp-envelopes-bind-row-identity-and-require-offline-conversion.md) requires stopped writers, backups, valid envelope versions, and the correct key for real conversion. A no-op must preserve those checks that identify unsafe data, while avoiding unnecessary key access.


## Plan of Work

### Milestone 1: Make admin arguments and output trustworthy

Change `oauthClientsParser` in `shomei-server/app/Shomei/Admin/OAuthClients.hs` from `many` to `some` for redirects, retain repeatability, and retain `parseRedirectUris` for programmatic callers. Verify rendered help marks one occurrence as required. Reject missing redirects before database/environment acquisition; one or several valid redirects continue to parse.

Add an exported `knownAuthEventTypes :: [Text]` to `shomei-core/src/Shomei/Audit/Event/Codec.hs`, listing every currently supported stored event name. Extend `shomei-core/test/Shomei/Audit/Event/CodecSpec.hs` so the vocabulary is unique and matches the names covered by every constructor's projection/decoding fixture. Include constructors added by concurrent work before finalizing; do not hard-code today's count in a new assertion. Use this vocabulary in a validated `--type` reader in `shomei-server/app/Shomei/Admin/Audit.hs`. Reject an unknown type with a useful message listing accepted names and exit failure. Preserve no-filter queries, repeated valid types, and all four subcommands. Also validate `fTypes` in `toQuery` so direct action callers cannot bypass this contract. Validation does not inspect whether the database currently has matching rows: a known type with zero matches remains a successful empty result.

Remove only the fixed-duration parenthetical from `runServiceAccounts` as recorded above. Extend `shomei-server/test/Admin/Main.hs` with parser/help regressions, unknown/known audit queries, and captured revocation output using default and nondefault machine policy. Use the existing temporary-database tests to confirm revocation still prevents issuance. Milestone acceptance is all these behaviors passing in `shomei-admin-test` and the core codec tests.

### Milestone 2: Handle no-op maintenance and configuration errors cleanly

In the TOTP branch of `shomei-server/app/Admin.hs`, retain `--check` as read-only version reporting without a key. For conversion, enforce `--offline` and reject unknown versions before declaring success. When legacy count is zero, print `converted=0` and exit success without reading or parsing `SHOMEI_TOTP_ENCRYPTION_KEY`; this applies to both an empty table and a table containing only version 1 rows. With legacy rows, still require a valid key and retain bounded batches, conflict handling, and error recovery. Unknown versions must fail even if the legacy count is zero. Keep the existing behavior of `--check` when combined with `--offline`.

Introduce a small shared startup configuration-error boundary in the server library, for example `shomei-server/src/Shomei/Server/ConfigurationError.hs`. Give expected validation errors a typed exception with a safe one-line description. Replace expected `userError` failures in `shomei-server/src/Shomei/Server/Config.hs` and `shomei-server/app/Shomei/Admin/Env.hs` with this exception, using setting names and constraints without echoing raw submitted values. Catch only that type at the server's configuration-loading boundary and admin environment-loading boundary, emit one prefixed stderr line, and exit failure. Do not catch arbitrary runtime exceptions, asynchronous cancellation, or `ExitCode`; library callers must still receive a failure. Normalize embedded newlines/control characters in the safe description. Adjust existing configuration tests that assert exception types accordingly, preserving their validation coverage.

For `loadDhallFile`, capture converter stdout/stderr rather than letting the child write uncontrolled diagnostics. Translate a missing converter, unreadable/invalid Dhall file, nonzero conversion exit, and rejected rendered JSON into a safe configuration error naming the relevant setting/stage. Do not include raw rendered JSON, converter stderr, secret-bearing paths, or arbitrary exception text. Catch only the expected process-launch/read failures at this narrow operation. Retain useful names for invalid environment fields and semantic invariants. Extend `shomei-server/test/Shomei/Server/ConfigSpec.hs` for loader failures and sentinel-secret redaction.

Add subprocess regressions to `shomei-server/test/Admin/Main.hs` for both executables, because action-level exception tests cannot prove stderr and exit behavior. Wire `process` (using the project's existing compatible bound) and `build-tool-depends` on `shomei-server:shomei-admin` and `shomei-server:shomei-server` in `shomei-server/shomei-server.cabal`. Resolve executables through Cabal's test PATH. Set child environments explicitly, clearing inherited `SHOMEI_*`, `DATABASE_URL`, and `PG_CONNECTION_STRING` values before installing each fixture. Reuse `withShomeiMigratedDatabase` for conversion fixtures. Require one stderr line and nonzero exit for missing connection settings, malformed numeric settings, unknown/invalid Dhall config, and converter failures, with no `Uncaught exception`, `user error`, backtrace, or sentinel secret. Assert normal `--help` still exits zero. Verify real legacy conversion fails safely without a key and still succeeds with the correct key; reuse fixture encryption helpers rather than inventing an envelope format. This milestone passes the admin, configuration, and PostgreSQL suites.

### Milestone 3: Make metrics readable and finish operator documentation

In `shomei-server/src/Shomei/Server/Observability/Metrics.hs`, render each existing finite bucket with stable ordinary decimal text: `0.005`, `0.01`, `0.025`, `0.05`, `0.1`, `0.25`, `0.5`, `1`, `2.5`, `5`, `10`. Keep the numerical thresholds and recording logic identical. Pair numeric boundaries with explicit labels or use a deterministic decimal formatter; never round small boundaries to zero. Emit one HELP and one TYPE line per base metric family, ahead of its samples, even before any requests. Descriptions must accurately state what the current counters measure and that duration is in seconds. Escape backslashes and newlines in HELP text separately from label escaping. Keep `+Inf`, sum, count, method/status dimensions, and bounded method vocabulary.

Extend `shomei-server/test/Shomei/Server/MiddlewareSpec.hs` to check an empty export and an export after a request, asserting all finite labels, unique HELP/TYPE metadata for all six families, metadata before samples, ordered cumulative buckets, and `+Inf` equal to count. Exercise the WAI `/metrics` middleware response, including its content type, rather than only testing string helpers. Existing tests for throwing handlers and hostile method names must continue to pass.

Update `docs/user/deployment.md` for concise startup errors and documented metrics, `docs/user/mfa.md` for keyless no-op conversion and unchanged real-conversion safeguards, and `docs/user/api.md` where it describes audit/admin usage. Add a concise entry to `shomei-server/CHANGELOG.md`; if the core vocabulary is publicly exported, also note that addition in `shomei-core/CHANGELOG.md`. No release/version bump is part of this plan. Finish with the checks below and ADR distillation; update ADR-20 if necessary to clarify that its key requirement applies when conversion actually occurs, following the profiled ADR workflow.


## Concrete Steps

Run commands from the repository root. In a checkout elsewhere, substitute its root for the first command.

```bash
cd /Users/shinzui/Keikaku/bokuno/shomei
export MORI_PG_CONNECTION_STRING='host=/Users/shinzui/.local/state/postgresql dbname=mori user=shinzui connect_timeout=5'
git status --short
nix develop --command cabal build exe:shomei-admin exe:shomei-server
```

Start with focused regression tests for the milestone being changed, then run the required final affected suites once the final implementation is assembled:

```bash
nix develop --command cabal test shomei-core-test shomei-admin-test shomei-server-config-test shomei-server-test shomei-postgres-test --test-options='-j2' --test-show-details=direct
nix develop --command cabal build all
nix fmt -- --fail-on-change
git diff --check
```

Expected results are successful compilation, each named suite passing, formatting exiting zero without changing files, and no whitespace errors. If formatting fails, format only the files changed for this plan and recheck; preserve unrelated work. Run the full `cabal test all --test-options='-j2'` if shared core changes or failures reveal broader impact. No schema change is expected; if implementation unexpectedly needs one, revisit scope and migration validation before proceeding.

Use these executable smoke checks after building:

```bash
nix develop --command cabal run exe:shomei-admin -- oauth-clients create --help
nix develop --command cabal run exe:shomei-admin -- oauth-clients create --display-name example --type public
nix develop --command cabal run exe:shomei-admin -- audit events --type no_such_type
```

Help shows a required repeatable redirect. The second command exits nonzero for the missing redirect. The third exits nonzero with accepted event types; it must fail at parsing even without a database configured. Cabal may add build messages, so stderr line-count assertions belong to tests invoking the binaries directly.

During implementation, record the first substantive update with the bundled provenance script using verified current-agent identity and `--mode implement`. Any commits use Conventional Commits and both trailers:

```text
ExecPlan: docs/plans/73-fix-operator-papercuts-in-admin-commands-and-server-metrics.md
Intention: intention_01m7hc4aspej5rapxfktdnavgp
```


## Validation and Acceptance

Milestone 1 must prove missing redirects are rejected before configuration/database loading, repeated redirects parse, and direct empty-list calls remain invalid. Test `no_such_type` alone and mixed with a valid type, across events/user/session/count. A recognized but absent event type succeeds with empty list output or count zero. Revocation prints exactly the lifetime-independent note for default and nondefault TTL settings and retains its persistence effects.

Milestone 2 must prove keyless offline success with `legacy=0 invalid_versions=0` followed by `converted=0`, both with no rows and with version 1 rows; a malformed key must also be ignored for a no-op. `--check` remains keyless and read-only. An unknown version fails conversion even with no legacy rows; missing `--offline` is still rejected. Legacy rows without a key, with a malformed key, or with the wrong key fail without overwriting unreadable rows; correct-key conversion succeeds, and rerunning keyless succeeds. Existing bounded/resumable converter tests continue to pass. Both binaries' expected configuration failures produce a single safe stderr line and failure status, while normal help succeeds. Redaction tests use sentinel credentials and ensure they never appear in stdout or stderr.

Milestone 3 must prove `/metrics` returns the existing successful text response with HELP descriptions, ordinary decimal finite bucket labels, consistent cumulative counts and correct infinity/count behavior. The source specifies six families: HTTP total, in-flight requests, duration histogram, successful logins, failed logins, and issued tokens. No metric names or numerical boundaries change. The label spelling change can create new series for the finite buckets on existing Prometheus installations; document this in the changelog so dashboards using exact label text can be adjusted.

Record concise command results and behavioral evidence in Progress as milestones complete. Compilation alone does not accept output behavior. Mark implementation milestones complete only from verified implementation behavior.


## Idempotence and Recovery

Builds and temporary-database tests can be rerun. Do not run conversion against a real database for acceptance. The converter remains explicitly offline and resumable; real deployments require stopped writers and matching database/key backups before conversion, and rollback after conversion requires restoring the matching backup as ADR-20 describes. This plan introduces no schema migration and must not rewrite version 1 rows on a no-op. Preserve unrelated worktree changes and other plans; never reset the tree to simplify validation.

Expected configuration-error handling must remain limited to configuration loading; retry after correcting the named field. Do not suppress infrastructure/programming failures through a catch-all. Before declaring completion, triage any friction recorded under this plan and distill durable decisions into the appropriate existing ADRs, using `okf validate docs/adr --strict --profile docs/adr/profile.dhall --profile-enforce --log-enforce` if ADRs changed.


## Interfaces and Dependencies

Keep the CLI command names and existing successful output formats except the specified revocation note, parser/help improvements, and no-op conversion result. Add only the core `knownAuthEventTypes :: [Text]` vocabulary and internal typed configuration-error helper required above. Preserve `AuditEventQuery.queryEventTypes :: [Text]`, stored event strings, encryption envelopes, database schemas, HTTP audit API behavior, token lifetimes, and metrics collection semantics.

Use existing optparse-applicative, exception, subprocess, bytestring-builder, WAI, Tasty, and ephemeral PostgreSQL facilities. No new external package or compatibility workaround is planned. Before guessing at a dependency API, use Mori with the connection string in Concrete Steps to locate and read its source/documentation. If dependency bounds or pins become necessary, verify the current registry release and upstream tags before choosing them. Cross-repository durable references must use canonical Mori URIs; repository-local source paths remain relative.
