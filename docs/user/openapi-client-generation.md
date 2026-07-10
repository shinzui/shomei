# Generating API Clients (OpenAPI 3.1)

Shōmei publishes a machine-readable description of its HTTP contract as an
**OpenAPI 3.1** document. It is generated *directly from the Servant API type*
(`ShomeiRoutes` in `shomei-servant/src/Shomei/Servant/API.hs`), so it cannot drift
from the running server. Point any standard OpenAPI code generator at it to get a
typed client in your language — no Haskell toolchain required.

Two ways to get it:

- **From a running server**: `GET /openapi.json` describes the binary that is
  answering. Prefer this when generating a client against a specific deployment.
- **From the repository**: the committed [`docs/api/openapi.json`](../api/openapi.json).

For the same build the two are identical.

## Where the schema lives and how to regenerate it

Regenerate the committed artifact from source with:

```bash
cabal run shomei-openapi > docs/api/openapi.json
```

The generator (`shomei-openapi`, defined in `shomei-servant`) is deterministic:
re-running it produces byte-identical output, so a non-empty `git diff` on
`docs/api/openapi.json` means the API or a DTO actually changed. A conformance
test (`cabal test shomei-servant`) checks that every DTO's JSON encoding still
validates against its generated schema, that every documented error code exists in
the server's runtime error catalog at the documented status, and that the document
keeps the hygiene properties generated clients depend on.

Each route gets a stable `operationId` derived from its method and path (e.g.
`GET /v1/auth/me` → `getAuthMe`, `POST /v1/auth/login` → `createAuthLogin`), which
becomes the method name in generated clients. The `v1` segment is deliberately
dropped from the id: an `operationId` names what an operation does, and folding the
version in would rename every generated method at each version bump. Authenticated
routes carry a `bearerAuth` security requirement; `components.securitySchemes.bearerAuth`
describes an HTTP bearer (JWT) scheme. Supply your access token as the bearer
credential (`Authorization: Bearer <accessToken>`), exactly as the
[HTTP API guide](api.md) describes.

## Errors in the generated client

Every error response references the `Problem` schema (RFC 7807) with
`Content-Type: application/problem+json`, and narrows it to the codes that operation
can actually return:

```json
{
  "401": {
    "description": "An RFC 7807 problem document. The `code` member is one of: missing_token, token_invalid.",
    "content": {
      "application/problem+json": {
        "schema": {
          "allOf": [{"$ref": "#/components/schemas/Problem"}],
          "properties": {"code": {"type": "string", "enum": ["missing_token", "token_invalid"]}}
        }
      }
    }
  }
}
```

Generators that understand `enum` will give you a closed set of error codes per
operation rather than an opaque string. Switch on `code`; see [Errors](api.md#errors).

## Token transport and generated clients

The schema describes **all three** token transports, so `TokenPairResponse.accessToken` and
`.refreshToken` are **optional** — a cookie-transport server omits them (only `expiresIn` is
required). Generated clients therefore type them as nullable (`accessToken?: string` in
TypeScript, `Optional[str]` in Python). A **bearer** deployment — the default — always populates
them, so unwrapping is safe there; write the null check anyway if your client might point at a
cookie-mode server.

`RefreshRequest.refreshToken` is likewise optional, because cookie clients post `{}` and let the
`shomei_refresh` cookie carry the token.

One thing the document under-describes, inherent to OpenAPI: cookie-issuing responses list
**one** `Set-Cookie` header, because OpenAPI keys response headers by name. The server always
sends two (`shomei_session` and `shomei_refresh`).

If you use cookie transport from a browser, your generated client must send credentials with each
request (`fetch(..., { credentials: "include" })`) and an allow-listed `Origin` on every mutating
call, or the server answers `403` with `code: "csrf_rejected"`. See
[Token transport](api.md#token-transport).

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
