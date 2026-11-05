# Runtime and operational acceptance evidence

Implementations: `2372a53` (cached OpenAPI), `a05b4e6` (shared host runtime), `9aa1972`
(downstream audit, diagnostics, CLI and key atomicity), `0dcd5ba` (transport warnings/proxy guide).
The nine-suite combined gate passed. Subsequent key/cancellation/file-failure changes passed
all server and downstream suites; the final warning changes passed the strict configuration suite.

```bash
cabal test shomei-servant shomei-client shomei-server microservice-auth-stack embedded-servant-app --test-show-details=failures --test-options=-j2 -j1
cabal test shomei-server microservice-auth-stack --test-show-details=failures --test-options=-j2 -j1
cabal test shomei-server:shomei-server-config-test --test-show-details=failures -j1
cabal build shomei-server embedded-servant-app -j1
sh deploy/entrypoint-test.sh
just adr-validate
python3 scripts/check-review-inventory.py
```

| Clause | Exact test / source / disposition |
|---|---|
| REV-7.14, EXTRA-3 | OpenAPI `serves the same JSON object directly and reuses its serialized bytes`; `measures 1000 render allocations against the uncached Value renderer`; HTTP `OpenAPI HTTP responses reuse the exact JSON document and media type`. Same schema and exact JSON body/media type, one shared forced representation. [Allocation result](openapi-allocations.txt): ~2.95 GB cumulative uncached allocations versus 32 KB cached for 1000 renderer calls. This is allocation work, not RSS or a latency promise. |
| REV-8.17.1 | Admin `generate→activate→(generate→activate auto-retires)→overlap verifies→revoke breaks it` and `key activation and rewrap roll back every write on an injected later failure`. Activation locks/revalidates the pending row inside the bounded transaction, then retires/promotes at one timestamp. A later trigger failure preserves all original statuses/timestamps. ADR-4 and ADR-23. |
| REV-8.17.2 | Admin `keys rewrap moves rows from the old KEK to the new one`, `keys rewrap with a wrong old KEK modifies no rows`, and the injected later-failure test above. The sequence proves the second write was reached; all original envelopes still match and only the old KEK opens them after rollback. Encryption occurs before the bounded database-only transaction. |
| REV-8.17.3 | Admin `key material loader rejects multiple active keys even after index bypass`; throwaway database removes the unique index, marks two valid rows active, and the real loader returns its invariant error. ADR-4. |
| REV-8.17.4 | Admin `audit reader returns published events; type filter + count work`: canonical TypeID and UUID user/session filters yield the same UUID query, the real reader returns one matching event, and NDJSON output contains canonical user/session TypeIDs. Event IDs remain UUIDs by their existing contract. |
| REV-8.17.5 | Server `request severity distinguishes 5xx, throttle and ordinary authentication failures`: error for 500/503, warn for 429, info for 200/401/403; the request logger uses that selector. Deployment guide explains attacker-triggered authentication failures. |
| REV-8.17.6 | Server `HIBP dependency failures expose only a bounded reason code` and `HIBP cancellation propagates instead of becoming an unavailable lookup`. An injected query error contains prefix, suffix, password, URL/query secret; the report is only the fixed transport reason. Existing fail-open/closed policy remains. |
| REV-8.17.7 | Admin `database errors retain only category and SQLSTATE`: injected connection secret, SQL, encrypted parameter and primary server message do not survive summarization. All CLI key failures use that formatter. |
| REV-8.17.8 | `deploy/entrypoint-test.sh` uses an admin stub that fails on any call; all entrypoint cases pass. The entrypoint delegates migration/key initialization to shared `buildEnv`. pg-migrate's serialized idempotent boot migration remains in shared standalone/embedded assembly; ADR-17. |
| REV-8.17.9 | Real-socket server tests: `admission rejects surplus sockets without leaking permits on rejection, disconnect or handler exception`; `explicit slow-client timeout releases an idle connection and shutdown releases shared capacity`; `shutdown with an admitted socket restores permits for a new listener`; `invalid direct-library host policies fail before serving`. Cap 1 tests reject repeated surplus sockets and admit again after every release path. Default cap 1024, timeout 30s, positive/representable configuration, shared standalone/embedded function; ADR-17. |
| REV-8.17.10 | Configuration suite checks default `*4`, Dhall `127.0.0.1`, environment `::1` override, and full FileConfig/Dhall parity. `hostWarpSettings` applies Warp's public setHost setter and is used by standalone and both embedded executables. Existing all-IPv4 default is preserved and documented. |
| REV-10.6 | Downstream `durable downstream audit preserves verified identities and fails closed on storage errors`: ordinary plus legacy/object delegated tokens; distinct actor and subject; rejected tokens have no unverified identity; action/resource/result/time/correlation; 32 concurrent requests produce 36 intact complete JSON lines including setup requests, mode 0600, no bearer/password material. Injected sink failures and actual invalid file storage return 503 with a constant secret-free body. Runnable service flushes/fsyncs per append; ADR-26 and README state single-process ownership, rotation, forwarding and storage limits. |
| REV-10.7.1 | HTTP version-boundary scenario asserts `public, max-age=300` on JWKS. Downstream `Cache-Control max-age overrides the configured TTL` and `max-age is clamped and max-age=0 does not loop` pass. Service Haddock and README now describe the actual publisher header and local hard ceiling. |
| REV-8.17 | Every owned leaf above is terminal. |

The plan's cross-check of REV-8 §§11/12 also passes the configuration tests
`notifierSecretsAreStrippedAndConfigIsSecretFree` and `notifierInsecureTransportFlags`: both
notifier secrets and the database string strip whitespace; SMTP plaintext credentials and HTTP
webhooks require explicit lab flags and emit fixed secret-free warnings (including non-loopback
HTTP). The notification guide documents inherited http_proxy/https_proxy/no_proxy from the
Mori-located dependency source. EP-7 retains ownership of those historical ledger rows.

No new risk exception is used. A file audit and a future business database do not form one atomic
transaction. Compatibility verification-only builders provide no durable audit guarantee; the
runnable executable always injects the file sink. Connection admission is separate from request,
hashing, pool and per-client proxy limits; idle clients can occupy slots until timeout. These
limits are stated in ADR-17/ADR-26 and the public guides.
