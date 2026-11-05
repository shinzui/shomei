---
okf_version: "0.2"
---

# Files

- [profile.dhall](profile.dhall)

# Friction Entry

- [Default test parallelism exhausts ephemeral PostgreSQL startup](1-default-test-parallelism-exhausts-ephemeral-postgresql-startup.md) - The PostgreSQL suite inherited all RTS capabilities and timed out nine ephemeral servers before tests could run.
- [SMTP dependency no longer builds with current network](2-smtp-dependency-no-longer-builds-with-current-network.md) - The existing SMTP release failed to compile after dependency resolution selected network 3.2.11.
- [Hasql interruption cleanup drains blocked results before cancellation](3-hasql-interruption-cleanup-drains-blocked-results-before-cancellation.md) - Hasql cancellation cleanup forced statement-level server deadline enforcement after repeated 30-second lock waits.
- [Released pool cancellation fix requires an incompatible driver generation](4-released-pool-cancellation-fix-requires-an-incompatible-driver-generation.md) - Repeated caller interruption lost pool capacity and the released fix requires a driver version excluded by the current migration and harness releases.
