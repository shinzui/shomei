# Generating API Clients (OpenAPI 3.1)

Shōmei publishes a machine-readable description of its HTTP contract as an
**OpenAPI 3.1** document at [`docs/api/openapi.json`](../api/openapi.json). It is
generated *directly from the Servant API type* (`ShomeiAPI` in
`shomei-servant/src/Shomei/Servant/API.hs`), so it cannot drift from the running
server. Point any standard OpenAPI code generator at that file to get a typed
client in your language — no Haskell toolchain required.

## Where the schema lives and how to regenerate it

The committed artifact is `docs/api/openapi.json`. Regenerate it from source with:

```bash
cabal run shomei-openapi > docs/api/openapi.json
```

The generator (`shomei-openapi`, defined in `shomei-servant`) is deterministic:
re-running it produces byte-identical output, so a non-empty `git diff` on
`docs/api/openapi.json` means the API or a DTO actually changed. A conformance
test (`cabal test shomei-servant`) checks that every DTO's JSON encoding still
validates against its generated schema.

Each route gets a stable `operationId` derived from its method and path (e.g.
`GET /auth/me` → `getAuthMe`, `POST /auth/login` → `createAuthLogin`), which
becomes the method name in generated clients. Authenticated routes carry a
`bearerAuth` security requirement; `components.securitySchemes.bearerAuth`
describes an HTTP bearer (JWT) scheme. Supply your access token as the bearer
credential (`Authorization: Bearer <accessToken>`), exactly as the
[HTTP API guide](api.md) describes.

## A note on OpenAPI 3.1

The document declares `"openapi": "3.1.0"`. Some older generators only support
3.0; use a **recent** generator release. The commands below were verified with
`@openapitools/openapi-generator-cli` 7.23.0 (which needs a Java runtime). If you
cannot run a 3.1-capable generator, downgrade tools accordingly or use a
JS-native 3.1 tool such as [`openapi-typescript`](https://github.com/openapi-ts/openapi-typescript).

## Codegen commands

All commands read the committed `docs/api/openapi.json`. Replace the output
directory as you like. Do **not** commit generated clients into this repo.

### TypeScript (fetch)

```bash
npx @openapitools/openapi-generator-cli generate \
  -i docs/api/openapi.json -g typescript-fetch -o ./shomei-ts-client
```

This emits one model per DTO plus an API class whose methods are the
`operationId`s above. The bearer token is supplied through the client
`Configuration`'s `accessToken` callback.

### Python

```bash
npx @openapitools/openapi-generator-cli generate \
  -i docs/api/openapi.json -g python -o ./shomei-py-client \
  --additional-properties=packageName=shomei_client
```

### Go

```bash
npx @openapitools/openapi-generator-cli generate \
  -i docs/api/openapi.json -g go -o ./shomei-go-client \
  --additional-properties=packageName=shomeiclient
```

Other languages (Rust, Java, C#, Kotlin, …) work the same way — swap the `-g`
generator name. See the [OpenAPI Generator](https://openapi-generator.tech/docs/generators/)
list for all supported targets.

## Using the spec interactively

You can also load `docs/api/openapi.json` into Swagger UI, Redoc, or any OpenAPI
viewer to browse the contract, or lint it with
[`vacuum`](https://quobix.com/vacuum/) /
[`@redocly/cli`](https://redocly.com/docs/cli/) before generating clients.
