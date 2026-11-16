# Bundle Update Log

## 2026-11-15
* **Update**: Set CAP-1 through CAP-24 `since` to the first tagged source snapshot, `0.1.0.0`,
  and distinguish source tags, Hackage candidates, and publication dates in the index.
* **Update**: CAP-1, CAP-3, and CAP-6 now describe atomicity as a shared port contract, including
  the in-memory interpreter's compare-and-swap and unit-of-work updates; CAP-1 lists 28 ports.
* **Update**: CAP-5 states the required signing-key KEK; CAP-9 lists all five combinators and
  their delegation behavior; CAP-14 explains authorization-code replay revocation; CAP-15
  lists the credential, MFA, and admin mutations refused under delegation.
* **Update**: CAP-17 explains that TOTP removal and recovery-code generation share the
  impersonation freshness window and measure credential proof time, not token issuance time.
* **Update**: CAP-21 explains that the master switch disables lockout, failure throttling, and
  request-rate limiting together; CAP-22 gives the actual readiness body and check names.

## 2026-09-05
* **Migrate**: Repin the shared `coordination.capabilities` profile to okf-profiles v0.13.1; the profile definition is unchanged, only its transitive OKF core import is newer.

## 2026-08-28
* **Update**: CAP-9: the embedded-with-en evidence entry now says the host guard is term-level; the combinators themselves are unchanged.

## 2026-08-27
* **Update**: CAP-22 now documents bounded metrics labels, monotonic timing, and timed single-flight readiness caching.
* **Update**: CAP-21 now documents trusted-proxy client attribution and metering for both declared and chunked request bodies.

## 2026-08-24
* **Addition**: Establish the capability bundle — CAP-1 through CAP-24 describe what Shōmei
provides today across its eight packages, each with its compatibility promise, the packages a
consumer depends on, evidence a reader can open, and a truthful `Limits` section.
* **Model**: Adopt the shared `coordination.capabilities` profile from
[okf-profiles v0.9.0](https://github.com/shinzui/okf-profiles), pinned by Dhall semantic hash
to match every other capability catalog in the portfolio. Provision claims only: absent
capabilities stay in the improvement-request bundle, the two-tier authorization story with
**en** is excluded as a composition claim, and there is deliberately no `planned` status.
* **Note**: Records were initially authored with `since: unreleased` and `stability: experimental`.
The source snapshot was subsequently tagged that day; the 2026-11-15 update reconciles `since`
with those tags. Stability remains experimental.
