# Database acceptance evidence

Tested implementation: `9c095e6`, including bounded transaction and pool changes from
`f039373` and `ab922c0`. All eight suites in the following gate passed. The final PostgreSQL
rerun includes the SQL-barrier sweep test, logout audit assertion and migration 0042.

```bash
cabal test shomei-core shomei-postgres shomei-servant shomei-server --test-show-details=failures --test-options=-j2 -j1
just migration-check
just adr-validate
python3 scripts/check-review-inventory.py
```

| Clauses | Exact PostgreSQL test / accepted evidence |
|---|---|
| REV-2.20.1 | `logout costs exactly 2 database round-trips`: logout then refresh returns SessionRevoked, one session-revoked event and zero reuse-detection events. `real refresh workflow race rotates once and treats the losing proof as theft`: two readers observe active proof before racing, one rotation, one reuse detection, entire family revoked, zero generic session-revoked events. |
| REV-5.10.1 | `create session + revoke`: a second revoke at a later timestamp preserves the first revoked_at. |
| REV-5.10.2, REV-5.10.3, REV-5.10.4 | `user and credential timestamps follow Clock; password tails share their transaction timestamp`: frozen creation times, user update, direct hash update, change and reset tails use their selected timestamp despite a different ambient Clock. ADR-7 defines the contract. |
| REV-5.10.5 | `authorization codes: consume once, replay misses, expiry misses` runs the bounded sweeper with batch size 1 and asserts two expired codes removed. The unused unbatched expiry operation and both interpreters are removed. |
| REV-5.12.1 | `real refresh workflow race rotates once and treats the losing proof as theft`: actual workflow with a read barrier, persisted family, session and audit assertions. |
| REV-5.12.2 | `real reset and verification workflows each consume once and audit one winner`: eight readers at each barrier, one success and seven typed failures, exactly one completion event each. |
| REV-5.12.3, REV-5.12.4 | `real recovery-code and pending-ceremony consume races have one persisted winner`: eight consumers, one used recovery code and one consumed ceremony; verify persisted state. |
| REV-5.12.5 | `totp counter: eight racing updates have one winner` and `passkey counter: eight racing nonzero updates have one winner`. Counterless compatibility has a separate PostgreSQL test. |
| REV-5.12.6 | `paced sweeper races a live refresh without deleting the rotation family`: a delete trigger waits at an observed SQL advisory-lock barrier while live rotation commits; ten expired sessions removed, live session and both family rows survive with one active child. |
| EXTRA-6 | `admin user and per-user audit pages use measured ordered indexes; small client catalog stays unindexed`. [Actual plans](admin-query-plans.txt): 10k users, 11k audit rows; user buffers 109→3, filtered users 109→4, per-user audit 205→4. A 40-client catalog uses one buffer/~0.01ms, so no catalog index is added. Migration 0042 adds only the measured ordered indexes. These are fixture measurements, not deployment latency guarantees. |

REV-2.20, REV-5.10 and REV-5.12 aggregate their now-terminal leaves. Earlier database lifecycle,
quota, retention and bulk/paging evidence remains pinned to `ab922c0` in the ledger. No new risk
exception is used. Index creation takes migration locks; schedule it using the existing migration
maintenance guidance. Password hashing remains outside database transactions. Cleanup retention
still depends on issuance rate, configured finite retention, and sweep lag (ADR-24).
