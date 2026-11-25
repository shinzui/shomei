# Bundle Update Log

## 2026-11-25
* **Addition**: FRIC-9 records detour documentation friction with mori://shinzui/shomei/plans/76-expose-session-kind-through-oauth-token-introspection: Plan 76 omitted the packaged server test prerequisite

## 2026-11-16

* **Update**: FRIC-8 accepted: Accept the local registry outage for this documentation and regression-only plan.


* **Addition**: FRIC-8 records detour environment friction with mori://shinzui/mori: Mori registry requires an unavailable local PostgreSQL service


* **Update**: FRIC-7 accepted: Accept a narrowly scoped http-client internal manager override until a per-request retry API exists.


* **Addition**: FRIC-7 records detour interface friction with mori://snoyberg/http-client/packages/http-client: HTTP manager retries can replay destructive recovery requests


* **Update**: FRIC-6 resolved: Resolve the extra-wrapper mismatch encountered during browser acceptance.


* **Addition**: FRIC-6 records detour interface friction with mori://shinzui/shomei: Passkey demo assumes an extra publicKey wrapper


* **Update**: FRIC-5 resolved: Removed the stale fork pin and mirrored the root narrow time relaxation; the required embedding build succeeds.

* **Addition**: FRIC-5 records detour tooling friction with mori://shinzui/shomei: Separate embedding project retained an obsolete WebAuthn pin

## 2026-11-05
* **Update**: FRIC-4 accepted: Accept the managed local pool while released migration and harness packages require the older driver generation.
* **Update**: FRIC-3 accepted: Accept the tested server deadline workaround; the upstream cleanup ordering remains.
* **Addition**: FRIC-4 records detour interface friction with mori://hasql/hasql/packages/hasql-pool: Released pool cancellation fix requires an incompatible driver generation
* **Update**: FRIC-3 logged: Verified authoritative current registry and release source; changing to the latest major release would not remove the cleanup limitation.
* **Addition**: FRIC-3 records detour interface friction with mori://hasql/hasql/packages/hasql: Hasql interruption cleanup drains blocked results before cancellation
* **Update**: FRIC-2 resolved: Select the released build fix verified against Hackage source and upstream history.
* **Update**: FRIC-1 accepted: The capped-concurrency PostgreSQL suite passed; retain the reproducible command in plan evidence.
* **Addition**: FRIC-2 records detour tooling friction with https://github.com/haskell-github-trust/smtp-mail: SMTP dependency no longer builds with current network
* **Addition**: FRIC-1 records detour environment friction with mori://shinzui/shomei: Default test parallelism exhausts ephemeral PostgreSQL startup
* **Adoption**: Adopt the `friction-log` profile (`coordination.frictionLog`) from https://raw.githubusercontent.com/shinzui/okf-profiles/v0.23.0/package.dhall.
