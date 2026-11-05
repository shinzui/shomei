# Bundle Update Log

## 2026-11-05
* **Update**: FRIC-2 resolved: Select the released build fix verified against Hackage source and upstream history.
* **Update**: FRIC-1 accepted: The capped-concurrency PostgreSQL suite passed; retain the reproducible command in plan evidence.
* **Addition**: FRIC-2 records detour tooling friction with https://github.com/haskell-github-trust/smtp-mail: SMTP dependency no longer builds with current network
* **Addition**: FRIC-1 records detour environment friction with mori://shinzui/shomei: Default test parallelism exhausts ephemeral PostgreSQL startup
* **Adoption**: Adopt the `friction-log` profile (`coordination.frictionLog`) from https://raw.githubusercontent.com/shinzui/okf-profiles/v0.23.0/package.dhall.
