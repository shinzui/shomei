# Bundle Update Log

## 2026-11-05
* **Addition**: FRIC-4 records detour interface friction with mori://hasql/hasql/packages/hasql-pool: Released pool cancellation fix requires an incompatible driver generation
* **Update**: FRIC-3 logged: Verified authoritative current registry and release source; changing to the latest major release would not remove the cleanup limitation.
* **Addition**: FRIC-3 records detour interface friction with mori://hasql/hasql/packages/hasql: Hasql interruption cleanup drains blocked results before cancellation
* **Update**: FRIC-2 resolved: Select the released build fix verified against Hackage source and upstream history.
* **Update**: FRIC-1 accepted: The capped-concurrency PostgreSQL suite passed; retain the reproducible command in plan evidence.
* **Addition**: FRIC-2 records detour tooling friction with https://github.com/haskell-github-trust/smtp-mail: SMTP dependency no longer builds with current network
* **Addition**: FRIC-1 records detour environment friction with mori://shinzui/shomei: Default test parallelism exhausts ephemeral PostgreSQL startup
* **Adoption**: Adopt the `friction-log` profile (`coordination.frictionLog`) from https://raw.githubusercontent.com/shinzui/okf-profiles/v0.23.0/package.dhall.
