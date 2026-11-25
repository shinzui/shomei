# Bundle Update Log

## 2026-11-25

* **Update**: IR-2 was superseded by `mori://shinzui/kikan/okf/improvement-requests/concepts/IR-3`, which carries the diagnostic admission and conformance requirements.

* **Update**: Complete IR-1 in the provider with authenticated session-kind introspection, PostgreSQL round trips and consumer route-policy evidence.


* **Update**: Generalized IR-1 and ExecPlan 76 to expose session kind to any authorized introspection caller. Hanmoto remains a consumer acceptance case.


* **Update**: Validated IR-1 against v0.3.0.1 and current source. OAuth covers scoped issuance. ExecPlan 76 tracks the remaining Hanmoto session-kind lookup and consumer proof.

* **Amendment**: IR-1 asks for the released Shomei profiles and verifier outputs
  for direct Hanmoto calls. The Kikan adapter uses verified credential
  identifiers for its Meibo directory lookup.

## 2026-11-17
* **Update**: Complete IR-5: v0.3.0.1 publishes shomei-core, shomei-servant, shomei-server and shomei-client 0.3.0.1 with the widened base64 bound; a Hackage-only base64 2.0 consumer solve needs no allow-newer.
* **Update**: Start IR-5: widen base64 to `>=1.0 && <2.2` in the four packages that declare it, verified on base64 2.0 and 2.1; patch release `v0.3.0.1` cut from `v0.3.0.0`.
* **Addition**: Add IR-5 to admit base64 2.0 in shomei-core, from Rei ExecPlan 292 where the frozen cohort resolves base64 2.0 through tls.

## 2026-11-05
* **Update**: Complete IR-3 with REV-12 and the 240-row closed ledger; record actual implementation review provenance and final candidate acceptance.

## 2026-11-01
* **Update**: Reject IR-4: a fix that keeps the strict reuse-detection contract was found; the analysed design stays in the withdrawn ExecPlan 69.
* **Addition**: Add IR-4 to stop revoking sessions when a rotated refresh token never reached the client, from sign-outs observed on mori://tan/tan-ng-labs.

## 2026-10-28
* **Update**: Link IR-3 to MasterPlan 9, its seven child ExecPlans, and the finding ledger; implementation remains open.
* **Addition**: Add IR-3 to track residual security, performance, interoperability, and test-coverage findings from REV-11.

## 2026-09-05
* **Migrate**: Repin the shared `coordination.improvement-requests` profile to okf-profiles v0.13.1; the pinned Dhall semantic hash is unchanged from v0.12.0.

## 2026-08-24
* **Migrate**: Adopt OKF v0.2: add `generated` provenance to IR-1 and IR-2, declare `okf_version: "0.2"` in a generated index, and repin the profile to okf-profiles v0.12.0.

## 2026-07-30
* **Migrate**: Assign stable handles to Shomei improvement requests.
* **Move**: Accept the diagnostic identity-and-scope request from Kikan as `IR-2`.
