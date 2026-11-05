# Authentication input limits

New login IDs and display names accept at most 256 Unicode code points, passkey labels and
role/scope names at most 128. Email addresses accept at most 254 UTF-8 bytes. New identity
values must fit both before and after normalization. Accepted character vocabularies remain
unchanged. Passwords accept at most 256 code points; the configured password policy can be
stricter. Values are never truncated.

An oversized login password returns HTTP 400 (`weak_password`) before account lookup, password
hashing or proof accounting. It creates no login attempt, lockout or audit event. The edge
request throttle still applies. Normal-sized invalid proofs retain the usual abuse accounting.

Existing oversized login IDs remain usable for password login, and existing email addresses
remain usable for password-reset and verification lookup. Persisted user, credential and audit
snapshots remain readable. Existing labels remain listable and removable. New writes are
bounded in the workflows and PostgreSQL; unchanged legacy values do not block status changes,
password resets, counters or other security updates.

Before upgrading, run this report against the deployment database with a read-only role:

```bash
psql "$SHOMEI_DATABASE_URL" -v ON_ERROR_STOP=1 -f scripts/report-legacy-input-sizes.sql
```

The report uses a read-only transaction and returns counts only. It does not alter or print
identities. Keep legacy identities; do not rename or truncate them to satisfy new-write limits.
If a legacy password exceeds 256 code points, use the normal emailed password-reset flow to
choose a new password. An account without a recovery email needs the deployment's existing
account-recovery process; no privileged password truncation or bypass is introduced.

Compatibility constructors are for authentication and snapshot decoding only. Library callers
must use `mkLoginId`, `mkEmail`, and `validateNewUser` for new values. Signup revalidates inputs
so a compatibility value cannot bypass new-write policy. Raw persistence effects remain the
migration/testing seam; production PostgreSQL independently enforces new/changed field sizes.

Migration 0039 is additive. Code rollback preserves the migration and its new-write limits;
legacy rows continue to support unrelated updates. See [ADR-22](../adr/0022-new-input-budgets-preserve-legacy-authentication.md).
