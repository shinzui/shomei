# Bundle Update Log

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
