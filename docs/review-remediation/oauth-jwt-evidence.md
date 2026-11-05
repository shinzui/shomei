# OAuth and JWT acceptance evidence

Implementation checkpoints: `4fea508` and `2472483`. The final code checkpoint passed
`cabal test shomei-servant shomei-jwt shomei-server microservice-auth-stack --test-show-details=failures --test-options=-j2 -j1`
(all eight suites); core also passed the preceding full core/JWT/HTTP/server/downstream gate.
`cabal build example-project-service -j1` passed. Starting that executable with
`DOWNSTREAM_MAX_TOKEN_LIFETIME_SECONDS=0` exited 1 naming the invalid policy before any JWKS fetch.
Configuration/schema parity, strict ADR and inventory checks passed. Runtime residual policies
and the bounded rollout/rollback procedure are in [token compatibility](../user/token-compatibility.md).

| Ledger clauses | Exact evidence in the tested tree | Result and residual |
|---|---|---|
| REV-2.23.1 | JWT `Sign/JwtSpec.hs`, `Verify/JwtSpec.hs`; server E2E token-exchange scenario in both emitter modes; downstream HTTP actor tests | Object and finite-window strings preserve actor/subject; malformed actors fail closed. Single actor only; no chains. |
| REV-2.23.2 | Core `OAuth/TokenGrant/WorkflowSpec.hs` PKCE alphabet/length tests, including matching digests for malformed verifiers | Legal boundaries accepted; invalid verifiers refused before hashing. |
| REV-3.7.1, REV-3.7.2 | JWT tests `rejects a string-valued roles claim as malformed`, `rejects a multi-element audience even when one value matches` | Strict list shapes and exactly one audience. |
| REV-3.7.3 | JWT finite-lifetime tests in `Verify/JwtSpec.hs`; downstream HTTP lifetime test | Positive exp–iat must fit mandatory finite policy, independent of skew. |
| REV-3.7.4 | JWT `drops nbf and jti from the extension claim bag`; signer raw-extension regression | Hosts cannot inject reserved keys. |
| REV-3.9.1, REV-3.9.3 | JWT `Key/JwtSpec.hs` public projection and `Rotation/JwtSpec.hs` JWKS metadata tests | Generated JWKS advertises alg; missing public projection is an error. |
| REV-3.9.2 | ADR-3 and token compatibility guide | Existing decision verified: sid is session/correlation identity; no per-access-token jti or revocation promise. |
| REV-7.13.1, REV-7.16.6 | Core shared bearer syntax tests; HTTP bearer/cookie scenarios; downstream HTTP mixed-case/spacing tests | Case-insensitive scheme with valid b64token and ASCII spaces; malformed/duplicate headers refused. |
| REV-7.13.2 | HTTP OAuth client credentials scenario with encoded `+`, colon, percent and malformed percent input | Form decode exactly once, reject bad escapes before decoding. |
| REV-7.13.3 | [OIDC trusted-client policy](../user/oidc.md), Authorization workflow and HTTP authorize scenarios | Existing decision verified: operator registers only trusted clients; headless issuer has no consent UI. |
| REV-7.13.4, REV-7.13.5, REV-7.13.6 | HTTP `scenarioOidcDiscoveryEnabled`, introspection scenario without hint, OAuth missing-credential assertions | Discovery advertises exchange; refresh introspection finds opaque tokens; missing credentials get Bearer challenge. |
| REV-7.13.7 | Token compatibility guide and typed capture tests | Existing decision verified: syntax-only HTTP 400 may precede authentication, with no resource lookup. |
| REV-7.16.1, REV-7.16.2, REV-7.16.3 | HTTP `scenarioCsrfMatrix`, including direct AuthHandler HEAD/OPTIONS assertions | null/foreign origins refused, foreign Origin cannot use allowed Referer; safe methods authenticate without CSRF origin. |
| REV-7.16.4 | Core bespoke-refresh regression and HTTP client-bound refresh scenario | OAuth token cannot refresh through bespoke endpoint. |
| REV-7.16.5 | HTTP `scenarioRevokeOwnership` | Cross-client revoke refused; privileged admin behavior retained. |
| REV-7.16.7, REV-10.7.2 | HTTP hostile-header scenario and downstream HTTP authorization tests | Invalid UTF-8 yields typed 401, never an exception. |
| REV-7.16.8 | Server middleware real chunked-body limit test | Actual streamed body is capped. |
| REV-7.16.9 | HTTP authorize parameter error scenario | Plain PKCE is refused. |
| REV-7.16.10 | HTTP UserInfo scope matrix | Email/profile claims require their scopes. |
| REV-7.16.11 | HTTP freshness-after-refresh scenario | Refresh preserves proof time; stale proof cannot bypass step-up. |
| REV-10.7.3 | Downstream HTTP missing/invalid credentials and challenge assertions | Missing credential differs from invalid_token challenge, both 401. |
| REV-10.7.4 | JWT skew/algorithm tests and downstream verified settings | Explicit skew, supported algorithms and finite lifetime; existing typ-less compatibility remains separate. |

REV-3.7, REV-3.9, REV-7.13 and REV-7.16 close by all their clauses above. REV-2.23 remains
open until the independently owned clone-warning and historical compatibility clauses close.
