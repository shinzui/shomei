# embedded-servant-app

This example mounts Shōmei's complete Servant API inside a host application and protects the
host-owned `GET /projects` route with the same verifier. It also installs the exported background
tasks and WAI middleware, so key reload, notification delivery, request limits, logging, and metrics
match the standalone server.

Run it from the repository dev shell after `just create-database`. Export one key-encryption key and
keep it for the life of that database; a different value cannot decrypt signing-key rows created by
the first boot.

```bash
export SHOMEI_KEY_ENCRYPTION_KEY=$(head -c 32 /dev/urandom | base64)
cd examples/embedded-servant-app
cabal run embedded-servant-app
```

Open <http://localhost:8080/index.html> for the browser demo. See [`www/README.md`](www/README.md)
for the walkthrough and [`docs/user/passkeys.md`](../../docs/user/passkeys.md) for the passkey model.
