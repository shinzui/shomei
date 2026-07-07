---
id: 31
slug: complete-cookie-token-transport-with-csrf-defenses
title: "Complete Cookie Token Transport with CSRF Defenses"
kind: exec-plan
created_at: 2026-07-07T17:22:22Z
master_plan: "docs/masterplans/5-security-correctness-hardening-make-existing-guarantees-hold.md"
---

# Complete Cookie Token Transport with CSRF Defenses

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

Shōmei authenticates HTTP requests with a bearer token (`Authorization: Bearer <jwt>`).
For browser applications, an alternative transport exists in half-built form: an
**HttpOnly cookie** — a cookie the browser attaches automatically and page JavaScript can
never read, which removes the token from XSS reach. The configuration enum
`TokenTransport` (`BearerToken | HttpOnlyCookie | BearerAndCookie` in
`shomei-core/src/Shomei/Config.hs`, parseable from `SHOMEI_TOKEN_TRANSPORT=bearer|cookie|both`)
suggests the feature is done. It is not, and the half that exists is the dangerous half:

- The **read** path is live *unconditionally*: `extractToken` in
  `shomei-servant/src/Shomei/Servant/Auth.hs` falls back to a `shomei_session` cookie for
  every authenticated route, in every deployment, regardless of the configured transport.
- The **write** path does not exist: no handler ever emits `Set-Cookie`, so the config
  enum is dead code.
- There is **no CSRF defense**. CSRF (cross-site request forgery) is the attack the cookie
  transport invites: because the browser attaches cookies automatically, a malicious page
  on another site can make the victim's browser send authenticated state-changing requests
  (logout, password change, passkey deletion) without reading any response. Bearer tokens
  are immune (a foreign page cannot set the header); cookies need explicit defenses.

The MasterPlan decision (2026-07-07) is to **complete** the feature rather than remove the
read path — removal remains the recorded fallback only if CSRF scope balloons. After this
plan, a deployment that sets `SHOMEI_TOKEN_TRANSPORT=cookie` gets a genuinely working,
browser-safe session flow: login/signup/refresh/MFA/passkey completions set `shomei_session`
(access token) and `shomei_refresh` (refresh token) cookies with `HttpOnly`, `Secure`,
configurable `SameSite` (default `Lax`), correct `Path` and `Max-Age`; token values are
omitted from JSON bodies in cookie-only mode; logout clears both cookies; the refresh
endpoint accepts the refresh token from its cookie; every cookie-authenticated **mutating**
request must present an allow-listed `Origin` (with `Referer` fallback) or is refused with
`403 csrf_rejected`; and — closing the review finding — `bearer` mode **stops accepting
cookies entirely**. Bearer behavior for existing deployments is byte-for-byte unchanged.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").

- [ ] M1: `CookieConfig` (+ `SameSitePolicy`) added to `ShomeiConfig` with defaults; env
      (`SHOMEI_COOKIE_SECURE`, `SHOMEI_COOKIE_SAMESITE`, `SHOMEI_CSRF_ALLOWED_ORIGINS`) and
      Dhall-file plumbing in `Shomei.Server.Config`.
- [ ] M1: `extractToken` made transport-aware and source-tagged (`FromBearer`/`FromCookie`);
      `BearerToken` mode no longer reads cookies; unit cases pass.
- [ ] M1: `authHandler` enforces the Origin/Referer CSRF gate for cookie-sourced
      credentials on mutating methods; `403 csrf_rejected` shape defined.
- [ ] M2: `Shomei.Servant.Cookie` helper module (build/clear/render cookies).
- [ ] M2: `Set-Cookie` emission wired into signup, login (complete arm only), refresh,
      mfaComplete, passkeyLoginComplete; clearing wired into logout; routes carry the
      response-header types; `TokenPairResponse`/`SignupResponse` token fields optional and
      omitted in cookie-only mode.
- [ ] M2: refresh accepts the refresh token from the `shomei_refresh` cookie (body takes
      precedence) and applies the CSRF gate when it does.
- [ ] M3: servant integration tests: cookie attributes, body omission, cookie auth
      round-trip, CSRF accept/reject matrix, bearer-mode cookie rejection, logout clearing,
      cookie refresh rotation.
- [ ] M4: `docs/user/api.md` + `docs/user/security.md` updated; OpenAPI spec regenerated
      (`cabal run shomei-openapi > docs/api/openapi.json`); live curl transcript captured.
- [ ] `cabal build all` / `cabal test all` green; living sections updated; Outcomes
      written.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

(None yet.)


## Decision Log

Record every decision made while working on the plan.

- Decision: Complete the cookie transport (MasterPlan decision restated); removal of the
  read path remains the fallback only if CSRF work balloons beyond this plan.
  Rationale: `TokenTransport` is documented, configurable public surface; retreating would
  break the documented contract, and the browser-security value (HttpOnly = XSS-proof
  token storage) is real.
  Date: 2026-07-07

- Decision: CSRF mechanism = **SameSite cookies (default `Lax`) + an Origin allow-list
  check with Referer fallback** on cookie-authenticated mutating requests. No double-submit
  token.
  Rationale: Shōmei's mutating surface is JSON-over-POST/DELETE APIs, not HTML forms.
  `SameSite=Lax` already stops browsers attaching the cookies to cross-site POSTs; the
  Origin check is the standards-track second layer (browsers always send `Origin` on
  cross-origin requests and on same-origin POSTs) that also covers old/quirky user agents
  and `SameSite=None` deployments. A double-submit token would require every client to run
  JavaScript that mirrors a token into a header — more moving parts, client-side changes,
  and a worse fit for an auth *toolkit* whose embedders have varied frontends. If an
  embedder needs double-submit later it can be layered on without breaking this design.
  Date: 2026-07-07

- Decision: The CSRF gate applies **only** when the credential came from a cookie and only
  to non-safe methods (everything except GET/HEAD/OPTIONS). A cookie-authenticated
  mutating request with *neither* `Origin` nor `Referer` is **rejected**.
  Rationale: bearer credentials cannot be attached cross-site by a browser, so gating them
  adds friction with zero security (and would break curl/native/service-token callers).
  Safe methods don't mutate. Browsers reliably send `Origin` on the requests that matter;
  a headerless mutating request bearing only a cookie is either a non-browser client that
  should be using bearer, or an attack — fail closed.
  Date: 2026-07-07

- Decision: Read-path semantics per transport: `BearerToken` → Authorization header only
  (cookie fallback removed); `HttpOnlyCookie` and `BearerAndCookie` → bearer first, then
  cookie.
  Rationale: bearer must stay accepted in all modes because it is CSRF-immune and is how
  non-browser callers (services, CLIs, the service-token flow) authenticate even in
  cookie deployments. What `HttpOnlyCookie` vs `BearerAndCookie` governs is the *response*
  side: cookie-only omits tokens from JSON bodies (XSS cannot exfiltrate what the body
  never contains); `both` sets cookies *and* returns body tokens for transitional clients.
  Date: 2026-07-07

- Decision: Two cookies — `shomei_session` (access token, `Path=/`, `Max-Age` =
  `accessTokenTTL`) and `shomei_refresh` (refresh token, `Path=/auth/refresh`, `Max-Age` =
  `refreshTokenTTL`) — i.e. cookie transport *does* move the refresh token into a cookie.
  Rationale: keeping the refresh token in the JSON body in cookie mode would defeat the
  point (JS-readable long-lived credential). Scoping `shomei_refresh` to
  `Path=/auth/refresh` means the browser presents the long-lived secret to exactly one
  endpoint, shrinking exposure. The name `shomei_session` is kept because the read path
  already uses it.
  Date: 2026-07-07

- Decision: In cookie-only mode the JSON token fields are **omitted** (not empty strings,
  not nulls): `TokenPairResponse.accessToken`/`refreshToken` become `Maybe Text` with
  omit-`Nothing` serialization; `expiresIn` stays.
  Rationale: omission is the honest wire shape ("there is no body token"), keeps
  cookie-only responses XSS-clean, and `Maybe` + omitted-field decoding stays
  backward-compatible for bearer-mode clients (fields always present there). Empty strings
  would type-check everywhere and blow up at runtime instead.
  Date: 2026-07-07

- Decision: `Set-Cookie` response headers are typed as `Header "Set-Cookie" Text` (two of
  them), rendered with `Web.Cookie.renderSetCookie`, using servant's
  `addHeader`/`noHeader` so bearer mode emits no header at all.
  Rationale: `web-cookie`'s `SetCookie` has no `ToHttpApiData` instance in our dependency
  set; defining an orphan instance (as servant-auth-server does) invites clashes.
  Rendering to `Text` at the construction site is explicit and dependency-free
  (`shomei-servant` already depends on `cookie` for `parseCookies`).
  Date: 2026-07-07

- Decision: Cookie/CSRF policy lives in a new `CookieConfig` sub-record of `ShomeiConfig`:
  `secure :: Bool` (default `True`), `sameSite :: SameSitePolicy` (default `SameSiteLax`),
  `allowedOrigins :: [Text]` (default `["http://localhost:8080"]`).
  Rationale: mirrors the existing sub-record pattern (`WebAuthnConfig`,
  `ImpersonationConfig`); append-only per MasterPlan IP-3. The localhost default matches
  `defaultWebAuthnConfig.origins` and `publicBaseUrl`, so the turnkey dev experience works
  out of the box; production operators must set real origins (documented loudly).
  `Secure=True` by default is safe even for localhost development — browsers exempt
  localhost from the Secure-cookie HTTPS requirement.
  Date: 2026-07-07

- Decision: The CSRF rejection is an HTTP-layer error (`403
  {"error":"csrf_rejected","message":"Origin not allowed for cookie-authenticated
  request"}`) built in `shomei-servant`, not a new `AuthError` constructor.
  Rationale: CSRF is a transport-level property of *how the credential arrived*; the core
  workflows never see it, so polluting the domain error vocabulary would be wrong-layer.
  Date: 2026-07-07

- Decision: `RefreshRequest.refreshToken` becomes optional (`Maybe Text`); the body value,
  when present, takes precedence over the cookie.
  Rationale: cookie-mode browser clients POST an empty JSON object; body-precedence keeps
  bearer-mode behavior identical and makes mixed-mode (`both`) deterministic.
  Date: 2026-07-07

- Decision: The `mfa_required` arm of `POST /auth/login` sets **no** cookies (nothing to
  set — no token was issued); the token-issuing completions (`/auth/mfa/complete`,
  `/auth/login/passkey/complete`) and `POST /auth/signup` all set the same two cookies as
  a completed login.
  Rationale: cookies must be armed at every point a `TokenPair` crosses the boundary, or
  cookie-mode users of MFA/passwordless/signup would silently get body-less, cookie-less
  responses. Signup issues tokens today (`SignupResponse.token`), so it is in scope.
  Date: 2026-07-07


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

(To be filled during and after implementation.)


## Context and Orientation

Shōmei is a multi-package Haskell (Cabal) project built inside a Nix devshell. This plan
lives almost entirely in `shomei-servant` (the HTTP layer: the `ShomeiAPI` servant route
record, request handlers, DTOs — the JSON wire shapes — and the auth combinator) with
config additions in `shomei-core` and env plumbing in `shomei-server`. *Servant* is the
Haskell web framework in use: routes are types; a route's response headers are part of its
type (`Headers '[Header "Set-Cookie" Text, …] Body`); handlers attach them with
`addHeader`/`noHeader`.

Exact current state (verified against the working tree):

**The read path** — `shomei-servant/src/Shomei/Servant/Auth.hs`. `authHandler` (lines
75–84) is built from a verifier function and registered in the servant `Context` by
`Shomei.Server.Boot.authContext` (`authHandler senv.verifier`). `extractToken` (lines
88–102):

```haskell
extractToken :: Request -> Maybe Text
extractToken req = bearer <|> cookieToken
  where
    ...
    cookieToken = do
      raw <- lookup "Cookie" headers
      val <- lookup ("shomei_session" :: BS.ByteString) (parseCookies raw)
      pure (Text.decodeUtf8 val)
```

— the unconditional cookie fallback. `parseCookies` comes from `Web.Cookie` (package
`cookie`, already a `shomei-servant` dependency).

**The dead config** — `shomei-core/src/Shomei/Config.hs` line 46: `data TokenTransport =
BearerToken | HttpOnlyCookie | BearerAndCookie`; `ShomeiConfig.tokenTransport` defaults to
`BearerToken`. Parsed from `SHOMEI_TOKEN_TRANSPORT` in
`shomei-server/src/Shomei/Server/Config.hs` (`transportEnv`, lines 489–498:
`bearer|cookie|both`). `rg -n "tokenTransport" --type haskell` shows no consumer beyond
config code. (Note: the value is spelled `BearerToken`, not "BearerOnly".)

**Routes and handlers** — `shomei-servant/src/Shomei/Servant/API.hs` defines the
`ShomeiAPI` record; the routes this plan retypes are `signup` (`Post '[JSON]
SignupResponse`), `login` (`RemoteHost :> ReqBody '[JSON] LoginRequest :> Post '[JSON]
LoginResponse`), `refresh` (`ReqBody '[JSON] RefreshRequest :> Post '[JSON]
TokenPairResponse`), `logout` (`Authenticated :> PostNoContent`), `mfaComplete` and
`passkeyLoginComplete` (both `Post '[JSON] TokenPairResponse`). Handlers are in
`shomei-servant/src/Shomei/Servant/Handlers.hs` (`signupH`, `loginH` ~line 150, `refreshH`
~187, `logoutH` ~274, `mfaCompleteH` ~324, `passkeyLoginCompleteH` ~337); they call core
workflows through the seam `Env` (`shomei-servant/src/Shomei/Servant/Seam.hs`, which
carries `config :: ShomeiConfig` — so every handler can read the transport). DTOs are in
`shomei-servant/src/Shomei/Servant/DTO.hs`: `TokenPairResponse { accessToken :: Text,
refreshToken :: Text, expiresIn :: Int }` (lines 81–87, generic To/FromJSON),
`tokenPairToResponse` (lines 296–305), `LoginResponse` (a hand-instanced two-arm sum:
`complete` with `user`+`token`, `mfa_required` with `ceremonyId`+`options`),
`SignupResponse { user, token }`, `RefreshRequest { refreshToken :: Text }` (line 183).

**Token TTLs** for `Max-Age`: `ShomeiConfig.accessTokenTTL` (default 15 min) and
`refreshTokenTTL` (default 30 days), both `NominalDiffTime`.

**Tests** — the servant integration suite is `shomei-servant/test/Main.hs`, one large
end-to-end scenario over hybrid stacks (in-memory stores + real ES256 JWT signer/verifier)
driven with WAI test helpers; it constructs `Seam.Env` values directly, so per-transport
configs are easy to inject. The generated OpenAPI spec is committed at
`docs/api/openapi.json` and regenerated with `cabal run shomei-openapi >
docs/api/openapi.json` (executable in `shomei-servant/shomei-servant.cabal`); a conformance
suite covers it, so wire-shape changes must regenerate the file.

**CSRF in one paragraph** (term of art, defined): a *cross-site request forgery* is a
state-changing request that the victim's own browser sends to Shōmei because a page on an
attacker's origin triggered it (a form auto-submit, a `fetch` with
`credentials: "include"`); the browser helpfully attaches the victim's cookies. The
attacker cannot read the response (CORS blocks that) but does not need to — the side
effect (logout, password change, passkey removal) is the attack. Defenses used here: the
`SameSite` cookie attribute (tells the browser not to attach the cookie on cross-site
requests; `Lax` allows only top-level GET navigations) and server-side verification of the
`Origin` request header (which browsers set to the *initiating* page's origin and
JavaScript cannot forge) against an allow-list.

Build/test commands (repository root, inside `nix develop`): `cabal build all`,
`cabal test shomei-servant`, `cabal test all`. Live server: `just create-database` then
`cabal run exe:shomei-server` (port 8080).


## Plan of Work

Four milestones: M1 fixes the read side (config vocabulary, transport-aware extraction,
CSRF gate). M2 builds the write side (Set-Cookie emission, body redaction, cookie
refresh). M3 is the integration-test matrix. M4 is docs, OpenAPI, and the live transcript.

### Milestone M1 — cookie policy config and a safe read path

Scope: at the end, `bearer` deployments no longer accept cookies at all; cookie-mode
deployments accept them but refuse cross-origin mutations; nothing emits cookies yet.

1. Config (`shomei-core/src/Shomei/Config.hs`): add, following the `WebAuthnConfig`
   pattern (exported types, `defaultCookieConfig`, field + default in
   `ShomeiConfig`/`defaultShomeiConfig`):

   ```haskell
   -- | How browsers may carry Shōmei's cookies cross-site. Rendered into the
   -- SameSite attribute of every cookie Shōmei sets.
   data SameSitePolicy = SameSiteStrict | SameSiteLax | SameSiteNone
     deriving stock (Generic, Eq, Show)
     deriving anyclass (FromJSON, ToJSON)

   -- | Cookie-transport and CSRF policy (used only when 'tokenTransport' is
   -- 'HttpOnlyCookie' or 'BearerAndCookie').
   data CookieConfig = CookieConfig
     { -- | mark cookies Secure (HTTPS-only; browsers exempt localhost). Default True.
       secure :: !Bool,
       -- | SameSite attribute. Default 'SameSiteLax'.
       sameSite :: !SameSitePolicy,
       -- | origins allowed to make cookie-authenticated mutating requests, e.g.
       -- ["https://app.example.com"]. Compared exactly against the Origin header
       -- (scheme://host[:port]). Default ["http://localhost:8080"] for the
       -- turnkey dev experience — production MUST set real origins.
       allowedOrigins :: ![Text]
     }
     deriving stock (Generic, Eq, Show)
     deriving anyclass (FromJSON, ToJSON)
   ```

2. Env/file plumbing (`shomei-server/src/Shomei/Server/Config.hs`): in
   `overlayCoreFromEnv` read `SHOMEI_COOKIE_SECURE` (`boolEnv`),
   `SHOMEI_COOKIE_SAMESITE` (`strict|lax|none`, new small parser modeled on
   `sessionCheckEnv`), `SHOMEI_CSRF_ALLOWED_ORIGINS` (comma-separated, modeled on
   `overlayWebAuthnFromEnv`'s `originsEnv`); add optional `cookieSecure`,
   `cookieSameSite`, `csrfAllowedOrigins` fields to `FileConfig` and merge in
   `baseFromFile`.

3. Read path (`shomei-servant/src/Shomei/Servant/Auth.hs`): make extraction
   transport-aware and source-tagged:

   ```haskell
   -- | Where the presented credential came from. Cookie-sourced credentials are
   -- subject to the CSRF origin gate; bearer credentials never are (a foreign page
   -- cannot set the Authorization header).
   data TokenSource = FromBearer | FromCookie
     deriving stock (Eq, Show)

   extractToken :: TokenTransport -> Request -> Maybe (TokenSource, Text)
   ```

   `BearerToken` → bearer lookup only. `HttpOnlyCookie`/`BearerAndCookie` → bearer first,
   then the `shomei_session` cookie (existing `parseCookies` code), tagging the source.

4. CSRF gate (same module):

   ```haskell
   -- | Allow-list check for cookie-authenticated mutating requests: Origin header
   -- must match exactly; absent Origin falls back to a Referer prefix match
   -- (an allowed origin followed by "/" or end); absent both fails closed.
   originAllowed :: [Text] -> Request -> Bool
   ```

   and extend `authHandler` to take the policy:

   ```haskell
   data CookiePolicy = CookiePolicy
     { transport :: !TokenTransport,
       allowedOrigins :: ![Text]
     }

   authHandler :: CookiePolicy -> (Text -> IO (Either TokenError AuthClaims)) -> AuthHandler Request AuthUser
   ```

   Handler logic: extract with `extractToken policy.transport`; on `FromCookie` **and**
   `requestMethod req` not in `["GET","HEAD","OPTIONS"]`, require
   `originAllowed policy.allowedOrigins req`, else throw
   `err403 { errBody = "{\"error\":\"csrf_rejected\",\"message\":\"Origin not allowed for cookie-authenticated request\"}" , errHeaders = [("Content-Type","application/json")] }`
   (define it once as `csrfRejected :: ServerError` and export it — the refresh handler
   reuses it in M2). Then verify as today.

5. Assembly: `Shomei.Server.Boot.authContext` (and every other `authHandler` call —
   `rg -n "authHandler" --type haskell`, including the servant test assemblies) passes
   `CookiePolicy { transport = cfg.tokenTransport, allowedOrigins =
   cfg.cookieConfig.allowedOrigins }` built from the seam env's config.

6. Unit tests (servant suite): with transport `BearerToken`, a request carrying only a
   valid `shomei_session` cookie → `401` (**fails before this plan** — the cookie is
   accepted today; observe once and record); with `HttpOnlyCookie`, the same request →
   `200` on a GET, `403 csrf_rejected` on a POST without Origin, `200` on a POST with an
   allow-listed Origin, `403` with a foreign Origin; bearer requests unaffected in all
   modes.

Acceptance: `cabal test shomei-servant` passes with the new read-path matrix.

### Milestone M2 — emit, redact, clear, and refresh

Scope: cookie-mode responses actually carry cookies; bodies stop carrying tokens in
cookie-only mode; logout clears; refresh works from the cookie.

1. New module `shomei-servant/src/Shomei/Servant/Cookie.hs` (add to `exposed-modules` in
   `shomei-servant/shomei-servant.cabal`):

   ```haskell
   -- | Building and rendering Shōmei's transport cookies. Two cookies:
   -- shomei_session (access token, Path=/) and shomei_refresh (refresh token,
   -- Path=/auth/refresh — presented to exactly one endpoint). Both HttpOnly.
   module Shomei.Servant.Cookie
     ( CookiePair,
       tokenCookies,     -- :: ShomeiConfig -> TokenPair -> CookiePair
       clearedCookies,   -- :: ShomeiConfig -> CookiePair
       applyCookies,     -- attach a CookiePair when transport uses cookies, noHeader otherwise
       WithCookies,
     )
   where
   ```

   `WithCookies a = Headers '[Header "Set-Cookie" Text, Header "Set-Cookie" Text] a`.
   Build with `Web.Cookie.defaultSetCookie` setting: name/value; `setCookiePath = Just
   "/"` (session) / `Just "/auth/refresh"` (refresh); `setCookieHttpOnly = True`;
   `setCookieSecure = cfg.cookieConfig.secure`; `setCookieSameSite` mapped from
   `SameSitePolicy` (`sameSiteStrict`/`sameSiteLax`/`sameSiteNone`); `setCookieMaxAge =
   Just (round cfg.accessTokenTTL)` resp. `refreshTokenTTL`. `clearedCookies` = same
   names/paths/flags, empty value, `Max-Age=0`. Render via `renderSetCookie` (a
   `Builder`) → strict `Text`. `applyCookies cfg pair body`: when `cfg.tokenTransport` is
   `HttpOnlyCookie`/`BearerAndCookie`, `addHeader session (addHeader refresh body)`; when
   `BearerToken`, `noHeader (noHeader body)`.

2. DTO changes (`shomei-servant/src/Shomei/Servant/DTO.hs`):
   - `TokenPairResponse { accessToken :: Maybe Text, refreshToken :: Maybe Text,
     expiresIn :: Int }` with hand-written instances that omit `Nothing` fields on
     encode and treat missing fields as `Nothing` on decode (aeson: build the object
     from `catMaybes`; parse with `.:?`).
   - `tokenPairToResponse :: ShomeiConfig -> TokenPair -> TokenPairResponse`: body tokens
     are `Just` for `BearerToken` and `BearerAndCookie`, `Nothing` for `HttpOnlyCookie`.
     Update all callers (`rg -n "tokenPairToResponse" --type haskell` — handlers and
     tests; also the demo/client code, `rg -n "TokenPairResponse"` across the repo, which
     must now handle `Maybe`).
   - `RefreshRequest { refreshToken :: Maybe Text }`.

3. Route types (`shomei-servant/src/Shomei/Servant/API.hs`): wrap the five token-issuing
   responses and logout in `WithCookies` (import from the new module):
   `signup … Post '[JSON] (WithCookies SignupResponse)`;
   `login … Post '[JSON] (WithCookies LoginResponse)`;
   `refresh … :> Header "Cookie" Text :> Header "Origin" Text :> Header "Referer" Text :>
   ReqBody '[JSON] RefreshRequest :> Post '[JSON] (WithCookies TokenPairResponse)`;
   `mfaComplete`/`passkeyLoginComplete` → `WithCookies TokenPairResponse`;
   `logout … :> Verb 'POST 204 '[JSON] (WithCookies NoContent)` (replacing
   `PostNoContent`, which cannot carry headers).

4. Handlers (`shomei-servant/src/Shomei/Servant/Handlers.hs`):
   - `signupH`/`mfaCompleteH`/`passkeyLoginCompleteH`: on success,
     `applyCookies env.config (tokenCookies env.config pair) body`.
   - `loginH`: `complete` arm applies cookies; `mfa_required` arm `noHeader (noHeader …)`.
   - `logoutH`: after revoking, apply `clearedCookies` (always safe to send even in
     bearer mode? — no: honor the transport via `applyCookies`, so bearer mode stays
     header-free).
   - `refreshH` (new signature `Env -> Maybe Text -> Maybe Text -> Maybe Text ->
     RefreshRequest -> Handler (WithCookies TokenPairResponse)` for
     Cookie/Origin/Referer headers): resolve the presented token — body first, else (when
     transport permits cookies) the `shomei_refresh` value from the Cookie header
     (`parseCookies`); if the cookie was used, enforce the same Origin/Referer gate
     (reuse `originAllowed` + `csrfRejected`); neither present → `400` `"refreshToken
     required"`. Rotate via the unchanged core workflow; apply fresh cookies to the
     response.

5. Sweep the compile fallout: the servant test suite and any embedded/demo assemblies
   construct these routes/DTOs (`cabal build all` lists every site).

Acceptance: `cabal build all` green; existing bearer-mode servant tests pass unchanged
(they now read `token = Just …` fields); manual smoke via curl (Concrete Steps) shows
`Set-Cookie` in cookie mode and its absence in bearer mode.

### Milestone M3 — the integration-test matrix

Scope: the behaviors are pinned by tests in `shomei-servant/test/Main.hs`, following its
existing sectioned end-to-end style (build a `Seam.Env` per transport config; drive WAI
requests; assert on status/headers/bodies). Cases:

1. Cookie mode (`HttpOnlyCookie`): login (complete arm) → two `Set-Cookie` headers;
   `shomei_session` has `HttpOnly`, `SameSite=Lax`, `Path=/`, `Max-Age=900`, `Secure`;
   `shomei_refresh` has `Path=/auth/refresh`, `Max-Age=2592000`; body has **no**
   `accessToken`/`refreshToken` keys (assert on raw JSON) but has `expiresIn`.
2. Cookie auth round-trip: GET `/auth/me` with only the session cookie → `200`.
3. CSRF matrix on a mutating route (e.g. `POST /auth/logout` with only cookies): no
   Origin/Referer → `403 csrf_rejected`; allowed Origin → `204`; foreign Origin → `403`;
   no Origin but allowed Referer → success; bearer-authenticated logout with a foreign
   Origin → `204` (gate skipped for bearer).
4. Cookie refresh: POST `/auth/refresh` with `{}` body + `shomei_refresh` cookie + allowed
   Origin → `200`, new cookies differ from old, old refresh token now rejected
   (rotation happened); same without Origin → `403`.
5. Bearer mode (`BearerToken`): the same login carries **no** `Set-Cookie`; body carries
   both tokens; a cookie-only authenticated request → `401`.
6. `BearerAndCookie`: cookies set **and** body tokens present.
7. Logout clearing: cookie-mode logout response's `Set-Cookie` values have empty values
   and `Max-Age=0` for both names.

Acceptance: `cabal test shomei-servant` green; each CSRF-reject case observed to fail
against M1-less code at least once during development (record in Surprises &
Discoveries).

### Milestone M4 — docs, OpenAPI, live transcript

Scope: written contract matches behavior.

- `docs/user/api.md`: new "Token transport" subsection near the top — the three modes,
  cookie names/attributes, body-omission rule, the CSRF requirement ("cookie-authenticated
  mutating requests must send an allow-listed Origin"), `403 csrf_rejected`; update the
  `login`/`signup`/`refresh`/`logout`/`mfa/complete`/`login/passkey/complete` entries with
  their cookie behavior and `refresh`'s optional body field.
- `docs/user/security.md`: new "Cookie transport & CSRF" section — HttpOnly rationale
  (XSS), SameSite default, Origin allow-list, refresh-cookie path scoping, and the
  explicit statement that bearer mode ignores cookies entirely.
- `docs/user/deployment.md`: `SHOMEI_TOKEN_TRANSPORT`, `SHOMEI_COOKIE_SECURE`,
  `SHOMEI_COOKIE_SAMESITE`, `SHOMEI_CSRF_ALLOWED_ORIGINS` (with a red-letter "set real
  origins in production").
- Regenerate the committed OpenAPI spec: `cabal run shomei-openapi >
  docs/api/openapi.json`; run its conformance suite (`cabal test all` covers it).
- Capture the live curl transcript from Validation and paste it there.

Acceptance: docs updated, spec regenerated and green, transcript recorded.


## Concrete Steps

All commands from `/Users/shinzui/Keikaku/bokuno/shomei`, inside `nix develop`.

```bash
cabal build all                      # after each milestone
cabal test shomei-servant            # M1, M2, M3
cabal test all                       # sweep incl. OpenAPI conformance
cabal run shomei-openapi > docs/api/openapi.json    # M4
```

Fallout sweeps:

```bash
rg -n "extractToken|authHandler" --type haskell     # M1 signature changes
rg -n "tokenPairToResponse|TokenPairResponse" --type haskell   # M2 DTO changes
rg -n "RefreshRequest" --type haskell
rg -n "PostNoContent" shomei-servant/src            # logout route change
```

Live cookie-mode smoke test (M2/M4):

```bash
just create-database
SHOMEI_TOKEN_TRANSPORT=cookie SHOMEI_CSRF_ALLOWED_ORIGINS=http://localhost:8080 \
  cabal run exe:shomei-server        # terminal 1

# terminal 2 — signup in cookie mode: note Set-Cookie headers, token-free body
curl -si -X POST http://localhost:8080/auth/signup -H 'Content-Type: application/json' \
  -d '{"email":"c@example.com","password":"correct horse battery staple","displayName":"C"}' \
  | tee /tmp/resp | grep -i '^set-cookie'
```

Expected:

```text
Set-Cookie: shomei_session=eyJ…; Path=/; Max-Age=900; HttpOnly; Secure; SameSite=Lax
Set-Cookie: shomei_refresh=Kj9…; Path=/auth/refresh; Max-Age=2592000; HttpOnly; Secure; SameSite=Lax
```

and the JSON body's `token` object contains `expiresIn` but no `accessToken`/
`refreshToken` keys. Continue:

```bash
# cookie-authenticated GET works
curl -s -o /dev/null -w '%{http_code}\n' http://localhost:8080/auth/me \
  -H 'Cookie: shomei_session=<value from above>'                     # → 200

# cookie-authenticated mutation without Origin is refused
curl -s -X POST http://localhost:8080/auth/logout \
  -H 'Cookie: shomei_session=<value>'                                # → {"error":"csrf_rejected",…}

# with an allow-listed Origin it succeeds and clears the cookies
curl -si -X POST http://localhost:8080/auth/logout \
  -H 'Cookie: shomei_session=<value>' -H 'Origin: http://localhost:8080' \
  | grep -i '^set-cookie'      # both cookies re-set with empty value; Max-Age=0
```

Bearer-mode regression check: rerun the server without the env vars; signup response has
no `Set-Cookie`, body has both tokens, and a request authenticated *only* by a cookie
gets `401`.


## Validation and Acceptance

Acceptance is the observable matrix, automated in M3 and demonstrated live in M4:

1. `bearer` (default): responses never set cookies; bodies carry tokens exactly as today;
   **cookies are never accepted as credentials** (the review's dangling read path is
   closed) — a cookie-only request is `401`.
2. `cookie`: token-issuing responses set `shomei_session` + `shomei_refresh` with
   `HttpOnly; Secure; SameSite=Lax` (configurable), correct `Path`/`Max-Age`; bodies omit
   token values; cookie-authenticated GETs work; cookie-authenticated mutations require an
   allow-listed `Origin` (Referer fallback) and otherwise return
   `403 {"error":"csrf_rejected",…}`; `POST /auth/refresh` with an empty body uses the
   `shomei_refresh` cookie, rotates, re-sets both cookies, and is CSRF-gated; logout
   clears both cookies.
3. `both`: union — cookies set *and* bodies carry tokens; read path as in cookie mode.
4. Bearer requests are never CSRF-gated in any mode.
5. `cabal test all` green, including the regenerated OpenAPI conformance suite; the
   committed `docs/api/openapi.json` reflects the optional token fields and new headers.

Test commands: `cabal test shomei-servant`, `cabal test all`. Each security-relevant
negative case (cookie accepted in bearer mode; CSRF-less mutation) must be observed
failing against pre-plan code once, recorded in Surprises & Discoveries.


## Idempotence and Recovery

All changes are compiler-checked source edits; `cabal build`/`cabal test` re-run safely.
Route-type and DTO changes are enumerated by the compiler — a partial edit cannot slip
through silently. No database schema or data changes exist in this plan.

Deployment safety: the default transport remains `BearerToken`, whose behavior after this
plan is a strict subset of today's (same responses; cookie fallback removed). The only
deployments that could notice the read-path tightening are ones *relying* on the
undocumented always-on cookie fallback while configured as `bearer` — they should set
`SHOMEI_TOKEN_TRANSPORT=cookie` or `both`, which is the one-line recovery. Cookie mode is
opt-in and reversible: switching back to `bearer` simply stops setting/accepting cookies
(stale cookies in browsers expire via `Max-Age` or are ignored).

Wire-compat: `TokenPairResponse` fields become optional but are always present in
bearer/both modes, so existing bearer-mode clients decode unchanged; only cookie-mode
(new) clients see omissions. `RefreshRequest.refreshToken` optionality is
backward-compatible (present bodies still decode).

If CSRF scope balloons mid-implementation, the MasterPlan-recorded fallback is to remove
the cookie read path (delete the cookie branch of `extractToken`, keep the transport enum
parsing but reject `cookie|both` at config load with a clear error) — record such a pivot
in this Decision Log before doing it.


## Interfaces and Dependencies

No new package dependencies: `cookie` (parse/render), `servant`/`servant-server`
(`Headers`, `addHeader`/`noHeader`), `wai` (`Request`, `requestMethod`), `aeson` are all
already dependencies of `shomei-servant`.

Definitions that must exist at the end (full module paths):

- `Shomei.Config.SameSitePolicy` (`SameSiteStrict|SameSiteLax|SameSiteNone`),
  `Shomei.Config.CookieConfig { secure :: Bool, sameSite :: SameSitePolicy,
  allowedOrigins :: [Text] }`, `defaultCookieConfig`, and
  `ShomeiConfig.cookieConfig :: CookieConfig`.
- Env handling in `Shomei.Server.Config`: `SHOMEI_COOKIE_SECURE`,
  `SHOMEI_COOKIE_SAMESITE`, `SHOMEI_CSRF_ALLOWED_ORIGINS` (+ matching optional
  `FileConfig` fields).
- `Shomei.Servant.Auth.TokenSource (FromBearer | FromCookie)`;
  `Shomei.Servant.Auth.extractToken :: TokenTransport -> Request -> Maybe (TokenSource, Text)`;
  `Shomei.Servant.Auth.CookiePolicy { transport, allowedOrigins }`;
  `Shomei.Servant.Auth.authHandler :: CookiePolicy -> (Text -> IO (Either TokenError
  AuthClaims)) -> AuthHandler Request AuthUser`;
  `Shomei.Servant.Auth.originAllowed :: [Text] -> Request -> Bool`;
  `Shomei.Servant.Auth.csrfRejected :: ServerError` (403, `csrf_rejected`).
- `Shomei.Servant.Cookie.WithCookies a`, `tokenCookies`, `clearedCookies`,
  `applyCookies` as sketched in M2.
- `Shomei.Servant.DTO.TokenPairResponse` with `Maybe Text` token fields
  (omit-`Nothing` JSON); `tokenPairToResponse :: ShomeiConfig -> TokenPair ->
  TokenPairResponse`; `RefreshRequest { refreshToken :: Maybe Text }`.
- `Shomei.Servant.API.ShomeiAPI` with `WithCookies`-wrapped responses on `signup`,
  `login`, `refresh` (+ `Header "Cookie"/"Origin"/"Referer"` inputs), `mfaComplete`,
  `passkeyLoginComplete`, `logout`.
- `Shomei.Server.Boot.authContext` passing the `CookiePolicy` from config.

Relations to other plans: none of the core workflows change, so plans 28 and 30 (which
edit `Shomei.Workflow`) do not conflict beyond trivial test-file adjacency. The MasterPlan
config integration point applies: this plan adds `cookieConfig` and must not rename
existing `ShomeiConfig` fields. The committed OpenAPI spec (plan 27's deliverable) must be
regenerated here because the wire shapes change.
