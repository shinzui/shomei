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
- [Separate embedding project retained an obsolete WebAuthn pin](5-separate-embedding-project-retained-an-obsolete-webauthn-pin.md) - The separately solved en embedding project retained a fork pin incompatible with the current Shomei library, blocking the required embedding build.
- [Passkey demo assumes an extra publicKey wrapper](6-passkey-demo-assumes-an-extra-publickey-wrapper.md) - The demo and browser-check instructions expected options.publicKey although HTTP begin responses contain the creation or request options directly.
- [HTTP manager retries can replay destructive recovery requests](7-http-manager-retries-can-replay-destructive-recovery-requests.md) - The HTTP client retry policy belongs to the manager and can replay POST after an ambiguous reused-connection failure, requiring request-local isolation.
- [Mori registry requires an unavailable local PostgreSQL service](8-mori-registry-requires-an-unavailable-local-postgresql-service.md) - Registry discovery failed because the local Sungkyung PostgreSQL socket refused connections.
- [Plan 76 omitted the packaged server test prerequisite](9-plan-76-omitted-the-packaged-server-test-prerequisite.md) - The validation commands ran the PostgreSQL cases but failed the packaged OAuth check on a checkout without a built server executable.
