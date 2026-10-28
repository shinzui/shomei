---
type: Improvement Request
title: Close residual findings from the August security and performance reviews
description: Give every residual review subitem a fix with evidence or an explicit documented disposition.
timestamp: "2026-10-28T18:06:42Z"
generated:
  by: process:codex
  at: "2026-10-28T18:06:42Z"
requestId: IR-3
status: proposed
origin: mori://shinzui/shomei/okf/reviews/concepts/REV-11
---

# Close residual review findings

[REV-11](../reviews/remediation-completeness-audit.md) records the source evidence
and original finding identifiers. This request owns the remaining work without
reopening the already implemented major remediations.

Implementation is planned in [MasterPlan 9](../masterplans/9-close-all-security-and-performance-review-findings.md),
with seven child ExecPlans and a [finding ledger](../review-remediation/findings.md).
The work remains open; plan creation does not satisfy acceptance.

## Required outcomes

- Version, bind, and migrate TOTP ciphertext; test cross-row transplant rejection
  and upgrades without an indefinite unbound fallback.
- Define field-size and passkey-count budgets, covering domain and JSON callers,
  login password handling, and compatibility with existing stored identifiers.
- Validate PKCE verifier length/alphabet, including invalid inputs whose digest
  otherwise matches the stored challenge.
- Bound transaction retries and test repeated retryable failures and cleanup.
- Cache OpenAPI bytes; verify equivalent responses without repeated encoding.
- Explain direct-attestation limitations and add signed WebAuthn ceremony tests.
- Bound session enumeration, bulk revocation, and machine/delegated session growth.
- Demonstrate delegated-action auditing in the downstream example or record an
  explicit disposition of its omission.
- Resolve remaining actor claim, bearer parsing, JWT lifetime/correlation,
  credential timestamp, clock-port, and unbatched-expiry observations.
- Reconcile every remaining subitem in REV-5 §12, REV-7 §§13,16, and REV-8 §17,
  including tests, CLI consistency, logging, and connection/admission policy.

## Acceptance

Every original numbered finding and unnumbered performance observation has a fix
and named regression evidence, an existing explicit disposition, or an honestly
open tracking item. Body caps are not field limits, statement timeouts are not
retry budgets, and begin-option tests are not signed-ceremony tests. Preserve
the original commit-pinned reviews; record closure against a newly tested commit.
