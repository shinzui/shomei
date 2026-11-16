# OAuth executable contract

From the repository root run `nix develop --command just test-oauth-contract`.
The runner builds the server and supplies `SHOMEI_TEST_SERVER_BIN`. The ordinary server test
suite also resolves the already built executable through `cabal list-bin`; build it before
running the suite directly. Missing Hurl or an executable is an error.

The Haskell fixture creates an isolated migrated PostgreSQL database, seeds one public client,
writes private typed Dhall configuration and a generated oversized form in a temporary directory,
and starts a loopback child process with test-only signing material. It brackets the exact child
process and waits for shutdown before releasing the database and files. Readiness and Hurl have
30-second bounds. It does not accept a deployment database or external HTTP target.

`errors.hurl` runs normal challenge, body, routing and negotiation assertions plus an application
problem-document control. `throttling.hurl` runs against a separate server lifetime with burst one
and one token per minute, so earlier tests cannot exhaust its bucket. The Hurl variables are
`base_url`, `client_id` and the valid public-client PKCE `challenge`; `--file-root` supplies the
generated `oversized.form`. These fixtures issue no tokens or account mutations and are repeatable.
All sensitive setup values remain in the temporary fixture. Detailed session permutations and
chunk accounting stay in Haskell tests.
