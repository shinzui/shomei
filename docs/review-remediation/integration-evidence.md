# MasterPlan 9 integration evidence

Initial complete code gate: `ea5d942d4d0b56c891347bcd868bda1f2fbe0cc5` (2026-11-05).
The provenance follow-up `195f1143a4325064451dd0a1cbd51e5208fd53cd` passed core/PostgreSQL/migration suites and migration/ADR checks through 0043. Final combined candidate acceptance is recorded in the closure review.

## Functional and operational gates

From the repository root, the following passed at the initial code gate:

```bash
cabal build all
cabal test all --test-show-details=failures --test-options=-j2 -j1
just build-embedded-with-en
just migration-check
just adr-validate
just reviews-validate
okf validate docs/improvement-requests --profile docs/improvement-requests/profile.dhall --profile-enforce --log-enforce
dhall-to-json --file config/shomei.example.dhall
```

All 14 suites passed: embedded-servant-app, microservice-auth-stack, client, core, JWT,
PostgreSQL, Servant OpenAPI, Servant HTTP, admin, health, configuration, server,
WebAuthn and migrations. The separate en build compiles its library and executable from its
own project. Migration namespace checks and the manifest through 0042 passed; 0043 requires the
follow-up gate. No deployment database was used. Test logs were captured under
`/tmp/shomei-ep7-{full-build,full-tests,en-build,migration,adr,reviews,ir-enforced}.log`;
the durable receipt here records the results without reproducing generated credentials.

Actual compiled CLI checks passed: `users create --help` lists --password-file; obsolete
--password is rejected by the parser; empty stdin and /dev/null password-file fail before
database access. Admin policy/verified-bootstrap, core breached-password policy and injectable
HIBP diagnostic tests establish the configured workflow; no external HIBP query was needed.
The shipped Dhall example renders successfully, and the configuration suite checks its schema's
completed default against every FileConfig key, strict enums, ranges and environment precedence.

Strict improvement-request validation initially reported missing *recommended* `reviews`
provenance on IR-1 through IR-4. After IR-3 receives its actual implementation review entry,
the remaining warnings concern IR-1, IR-2 and IR-4. With --strict these warnings make exit status 1;
profile/log enforcement without --strict passes all four documents. No independent reviews were
invented to suppress the warnings. ADR and review strict enforcement pass. The closure adds an
actual implementation review reference to IR-3; unrelated request provenance remains unchanged.

## Reproducible fixed workloads

```bash
scripts/review-remediation-load.sh --scenario all --output /tmp/shomei-review-load.json
```

The manual `review-load` Cabal flag is enabled by this script only. Production builds keep the
ephemeral PostgreSQL harness and load executable disabled. There is no external URL or database
argument. The helper provisions a new database, binds an internal loopback listener, uses no
HTTP proxy or redirects, bounds requests at five seconds, uses four HTTP workers and stops the
whole run at 180 seconds. The separate Argon2 script also refuses non-loopback targets, authority
userinfo/path tricks and out-of-range workload sizes before starting. Shell syntax and those
refusal cases passed.

The host uses a pool of eight, 1024 admitted sockets, default Argon2id 65,536 KiB / three passes /
one lane, two hashing permits, two requested RTS capabilities and the nonmoving collector.
Rate limiting, request logging and metrics are disabled for the workload. Default middleware
and the real HTTP/core/PostgreSQL stack remain installed. JSON contains only whitelisted
configuration, numeric aggregates and static labels; passwords, tokens, cookies, database
connection strings and raw exceptions are never serialized. Static phase logs contain no fixture
credentials. Functional tests separately assert secret-negative diagnostics at each boundary.

| Measurement | Initial | Repeat | Final driver before commit |
|---|---:|---:|---:|
| Session fixture / revoked / audit events | 10000 / 10000 / 10000 | 10000 / 10000 / 10000 | 10000 / 10000 / 10000 |
| Page size / requests | 200 / 51 | 200 / 51 | 200 / 51 |
| Session page-and-revoke wall ms | 387.066 | 423.353 | 413.388 |
| OpenAPI responses / workers | 1000 / 4 | 1000 / 4 | 1000 / 4 |
| OpenAPI wall ms | 65.088 | 76.503 | 74.378 |
| OpenAPI RSS growth KiB after warmup | 6320 | 4240 | 5232 |
| Login workers / load seconds / probes | 4 / 10 / 100 | 4 / 10 / 100 | 4 / 10 / 100 |
| Login attempts / unexpected HTTP errors | 209 / 0 | 197 / 0 | 201 / 0 |
| Idle / loaded probe p50 ms | 1.08 / 48.28 | 1.20 / 50.35 | 1.28 / 53.28 |
| Loaded probe p95 / p99 ms | 112.98 / 175.96 | 119.05 / 171.00 | 124.49 / 188.32 |
| Argon2 process peak RSS KiB | 207008 | 205040 | 205936 |

Raw aggregate receipts: [initial](load-initial.json), [repeat](load-repeat.json),
[final driver](load-final.json). The initial exploratory driver allowed 128 MiB RSS growth;
repeat/final enforce 32 MiB. The final driver also asserts disjoint session pages and explicitly
reports 70 expected preflight 401 responses; these intentional failures are separate from
unexpected workload errors. The initial bulk counter's name was corrected to
`bulk_unit_of_work_contract_calls`: it is one source-level audited unit-of-work dispatch,
not a measured physical-wire query counter. Earlier reports are preserved rather than rewritten.

The RSS observer and load generator share the server process. RSS includes allocator/collector
noise and client buffers, so fixed limits detect obvious retained document copies, not a proof
of steady-state memory behavior for arbitrary duration. All 1,000 bodies equal the shared cached
104,380-byte document. Four post-GC RSS samples show bounded growth for this fixed input. The 51st
session page is the existing empty terminal page when the previous page exactly fills its limit.

## Baselines and interpretation

The original `ee00382509c6cf4b3db2a3c87ff0bd029932c770` admin workflow reads every session,
then separately revokes and audits each active row. With 10,000 rows that is an application list
of 10,000 and 20,000 per-row effect dispatches after its read. Current HTTP listing returns at most
200 rows per page, and bulk revoke performs one audited SQL unit of work without transferring
10,000 rows to the application. It still necessarily updates and audits 10,000 database rows;
no constant database CPU/storage cost is claimed. PostgreSQL tests prove all-or-nothing audit,
one winner per session under eight racers and rollback after injected failure.

The former OpenAPI Value encoder runs per response. The same-candidate allocation comparison
executes 1,000 real renderer invocations: 2,945,392,000 cumulative allocated bytes for uncached
encoding versus 32,000 for shared bytes, with exact document equality. See
[allocation receipt](openapi-allocations.txt). This isolates repeated encoding without treating
HTTP wall time as a reliable before/after benchmark. Query-plan receipts separately record
representative sort/buffer reductions for measured indexes.

MasterPlan 6's older latency/RSS and low round-trip claims are explicitly historical. Its hardware,
RTS and workload are not identical to this run. The current logical database operation budgets are
10 successful-login, four wrong-password, five refresh, two logout and three reset confirmation;
they count Database interpreter dispatches, not network trips or statements within transactions.
The new driver reports current local latency and RSS without claiming an improvement over an
uncontrolled historical machine. Loaded probe medians are much higher than idle; the pass criteria
are bounded work, zero unexpected errors, finite duration and invariant outcomes, not deployment
latency SLOs. Hashing permit saturation tests prove the structural CPU/concurrency bound.

## Upgrade and failure fixtures

TOTP tests seed legacy pending/confirmed ciphertext, inspect versions without a key, convert
101 rows over multiple batches, resume idempotently, reject wrong key/tag/version, preserve changed
rows under a real CAS barrier, and complete actual MFA with the same secret before and after
conversion. The new runtime refuses remaining legacy rows. ADR-20 and mfa.md require a trusted
backup, stopped old hosts, offline conversion, version verification, then new hosts; old binaries
cannot read converted rows and rollback requires the compatible backup. Historical ciphertext
transplants cannot be detected retroactively.

Actor tests mint real legacy strings and new objects, exercise standalone verification,
introspection, downstream HTTP and durable actor/subject auditing, reject malformed actors and
cutoff-expired strings, and force object emission when legacy expiry plus skew would outlive the
read window. token-compatibility.md orders readers before object emission and keeps rollback
readers compatible. This verifies the application format contract with old/new fixtures, not a
production rolling deployment.

The final session-provenance fixture inserts a human, a service-account machine, a delegated actor
NULL provenance, and an unassociated session without a refresh-token record after the embedded 0042 schema, then runs actual additive 0043. It must prove
only the human remains interactive, unknown/omitted writes default safely and invalid kinds fail.
The core also refuses a stored actor even when the token omits act. That upgrade acceptance
supersedes the former assumption that every pre-0029 row was interactive.

## Final candidate receipt

At `1daf36ca2652e320c343754c84656688ab5af1d6`, the complete build, all 14 suites, separate en build, 43-migration manifest/namespace,
strict ADR/review/friction profiles, enforced improvement-request profile/log, closed inventory,
format check and diff check passed again. Logs are `/tmp/shomei-ep7-candidate-*.log`.
The candidate's isolated workload also passed; [aggregate result](load-candidate.json) records
10,000 revoked/audited sessions, 1,000 exact OpenAPI bodies, 6,272 KiB RSS growth (32,768 limit)
and 209 login attempts with zero unexpected HTTP errors in 18,016.481 ms.
The final metadata commit adds this receipt, closure records and the upgrade-order clarification
without changing tested code. [REV-12](../reviews/masterplan-9-remediation-closure.md) is the review of record.
