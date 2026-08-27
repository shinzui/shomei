---
id: 58
slug: proxy-aware-wai-edge-trusted-forwarded-headers-metered-bodies-and-bounded-metrics
title: "Proxy-Aware WAI Edge: Trusted Forwarded Headers, Metered Bodies, and Bounded Metrics"
kind: exec-plan
created_at: 2026-08-27T03:23:49Z
intention: "intention_01m10kwqt9eedbjvk91rn726mq"
master_plan: "docs/masterplans/8-trust-boundary-remediation-close-the-august-2026-security-and-performance-review.md"
---

# Proxy-Aware WAI Edge: Trusted Forwarded Headers, Metered Bodies, and Bounded Metrics

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.

This is **EP-8** of
[MasterPlan 8](../masterplans/8-trust-boundary-remediation-close-the-august-2026-security-and-performance-review.md)
(Phase 3; soft dependencies on EP-4, `docs/plans/54-…`, and EP-6, `docs/plans/56-…`, both unstarted 104-line
skeletons at HEAD `5dfd2a6`). It owns *what enters the process*: who a request is attributed to, how much
body it may carry, what the metrics scrape can contain, which clock the edge reads, how readiness answers,
and how the cookies are named.


## Purpose / Big Picture

Today `shomei-server` believes the TCP peer is the client. It serves plaintext only (no `warp-tls`) and its
cookies default to `Secure`, so production sits behind a TLS-terminating reverse proxy, where every request
arrives from the proxy's address: twenty wrong passwords from *anyone* trip the per-IP failure throttle for
*everyone*, the token bucket is shared by all, and every login-attempt row records the proxy as `16777343`.

After this plan an operator sets `SHOMEI_TRUSTED_PROXIES=10.0.0.0/8` (or turns on warp's PROXY protocol) and
the rate limiter, the login handler, the token-exchange audit row, and the request log all see the real
client, rendered as `203.0.113.7` or `2001:db8::1`; the per-IP knobs are tunable from the environment and
the Dhall file; a chunked upload is cut off at 1 MiB with the same RFC 9457 problem document every other
error carries; a crash inside a handler answers `500 {"code":"internal",…}` instead of warp's plain-text
page; invalid UTF-8 in `Authorization` is a `401`; a hostile HTTP method can neither corrupt nor bloat
`/metrics`; the token bucket and latency histogram survive an NTP step; `/health/ready` answers within two
seconds and costs at most one query per second; and the cookies are `__Host-shomei_session` and
`__Secure-shomei_refresh`. Each is demonstrated by a test that fails at HEAD or a `curl` transcript below.


## Progress

- [x] (2026-08-27T22:40:52Z) Step 0: pre-fix observations recorded in Surprises & Discoveries.
- [x] (2026-08-27T22:52:42Z) M1: `Shomei.Servant.ClientIp` used at all four sites; `Shomei.Server.Middleware.TrustedProxy` with
      the four MiddlewareSpec cases; `trustedProxies`/`proxyProtocol` keys (env + Dhall); boot refuses an
      invalid entry; `edgeMiddleware` in `Boot.hs`; warp `setProxyProtocol*`; `deployment.md` "Behind a
      reverse proxy"; `docs/adr/` created with the trusted-proxy ADR.
- [ ] M2: seven rate-limit env vars and four missing Dhall keys; `normalizeOrigin` at load;
      `cookieTransportWarnings` at boot; ConfigSpec cases.
- [ ] M3: `__Host-`/`__Secure-` names when `cookieSecure`; servant scenarios, docs, CHANGELOGs; cookie ADR.
- [ ] M4: metered body; `pcPayloadTooLarge`; chunked test flipped; `problemExceptionResponse` installed;
      `decodeUtf8Lenient` in `Auth.hs`; hostile-header scenario; `openapi.json` regenerated.
- [ ] M5: method-label whitelist and escaping; monotonic clock; `HealthPolicy` (2 s timeout, 1 s cache);
      health tests; docs reconciled; ADR distillation; MasterPlan 8 updated.
- [ ] `nix fmt` clean; `cabal build all --enable-tests` and `cabal test all` green.


## Surprises & Discoveries

- The regression-first run needed port `18080` because a local container already owned
  `127.0.0.1:8080`, and it used a clean `shomei_ep8` database so the signing-key envelope had a
  known test key. The behavior matched the review: twenty requests with twenty-five distinct
  `X-Forwarded-For` values were all attributed to the socket peer, then five shared-bucket
  responses were throttled; the stored rows collapsed to one decimal IPv4 value. The oversized
  chunked body reached JSON decoding and answered 400, and invalid UTF-8 in `Authorization`
  escaped as warp's plain 500. Evidence:

  ```text
  401 401 401 401 401 401 401 401 401 401 401 401 401 401 401 401 401 401 401 401 429 429 429 429 429
  16777343|20
  400
  HTTP/1.1 500 Internal Server Error
  {"error":"Cannot decode byte '\\xff': Data.Text.Encoding: Invalid UTF-8 stream","level":"error","method":"GET","msg":"unhandled exception","path":"/v1/auth/me"}
  ```

- EP-4 had already extracted `Shomei.Servant.RemoteHost` while landing the expanded credential
  accounting surface. M1 kept it as a compatibility re-export and moved the implementation and
  every in-tree reader to `Shomei.Servant.ClientIp`. The focused suite passed 21 cases, and the
  live rerun with `SHOMEI_TRUSTED_PROXIES=127.0.0.1/32` returned twenty-five 401s while persisting
  `203.0.113.1` through `203.0.113.25` once each; `SHOMEI_TRUSTED_PROXIES=nope` exited 1 before boot.


## Decision Log

- Decision: The trusted-proxy middleware **rewrites `remoteHost`** on the WAI `Request` rather than stashing
  the client in the request `vault`.
  Rationale: servant's `RemoteHost` is `passToServer subserver remoteHost` (servant-server 0.20.3
  `Servant/Server/Internal.hs:1097-1101`), so `loginH`, the OAuth token endpoint, `RateLimit.clientKey`, and
  `Logging.clientIp` all see the client with no change; a vault key would need every reader taught a second
  lookup. wai-extra 3.1.18's `RealIp` makes the same choice (`RealIp.hs:50-59`). The rewritten address
  carries port 0: nothing in Shōmei reads it. Date: 2026-08-27

- Decision: `trustedProxies` **defaults to empty** (trust nobody — today's behaviour); only `X-Forwarded-For`
  is consulted, walking from the right and skipping trusted addresses; when every hop is trusted the
  leftmost is used; warp's PROXY protocol is exposed as `none` or `required` only.
  Rationale: a non-empty default (wai-extra trusts every RFC 1918 range) makes a container neighbour a
  spoofing vector. RFC 7239 `Forwarded` and `X-Real-IP` are not read because a header the operator's proxy
  does not set is exactly the attacker-controlled input the finding is about. `setProxyProtocolOptional` is
  refused because warp documents it as "easy IP address spoofing" (warp 3.4.15 `Warp.hs:451-458`).
  Date: 2026-08-27

- Decision: CIDR parsing and matching use **`iproute`** (`Data.IP`), already in the build plan at 1.7.15 as
  warp's dependency; address *rendering* is hand-written on `network`.
  Rationale: IPv6 text parsing with `::` compression is subtle, and iproute costs no new build. It is not in
  the Mori corpus, so its API is taken from wai-extra's `RealIp.hs` and verified with `:browse Data.IP`.
  Rendering stays on `network` so `shomei-servant` gains no dependency. Date: 2026-08-27

- Decision: Rename the cookies to **`__Host-shomei_session`** and **`__Secure-shomei_refresh`** now, pre-1.0,
  whenever `cookieSecure` is on; keep the bare names when it is off.
  Rationale: the prefixes make a browser refuse a same-named cookie planted by a sibling subdomain with
  `Domain=` (REV-7 finding 9). `__Host-` requires `Path=/`, which the session cookie satisfies; the refresh
  cookie's `Path=/v1/auth/refresh` rules it out, hence `__Secure-`. Browsers reject a prefixed cookie without
  `Secure`, so a `cookieSecure = false` deployment must keep the bare names. It is a breaking rename — every
  browser session is logged out once — and 0.1.0.0 is the only release; later it would need a dual-name period.
  Date: 2026-08-27

- Decision: The `method` label is **whitelisted** to `GET HEAD POST PUT PATCH DELETE OPTIONS` (else `other`)
  and every label value is escaped per the exposition format.
  Rationale: warp accepts any bytes before the first space as the method, so the label was an unbounded
  attacker-chosen series key and a `"` in it blacked out the scrape (REV-8 finding 6). Date: 2026-08-27

- Decision: `trustedProxies` and `proxyProtocol` live in **`ServerSettings`**, not `ShomeiConfig`; the per-IP
  knobs stay in `RateLimitConfig` and only gain env/Dhall exposure.
  Rationale: they describe this process's network edge, like `serverPort`; `ShomeiConfig` is handed to every
  embedding host through `Seam.Env` and built by `defaultShomeiConfig` in the admin CLI and tests. EP-9
  builds `hostMiddleware` from the parsed `TrustedProxies` value, not from either record. Date: 2026-08-27

- Decision: Readiness gets `withProbeTimeout 2_000_000 "postgres"` and a **one-second single-flight cache**,
  both fields of a `HealthPolicy` so tests can set the cache to 0; body metering is written in `BodyLimit.hs`
  in wai-extra's `RequestSizeLimit` shape rather than by adding wai-extra; existing decimal `client_ip` rows
  are **not backfilled**.
  Rationale: a hung pool otherwise stalls the probe for the 10 s acquisition timeout, and probe fan-in should
  not multiply queries. Twenty-five testable lines are not worth a dependency (plan 36's rule). Login
  attempts are counted over a 15-minute window, so old-format rows matter for fifteen minutes after the
  upgrade; audit payloads are historical facts. Date: 2026-08-27


- Decision: Keep `Shomei.Servant.RemoteHost` as a compatibility re-export while moving canonical
  rendering and all in-tree consumers to `Shomei.Servant.ClientIp`.
  Rationale: EP-4 extracted `RemoteHost` after this plan was drafted and exposed it from the package.
  Deleting that module would create an unrelated source break for embedding hosts; a zero-cost re-export
  preserves compatibility while the new name makes the shared policy explicit. Date: 2026-08-27


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

**Architecture Decision Records.** There is no `docs/adr/` at HEAD (`mori.dhall` declares the
`improvement-requests`, `capabilities`, and `reviews` bundles only), so no local ADR applies; no
cross-repository ADR is relevant. The MasterPlan names "the trusted-proxy policy and its default" (and the
cookie-name prefixes) as ADR-worthy. If `docs/adr/` exists when M1 starts (a sibling plan may have created
it), allocate the next handle with `okf id next docs/adr --profile docs/adr/profile.dhall ADR`; otherwise
bootstrap it as the MasterPlan's Integration Points prescribe — copy the frozen descriptor
`blueprints/adopt-architecture-decisions/files/architecture-decisions-profile.dhall` from the
`shinzui/okf-profiles` checkout (`mori path shinzui/okf-profiles`) to `docs/adr/profile.dhall`, run
`okf index docs/adr --write --okf-version 0.2`, add a `log.md`, an `adrs` `okfBundles` entry in
`mori.dhall`, and a `just adr-validate` recipe (`okf validate docs/adr --strict --profile
docs/adr/profile.dhall --profile-enforce --log-enforce`). Records are `NNNN-<slug>.md` with the profile's
frontmatter (`type: Architecture Decision Record`, `title`, `description`, `generated`, `docId: ADR-N`,
`status: Accepted`, `date`) and Context / Decision / Consequences sections.

**Terms.** *WAI* is the Haskell web-application interface: an `Application` maps a `Request` and a response
continuation to `IO`; a *middleware* is `Application -> Application`; *warp* is the HTTP server running it.
A *reverse proxy* (nginx, a cloud load balancer) terminates TLS and connects to warp from its own address,
appending the address *it* saw to `X-Forwarded-For`, so the header reads `client, proxy1, proxy2` — anything
the client sent sits left of what the proxies appended, which is why the *rightmost untrusted* entry is the
client. The *PROXY protocol* has the proxy write one line with the client address at the start of the TCP
connection; warp sets the peer from it. A *CIDR block* (`10.0.0.0/8`) is an address range. A *problem
document* is the RFC 9457 JSON body every Shōmei error carries (`docs/user/api.md:34`). The *monotonic
clock* (`getMonotonicTimeNSec`) never jumps; the wall clock (`getPOSIXTime`) does under NTP.

**What this plan owns (MasterPlan Integration Points 6, 7, 8).** EP-4 owns *what* is throttled
(`throttledPath`, `RateLimit.hs:162-172`); EP-8 owns *who* — the client key, trusted-proxy resolution, and
the clock — and neither changes the other's function. Every key added here goes to `config/shomei-types.dhall`
and `docs/user/deployment.md` in the same commit. EP-9 owns the exported host stack; since `docs/plans/59-…`
is a skeleton, this plan changes `Boot.main`'s stack through one exported function EP-9 can lift verbatim.

**The code at HEAD `5dfd2a6` (identical to reviewed `ee00382`).**
`shomei-server/src/Shomei/Server/Middleware/RateLimit.hs:177-181` keys the bucket on the peer as
`Char8.pack (show host)`; `:145` reads `realToFrac <$> getPOSIXTime`; the arithmetic at `:118-138` only
subtracts timestamps; the 429 at `:153` already uses `Shomei.Servant.Middleware.problemResponse`.
`shomei-servant/src/Shomei/Session/Handler.hs:69-77` builds `ClientIp (clientIpText peer)` from servant's
`RemoteHost` and `:134-138` renders with `show host` — the `16777343` in `shomei_login_attempts.client_ip`
(a `text` column, migration `0011`) and in the `LoginFailed`/`AccountLocked`/`LoginThrottled` payloads
(`shomei-core/src/Shomei/Audit/Event/Domain.hs:193-202`); `Shomei/OAuth/Handler.hs:81-85` is a copy used at
`:403` for the token-exchange audit; the `ClientIp` Haddock (`Session/LoginAttempt/Domain.hs:26`) promises
`"203.0.113.7"`; only `Observability/Logging.hs:154-161` renders IPv4 correctly, and it prints IPv6 as four
`Word32`s. `Middleware/BodyLimit.hs:38-41` refuses only `KnownLength n > limit` and `:43-47` answers
`413 {"error":"payload_too_large"}` as `application/json`; `test/Shomei/Server/MiddlewareSpec.hs:293-298`
pins the chunked bypass as a "documented caveat"; Servant reads the whole body before aeson parses it.
`Observability/Metrics.hs:112-116` labels `http_requests_total` with `decodeLatin1 (requestMethod req)`,
`:193-200` emits it raw, `:103,106` time the histogram with `getPOSIXTime`, `:129-134` serves `/metrics` to
anyone. `Boot.hs:118-122` composes `requestLoggingMiddleware obs . withMetrics . bodyLimitMiddleware
defaultBodyLimitBytes . rateLimitMiddleware rl`; `:138-143` sets `setOnException` but no
`setOnExceptionResponse` (an escaped exception answers warp's `500 text/plain "Something went wrong"`,
`Settings.hs:383-405`) and no `setProxyProtocol*`. `shomei-servant/src/Shomei/Servant/Auth.hs:218` and
`:278` decode `Authorization`, `Cookie`, `Origin`, `Referer` with the throwing `Text.decodeUtf8`; `:236-239`
looks up the literal `"shomei_session"`; `:284` compares `Origin` exactly; `Servant/Cookie.hs:66-70` defines
the names. `shomei-core/src/Shomei/Config.hs:227-244` is `RateLimitConfig` (defaults `:460-470`: 5 / 20 /
15 min / 15 min / 60 / 60 / on); `:112-118` is `defaultCookieConfig` with `["http://localhost:8080"]`.
`Shomei/Server/Config.hs:331-336` merges only three rate-limit keys from Dhall, `overlayCoreFromEnv`
(`:541-611`) reads none from the environment, and `csrfOriginsEnv` (`:1088-1093`) only splits and strips.
`config/shomei-types.dhall:33-35` is a *closed* record — an annotated file must carry every field — so this
plan adds keys as `Optional` (the `notifierTransport` precedent, `:22-32`) and sets them to `None` in
`config/shomei.example.dhall`; EP-6 makes omission legal later. `Shomei/Health/Server.hs:34-40` runs the
readiness query untimed and uncached. `docs/user/deployment.md` has no proxy or TLS section (grep hits only
cookie rows `:25`, `:27`); `security.md:230-245` never mentions proxies;
`docs/capabilities/abuse-protection.md:72-78` states the collapse and the chunked bypass as limits.

**Dependency facts read for this plan.** warp 3.4.15 (`mori://yesodweb/wai/packages/warp`, on disk at
`/Users/shinzui/Keikaku/hub/haskell/wai-project/wai/warp`): `setOnExceptionResponse :: (SomeException ->
Response) -> Settings -> Settings` (`Warp.hs:227`); `InvalidRequest (..)` exported (`:129`) with
`PayloadTooLarge` among its constructors (`Types.hs:36-48`); `setProxyProtocolNone/Required/Optional`
(`Warp.hs:429-462`, version 1 text header only; `HTTP1.hs:55-70` replaces the peer from it);
`settingsMaximumBodyFlush = Just 8192` (`Settings.hs:317`), so after an early 413 warp drains at most 8 KiB
and closes. wai 3.2.5: `getRequestBodyChunk`, `setRequestBodyChunks :: IO ByteString -> Request -> Request`
(`Internal.hs:100-111`). wai-extra 3.1.18 `RequestSizeLimit.hs:55-70` is the model: a known length is refused
up front, a chunked body throws from inside the body action and the middleware catches it. `network` is not
in the Mori corpus; `:browse Network.Socket` from `cabal repl shomei-server --repl-no-load` (network 3.2.9.0
per `dist-newstyle/cache/plan.json`) lists `hostAddressToTuple`, `hostAddress6ToTuple`, `getNameInfo`,
`NI_NUMERICHOST`, and no `inet_ntoa`. iproute 1.7.15 is in the plan via warp, not in the corpus; API verified
with `cabal repl shomei-server:lib:shomei-server --repl-no-load --repl-options=-package\ iproute` then
`:browse Data.IP`. servant-health 0.1.0.0: `withProbeTimeout :: Int -> Text -> ProbeCheck -> ProbeCheck`
(`Check.hs:108-112`), `type ProbeCheck = IO ProbeVerdict`; no cache combinator.

**Where tests live.** `shomei-server-test` drives the database-free `MiddlewareSpec`; `shomei-server-config-test`
drives `ConfigSpec` with `setEnv`/`unsetEnv`; `shomei-health-test` (`test-health/Main.hs`, `-threaded`) uses an
ephemeral database; `shomei-servant/test/Main.hs` runs in-process servers with `testWithApplication`.


## Plan of Work

Five milestones, each leaving `cabal test all` green and ending in one commit; run Step 0 first.

### Milestone M1 — client identity: trusted proxies, PROXY protocol, IP rendering

At the end, a request from a trusted proxy is attributed to the rightmost untrusted `X-Forwarded-For` hop
everywhere the peer is read today, IPs render as text, and deploying behind a proxy is documented.

Create `shomei-servant/src/Shomei/Servant/ClientIp.hs` (add to `exposed-modules`) exporting `clientIpText ::
SockAddr -> Text` and `clientIpOf :: SockAddr -> ClientIp`. `SockAddrInet` renders `hostAddressToTuple` as
`a.b.c.d`; `SockAddrInet6` renders `hostAddress6ToTuple`'s eight `Word16`s per RFC 5952: lowercase hex
without leading zeros (`showHex`), the longest run of two or more zero groups — leftmost on a tie —
collapsed to `::` (so `::1`, `2001:db8::`, and `2001:0:0:1::1`, where the three-zero run wins);
`SockAddrUnix` renders its path. Delete the copies at `Session/Handler.hs:134-138` and
`OAuth/Handler.hs:81-85`; `Logging.clientIp` and `RateLimit.clientKey` (`encodeUtf8 . clientIpText .
remoteHost`) use it too, so all four sites agree byte for byte.

Create `shomei-server/src/Shomei/Server/Middleware/TrustedProxy.hs` and add `iproute >=1.7.8 && <1.8` to the
library's `build-depends`:

```haskell
-- Exports: TrustedProxies, parseTrustedProxies, isTrustedPeer, forwardedClient, trustedProxyMiddleware.
import Data.IP (IP (..), IPRange (..), fromSockAddr, ipv4ToIPv6, isMatchedTo, toSockAddr)

newtype TrustedProxies = TrustedProxies [IPRange]

-- | "10.0.0.0/8", "fd00::/8", or a bare address, which means /32 or /128.
parseTrustedProxies :: [Text] -> Either Text TrustedProxies
parseTrustedProxies = fmap TrustedProxies . traverse one
  where
    one raw =
      let t = Text.strip raw
          cidr | Text.any (== '/') t = t | Text.any (== ':') t = t <> "/128" | otherwise = t <> "/32"
       in maybe (Left ("trustedProxies: " <> raw <> " is not an IP address or CIDR block")) Right
            (readMaybe (Text.unpack cidr))

isTrustedPeer :: TrustedProxies -> IP -> Bool
isTrustedPeer (TrustedProxies ranges) ip = any (inRange ip) ranges
  where
    inRange (IPv4 a) (IPv4Range r) = a `isMatchedTo` r
    inRange (IPv6 a) (IPv6Range r) = a `isMatchedTo` r
    inRange (IPv4 a) (IPv6Range r) = ipv4ToIPv6 a `isMatchedTo` r
    inRange _ _ = False

-- | When the peer is trusted: the rightmost untrusted hop, or the leftmost when every hop is trusted.
forwardedClient :: TrustedProxies -> Request -> Maybe IP
forwardedClient tp req = do
  (peer, _) <- fromSockAddr (remoteHost req)
  guard (isTrustedPeer tp peer)
  let hops = concatMap (mapMaybe parseHop . BC.split ',') [v | (k, v) <- requestHeaders req, k == "X-Forwarded-For"]
  case filter (not . isTrustedPeer tp) hops of
    [] -> listToMaybe hops
    untrusted -> listToMaybe (reverse untrusted)

-- | "203.0.113.7", "203.0.113.7:4711", "[2001:db8::1]:4711", "2001:db8::1"; anything else is ignored.
parseHop :: ByteString -> Maybe IP
parseHop raw = readMaybe (BC.unpack address)
  where
    t = BC.strip raw
    address
      | Just rest <- BC.stripPrefix "[" t = BC.takeWhile (/= ']') rest
      | BC.count ':' t == 1 = BC.takeWhile (/= ':') t
      | otherwise = t

trustedProxyMiddleware :: TrustedProxies -> Middleware
trustedProxyMiddleware tp app req =
  app case forwardedClient tp req of
    Nothing -> req
    Just ip -> req {remoteHost = toSockAddr (ip, 0)}
```

In `Shomei/Server/Config.hs` add to `ServerSettings` (`:73-89`) `serverTrustedProxies :: ![IPRange]` and
`serverProxyProtocol :: !ProxyProtocolMode` (`data ProxyProtocolMode = ProxyProtocolOff |
ProxyProtocolRequired deriving stock (Eq, Show)`); to `FileConfig` `trustedProxies :: !(Maybe [Text])` and
`proxyProtocol :: !(Maybe Text)`; defaults `[]` / `ProxyProtocolOff`; in `overlayFromEnvBoth` read
`SHOMEI_TRUSTED_PROXIES` (comma-separated, split like `csrfOriginsEnv`) and `SHOMEI_PROXY_PROTOCOL` (`none` |
`required`; anything else an `ioError` naming the variable), then `parseTrustedProxies` on whichever layer
won and `ioError` on `Left` — the boot refuses a bad entry the way it refuses a zero pool size. Dhall:
`trustedProxies : Optional (List Text)`, `proxyProtocol : Optional Text`; `None` in the example file.

In `Boot.hs` replace the `let stack = …` at `:118-122` with an exported top-level function, compose
`Warp.setProxyProtocolNone` / `Warp.setProxyProtocolRequired` from `settings.serverProxyProtocol` into
`warpSettings`, and print `[shomei] trusted proxies: <list|none>; proxy protocol: <mode>` at boot:

```haskell
-- | The WAI edge every host must install. The trusted-proxy rewrite is outermost so the logger, the
-- limiter, and the handlers all see the client; it never responds, so logging stays the outermost
-- *responding* middleware (MasterPlan 2, IP-4). EP-9 lifts this into hostMiddleware unchanged.
edgeMiddleware :: ObservabilityConfig -> TrustedProxies -> RateLimiter -> Metrics -> Middleware
edgeMiddleware obs proxies rl metrics =
  trustedProxyMiddleware proxies
    . requestLoggingMiddleware obs
    . withMetrics
    . bodyLimitMiddleware defaultBodyLimitBytes
    . rateLimitMiddleware rl
  where
    withMetrics
      | obs.metricsEnabled = metricsMiddleware metrics . metricsEndpointMiddleware metrics
      | otherwise = id
```

Tests in `MiddlewareSpec.hs`, group `trusted proxies`: build `defaultRequest {remoteHost = SockAddrInet 4711
(tupleToHostAddress (10,0,0,5)), requestHeaders = [("X-Forwarded-For", …)]}` with proxies `["10.0.0.0/8"]`,
run `trustedProxyMiddleware` with an inner application that writes `clientIpText (remoteHost req)` to an
`IORef`, and assert: (1) peer `198.51.100.9` (not trusted) with header `203.0.113.7` keeps `198.51.100.9`;
(2) trusted peer with `203.0.113.7, 10.0.0.6` yields `203.0.113.7`; (3) trusted peer with `1.2.3.4,
203.0.113.7` — the attacker's `1.2.3.4` sits left of the proxy-appended real address — yields
`203.0.113.7`; (4) `10.0.0.1, 10.0.0.2` yields `10.0.0.1`; and `parseTrustedProxies ["10.0.0.0/8", "nope"]`
is `Left`. Group `client ip rendering`: `127.0.0.1`, `2001:db8::1`, `::1`, `2001:db8:0:1::`, `2001:0:0:1::1`.

Documentation: a new `## Behind a reverse proxy` section in `deployment.md` (after "GHC runtime options in
containers") stating that TLS termination is external (no `warp-tls`; `cookieSecure` and the `Origin` check
assume an `https://` public URL); that with no `SHOMEI_TRUSTED_PROXIES` every request is attributed to the
proxy, so `maxFailedLoginsPerIp` (20 per 15 minutes, shared) locks every user out — set it to the proxy's
address or subnet, or raise `SHOMEI_MAX_FAILED_LOGINS_PER_IP` (M2) and rate-limit at the proxy; an nginx
snippet with `proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;`, `location /metrics { allow
10.0.0.0/8; deny all; }`, and `SHOMEI_TRUSTED_PROXIES=127.0.0.1/32`; the PROXY-protocol alternative
(`SHOMEI_PROXY_PROTOCOL=required`; HAProxy `send-proxy`; warp reads v1 only), noting that then *every*
connection must carry the header, orchestrator HTTP probes included. Add the two env rows and two Dhall
names. Allocate a handle with `okf id next` and create `docs/adr/NNNN-trusted-proxy-policy-and-its-default.md`
(profile frontmatter; Context / Decision / Consequences) from the second Decision Log entry; `just adr-validate`
must pass.

### Milestone M2 — per-IP knobs, origin normalization, the cookie boot warning

In `Shomei/Server/Config.hs` add `SHOMEI_RATE_LIMIT_ENABLED` (`boolEnv`), `SHOMEI_MAX_FAILED_LOGINS_PER_ACCOUNT`,
`SHOMEI_MAX_FAILED_LOGINS_PER_IP`, `SHOMEI_PER_IP_REQUESTS_PER_MINUTE`, `SHOMEI_PER_IP_BURST` (`intEnvMaybe`),
`SHOMEI_LOCKOUT_WINDOW_SECONDS`, `SHOMEI_LOCKOUT_DURATION_SECONDS` (`ttlEnv`) to `overlayCoreFromEnv`; add
`maxFailedLoginsPerIp`, `perIpBurst`, `lockoutWindowSeconds`, `lockoutDurationSeconds` to `FileConfig` and the
merge at `:331-336`; after the overlay `requirePositive` the counts and windows (a zero burst refuses every
request; a zero window disables the throttle silently). Dhall: the four keys as `Optional Natural`;
`deployment.md`: seven env rows and four Dhall names. ConfigSpec: all seven set; `SHOMEI_PER_IP_BURST=0` refused.

Add `normalizeOrigin :: Text -> Either Text Text` to `shomei-core/src/Shomei/Config.hs`: strip whitespace and
one trailing `/`; split at `://`; the scheme must be non-empty and alphabetic, the remainder non-empty and
free of `/`, `?`, `#`, and space (`Left "<raw> must be scheme://host[:port] with no path"` otherwise);
return `Text.toLower` of the whole (a port is digits, so lowercasing everything is safe). Apply it in
`Shomei/Server/Config.hs` to the Dhall `csrfAllowedOrigins` and to `csrfOriginsEnv`, `ioError` on `Left`;
browsers already send `Origin` lowercase without a slash, so `Auth.hs:284` is untouched. Add
`cookieTransportWarnings :: ShomeiConfig -> [Text]`: empty unless `transportUsesCookies cfg.tokenTransport`;
one line when `allowedOrigins == defaultCookieConfig.allowedOrigins` ("cookie transport is on with the
development default csrfAllowedOrigins = [http://localhost:8080]; browsers on any other origin get 403
csrf_rejected — set SHOMEI_CSRF_ALLOWED_ORIGINS"); one per origin that is neither `https://` nor
`http://localhost[:port]` ("… is not https; with cookieSecure the browser will not send the cookies to it").
`Boot.main` prints them through the `[shomei] WARNING:` path used for the Argon2 floor. ConfigSpec:
`HTTPS://App.Example.com/` becomes `https://app.example.com`; `https://app.example.com/login` is refused;
cookie mode with defaults warns exactly once and `["https://app.example.com"]` not at all.

### Milestone M3 — cookie prefixes

In `Servant/Cookie.hs` turn the constants at `:66-70` into `sessionCookieName cfg = if cfg.secure then
"__Host-shomei_session" else "shomei_session"` and `refreshCookieName cfg = if cfg.secure then
"__Secure-shomei_refresh" else "shomei_refresh"` over `CookieConfig`; thread `cfg.cookieConfig` through
`tokenCookies`, `clearedCookies`, and `refreshTokenFromCookie :: CookieConfig -> Text -> Maybe Text` (call
site `Session/Handler.hs:96`). In `Auth.hs` add `sessionCookie :: !ByteString` to `CookiePolicy`
(`:147-150`), fill it in `cookiePolicyFromConfig`, and make `extractTokenFromHeaders` take the
`CookiePolicy` instead of the bare `TokenTransport` so the lookup at `:238` uses `policy.sessionCookie`. In
`shomei-servant/test/Main.hs` (`:2383-2563`, default config so `secure = True`) switch `cookieValueOf`,
`sessionCookieHeader`, `refreshCookieHeader`, and the `T.isPrefixOf` lookups to the prefixed names; assert
`__Host-shomei_session=` carries `Path=/;` and `Secure`; add a `cookieConfig.secure = False` scenario
asserting the bare names. Docs: `api.md:6, 97-98, 102, 127, 139`, `security.md:97-101`, `passkeys.md:54`,
`openapi-client-generation.md:79, 83`; an `## Unreleased` Changed (breaking) entry in both CHANGELOGs saying
browser sessions are logged out once. Allocate a handle with `okf id next` and create `docs/adr/NNNN-cookie-name-prefixes.md` from the fourth
decision; `just adr-validate` must pass.

### Milestone M4 — metered bodies, problem-shaped 413 and 500, lenient headers

In `Servant/Error.hs` add `pcPayloadTooLarge = problemSpec "payload_too_large" err413 "Request body too
large"` beside `pcBadRequest`, export it, add it to `problemCatalog` (`:482`), add the row
`payload_too_large | Request body too large | 413 | no | Send a smaller body. | never` to
`docs/user/problem-details.md`, and regenerate `docs/api/openapi.json` with `cabal run shomei-openapi >
docs/api/openapi.json` (the `test-openapi` suite asserts all three agree). Rewrite `BodyLimit.hs`:

```haskell
data BodyOverCap = BodyOverCap Word64 deriving stock (Show)
instance Exception BodyOverCap

-- | Refuse a declared length above the cap unread; meter everything else as the handler reads it.
bodyLimitMiddleware :: Word64 -> Middleware
bodyLimitMiddleware limit app req respond
  | KnownLength n <- requestBodyLength req, n > limit = respond tooLarge
  | otherwise = do
      seen <- newIORef 0
      responded <- newIORef False
      let metered = do
            chunk <- getRequestBodyChunk req
            total <- atomicModifyIORef' seen \n -> let n' = n + fromIntegral (BS.length chunk) in (n', n')
            when (total > limit) (throwIO (BodyOverCap limit))
            pure chunk
          respond' res = writeIORef responded True >> respond res
      app (setRequestBodyChunks metered req) respond' `catch` \e@(BodyOverCap _) -> do
        already <- readIORef responded
        if already then throwIO e else respond tooLarge
  where
    tooLarge = problemResponse pcPayloadTooLarge noProblemOccurrence
```

The `responded` flag exists because a continuation cannot run twice: Servant reads the body before the
handler runs, so today the exception always precedes the response, but a streaming route could differ, and
then the exception goes to warp instead. Flip `testChunkedBodyPassesThrough` into
`testChunkedBodyOverCapRejected`: `requestBodyLength = ChunkedBody`, `requestBody` drawn from an `IORef`
holding three 512 KiB chunks then `""`, an inner application that drains `getRequestBodyChunk` and then
responds 200; expect 413 and no inner response. Keep a small-chunked-body case (two 4 KiB chunks → 200).
Update the module Haddock (`:8-15`) and the `abuse-protection.md` bullet.

Create `shomei-server/src/Shomei/Server/Middleware/ExceptionResponse.hs` exporting
`problemExceptionResponse :: SomeException -> Response`: a `SomeAsyncException` is re-thrown (warp's own
default does the same), `Warp.PayloadTooLarge` renders `pcPayloadTooLarge`, any other `Warp.InvalidRequest`
renders `pcBadRequest`, everything else `problemResponse pcInternal noProblemOccurrence`; compose
`Warp.setOnExceptionResponse problemExceptionResponse` into `warpSettings` (`setOnException` keeps logging
the structured line). Test: `problemExceptionResponse (toException (ErrorCall "boom"))` has status 500,
`Content-Type: application/problem+json`, and `code` `internal`. In `Auth.hs` replace `Text.decodeUtf8`
with `Text.decodeUtf8Lenient` at `:218` and `:278` (text 2.1.4; `Logging.hs` already imports it): a
`U+FFFD` in a bearer token fails verification as `401 token_invalid`, in a cookie header it is
`401 missing_token`, in `Origin` it is `403 csrf_rejected`. Add `scenarioHostileHeaders` to
`shomei-servant/test/Main.hs` (under `testWithApplication`, whose default warp settings answer a plain-text
500 for a thrown exception, so it fails at HEAD): `Authorization: Bearer \xff` on `GET /v1/auth/me` → 401
`token_invalid`; `Cookie: \xff` in cookie mode → 401 `missing_token`; `Origin: \xff` with a valid session
cookie on `POST /v1/auth/logout` → 403 `csrf_rejected`. Update `api.md`'s Errors section for the 413 and 500.

### Milestone M5 — bounded metrics, monotonic clocks, timed and cached readiness, docs

In `Metrics.hs` replace `decodeLatin1 (requestMethod req)` at `:114` with `methodLabel :: ByteString -> Text`
(the seven whitelisted methods via `decodeLatin1`, else `"other"`) and pass every value in `labels` (`:200`)
through `escapeLabelValue`, which maps `\` to `\\`, `"` to `\"`, and newline to `\n`. Test: `defaultRequest
{requestMethod = "EVIL\"}"}` through `metricsMiddleware` produces `http_requests_total{method="other",status="200"} 1`
with no unescaped quote; a second request with method `BREW` lands in the same series (count 2). Replace
`getPOSIXTime` at `Metrics.hs:103,106` and `RateLimit.hs:145` with `monotonicSeconds :: IO Double`
(`(\ns -> fromIntegral ns / 1e9) <$> getMonotonicTimeNSec`); the `takeToken` tests inject the clock. Document
`/metrics` as internal in `api.md:521` and `deployment.md:399` (deny it at the proxy, as M1's snippet shows).

In `Shomei/Health/Server.hs` introduce `data HealthPolicy = HealthPolicy {readinessTimeoutMicros :: !Int,
readinessCacheMicros :: !Int}`, `defaultHealthPolicy = HealthPolicy 2_000_000 1_000_000`, `buildHealthChecks
env = buildHealthChecksWith defaultHealthPolicy (runAppIO env listActiveSigningKeys)`, and
`buildHealthChecksWith :: HealthPolicy -> IO (Either AuthError [StoredSigningKey]) -> IO (ProbeCheck,
ProbeCheck)`, with readiness = `trackReadiness` over `cachedFor policy.readinessCacheMicros` over
`withProbeTimeout policy.readinessTimeoutMicros "postgres"` over the existing `sequenceChecks`. `cachedFor ::
Int -> ProbeCheck -> IO ProbeCheck` allocates an `MVar (Maybe (Word64, ProbeVerdict))` and returns a
`modifyMVar` that yields the cached verdict when younger than the window (`getMonotonicTimeNSec`) and
otherwise runs the check *while holding the MVar* — concurrent probes share one query; a window of 0 returns
the check unchanged. In `test-health/Main.hs` the two existing cases switch to `buildHealthChecksWith
defaultHealthPolicy {readinessCacheMicros = 0} …`; add: a counting query evaluated once for two immediate
readiness calls and again after `threadDelay 1_100_000`; a query sleeping five seconds under
`readinessTimeoutMicros = 200_000` yields `Unhealthy "postgres"` in under two seconds. Update
`observability-and-health-probes.md:61` ("computed fresh on every request").

Finish the documentation no earlier milestone touched: `security.md:230-245` gains a paragraph on client
identity behind a proxy; `architecture.md:61-62` lists trusted-proxy → logging → metrics → `/metrics` →
body cap → limiter → app; `abuse-protection.md:75-78` is rewritten around `trustedProxies` and its
`interface` list gains the new module; `shomei-server/CHANGELOG.md` gains an Unreleased entry per milestone.
Then the ADR distillation pass (the two ADRs exist) and MasterPlan 8's registry row and Progress for EP-8.


## Concrete Steps

All commands run from `/Users/shinzui/Keikaku/bokuno/shomei` inside `nix develop`, which provides GHC
9.12.4, cabal, `psql`, `just`, and the `PGHOST`/`PGDATABASE` of the dev database.

**Step 0 — observe the pre-fix behaviour once, before any code change.**

```bash
just create-database
export SHOMEI_KEY_ENCRYPTION_KEY="$(openssl rand -base64 32)"
PG_CONNECTION_STRING="host=$PGHOST dbname=$PGDATABASE user=$(id -un)" \
  cabal run shomei-server > server.log 2> server.err &
sleep 3
# 25 wrong passwords, each claiming a different client; at HEAD all count against 127.0.0.1.
for i in $(seq 1 25); do
  curl -s -o /dev/null -w '%{http_code} ' -X POST localhost:8080/v1/auth/login \
    -H 'Content-Type: application/json' -H "X-Forwarded-For: 203.0.113.$i" \
    -d '{"loginId":"nobody@example.com","password":"wrong-password-1"}'
done; echo
psql -c "SELECT client_ip, count(*) FROM shomei.shomei_login_attempts GROUP BY 1"
head -c 1114112 /dev/zero | tr '\0' 'a' > big.json     # 1 MiB + 64 KiB, sent chunked
curl -s -o /dev/null -w '%{http_code}\n' -X POST localhost:8080/v1/auth/login \
  -H 'Content-Type: application/json' -H 'Transfer-Encoding: chunked' --data-binary @big.json
curl -s -i localhost:8080/v1/auth/me -H $'Authorization: Bearer \xff' | head -2
```

Expected at HEAD (record it in Surprises & Discoveries):

```text
401 401 401 401 401 401 401 401 401 401 401 401 401 401 401 401 401 401 401 401 429 429 429 429 429
 client_ip | count
-----------+-------
 16777343  |    20
400
HTTP/1.1 500 Internal Server Error
Content-Type: text/plain; charset=utf-8
```

(The chunked body is buffered whole and fails JSON parsing as `400`.) `kill %1` before continuing.

**M1.** Create the two modules, edit the loader, `Boot.hs`, the four call sites, the Dhall files, and
`deployment.md`; then:

```bash
cabal build shomei-server && cabal test shomei-server-test --test-options='-p "middleware hardening"'
```

```text
  middleware hardening
    trusted proxies
      an untrusted peer's X-Forwarded-For is ignored:               OK
      a trusted peer yields the rightmost untrusted hop:             OK
      a spoofed hop behind a trusted proxy is not the client:        OK
      every hop trusted falls back to the chain's origin:            OK
      an invalid trusted-proxy entry is refused:                     OK
    client ip rendering
      IPv4 renders as a dotted quad:                                 OK
      IPv6 renders per RFC 5952:                                     OK
```

Live: re-run the Step 0 loop with `SHOMEI_TRUSTED_PROXIES=127.0.0.1/32` in the server's environment — all 25
answers are `401`, and the table gains `203.0.113.1 | 1` … `203.0.113.25 | 1` under the old `16777343` row;
`SHOMEI_TRUSTED_PROXIES=nope` exits with `trustedProxies: nope is not an IP address or CIDR block`. Commit:

```text
feat(server): attribute requests to the client behind trusted proxies

A trustedProxies CIDR list (SHOMEI_TRUSTED_PROXIES; default empty) and an outermost
middleware that, when the peer is trusted, rewrites remoteHost to the rightmost
X-Forwarded-For hop that is not itself trusted, so the rate limiter, loginH, the
token-exchange audit, and the request log see the client with no handler change.
Warp's PROXY protocol is exposed as SHOMEI_PROXY_PROTOCOL. Client IPs render as
dotted quads and RFC 5952 text. deployment.md gains "Behind a reverse proxy".

MasterPlan: docs/masterplans/8-trust-boundary-remediation-close-the-august-2026-security-and-performance-review.md
ExecPlan: docs/plans/58-proxy-aware-wai-edge-trusted-forwarded-headers-metered-bodies-and-bounded-metrics.md
Intention: intention_01m10kwqt9eedbjvk91rn726mq
```

**M2.** `cabal test shomei-server-config-test`; expected new lines `the rate-limit knobs read from the
environment: OK`, `a zero per-IP burst refuses to boot: OK`, `origins are normalized at load: OK`, `an
origin with a path is refused: OK`, `cookie transport with the default origin list warns once: OK`. Live:
`SHOMEI_TOKEN_TRANSPORT=cookie cabal run shomei-server` prints the `[shomei] WARNING: cookie transport …`
line before `listening on :8080`; the Step 0 loop with `SHOMEI_TRUSTED_PROXIES=127.0.0.1/32
SHOMEI_PER_IP_BURST=3` and the *same* header on every request answers `401 401 401 429 …`. Commit
`feat(config): expose every rate-limit knob and normalize CSRF origins at load`, same three trailers.

**M3.** `cabal test shomei-servant`: the cookie scenarios pass with the prefixed names plus `cookieSecure =
false keeps the bare names: OK`. Live in cookie mode, `curl -si -X POST localhost:8080/v1/auth/signup …`
shows `Set-Cookie: __Host-shomei_session=…; Path=/; …; HttpOnly; Secure; SameSite=Lax` and `Set-Cookie:
__Secure-shomei_refresh=…; Path=/v1/auth/refresh; …`. Commit `feat(servant)!: prefix the transport cookies
with __Host- and __Secure-`, same trailers.

**M4.** `cabal test shomei-server-test` and `cabal test shomei-servant`: `a chunked body over the cap is
rejected with 413: OK`, `an escaped exception renders a problem document: OK`, `hostile headers answer in
the envelope: OK`. Live, repeat Step 0's last two commands:

```text
413
HTTP/1.1 401 Unauthorized
Content-Type: application/problem+json
```

and `curl -si … --data-binary @big.json | tail -1` shows
`{"type":"…#payload_too_large","title":"Request body too large","status":413,"code":"payload_too_large","retryable":false}`.
If curl reports exit 55/56 instead, warp closed the socket after draining 8 KiB before curl finished
sending; re-run with `head -c 1052672` — the 413 is in `server.log` either way. Commit `fix(server): meter
chunked bodies and render 413 and 500 as problem documents`, same trailers.

**M5.** `cabal test shomei-server-test` (`a hostile method is labelled other and escaped: OK`) and `cabal
test shomei-health-test` (`readiness is evaluated at most once per window: OK`, `readiness times out as a
postgres failure: OK`). Live: `curl -s -X $'BR"EW' localhost:8080/ >/dev/null; curl -s
localhost:8080/metrics | grep 'method="other"'` prints `http_requests_total{method="other",status="404"} 1`;
with PostgreSQL stopped (`pg_ctl stop -m fast`) `time curl -s localhost:8080/health/ready` answers
`503 {"status":"failed","check":"postgres",…}` in about two seconds rather than ten. Finish the docs, the ADR
pass, and MasterPlan 8; then the full gate:

```bash
nix fmt && cabal build all --enable-tests && cabal test all --test-options='-j2'
```

Commit `feat(server): bound the metrics method label, use the monotonic clock, and time and cache
readiness`, same trailers.


## Validation and Acceptance

Behind a proxy: with `SHOMEI_TRUSTED_PROXIES` set to the proxy's address, after twenty failures from client
A only A receives `429 too_many_requests` while B still receives `401 invalid_login`; a request carrying
`X-Forwarded-For` from a peer that is *not* listed is attributed to that peer, so a direct-to-warp attacker
cannot choose their own bucket; `shomei_login_attempts.client_ip` and the `login_failed` audit payload read
`203.0.113.7` (an IPv6 client `2001:db8::1`). An invalid entry refuses to boot naming it. Every
`RateLimitConfig` field is settable by env and by Dhall, and `dhall-to-json --file config/shomei.example.dhall`
still succeeds against the widened schema.

Bodies and exceptions: a 1 MiB + 1 byte body answers `413` whether or not it declares a length, as
`application/problem+json` with `code: payload_too_large`, and the inner application never sees it.
`Authorization: Bearer \xff` is `401 token_invalid`; a thrown `ErrorCall` inside a handler is `500 internal`
in the envelope and still produces the structured `unhandled exception` log line. The scrape after a request
with method `BR"EW` still parses and shows `method="other"`. `/health/ready` with a stopped database answers
within ~2 s, and two probes 100 ms apart run one query. In cookie mode `GET /v1/auth/me` authenticates with
`Cookie: __Host-shomei_session=…`, a bare `shomei_session=` cookie is `401 missing_token`, and with
`SHOMEI_COOKIE_SECURE=false` the bare names return.

Tests: `cabal test all --test-options='-j2'` is green, and the defect-detecting tests fail with their fix
stashed — check once for the proxy and chunked cases by reverting just `trustedProxyMiddleware`'s rewrite
arm and just the `catch` in `BodyLimit.hs`.


## Idempotence and Recovery

Every step is a source edit plus a test run and can be repeated. No migration is added: `client_ip` is
already `text` and old rows stay as they are. The cookie rename is the one operator-visible break: rolling
back reads the old names again and browsers hold both cookies until they expire, so a rollback is safe in
either direction and browser users re-authenticate once per switch. `SHOMEI_TRUSTED_PROXIES` unset
reproduces today's attribution exactly. If `cabal run shomei-openapi` produces a diff beyond the new
`payload_too_large` entry, commit that regeneration separately. A server left running from a transcript is
`kill %1`; the dev database resets with `dropdb "$PGDATABASE" && just create-database`.


## Interfaces and Dependencies

New dependency: `iproute >=1.7.8 && <1.8` in `shomei-server`'s library stanza only (in the build plan at
1.7.15 via warp). `Data.IP`, as verified with `:browse` on 2026-08-27: `data IP = IPv4 IPv4 | IPv6 IPv6`;
`data IPRange = IPv4Range (AddrRange IPv4) | IPv6Range (AddrRange IPv6)`; `fromSockAddr :: SockAddr -> Maybe
(IP, PortNumber)`; `toSockAddr :: (IP, PortNumber) -> SockAddr`; `isMatchedTo :: Addr a => a -> AddrRange a
-> Bool`; `ipv4ToIPv6 :: IPv4 -> IPv6`; `Read` instances for `IP` and `IPRange` (the ones wai-extra
`RealIp.hs:94` and `:65-72` rely on; confirm with `:info Data.IP.IPRange`). `network` 3.2.9.0 (already in
both packages): `hostAddressToTuple`, `hostAddress6ToTuple :: HostAddress6 -> (Word16 × 8)`, and the
`tupleTo…` inverses for tests. wai 3.2.5: `getRequestBodyChunk`, `setRequestBodyChunks`. warp 3.4.15:
`setOnExceptionResponse`, `InvalidRequest (..)`, `setProxyProtocolNone/Required`. text 2.1.4:
`decodeUtf8Lenient`. servant-health 0.1.0.0: `withProbeTimeout`, `ProbeCheck`, `ProbeVerdict`.

Signatures that must exist at the end of each milestone:

```haskell
Shomei.Servant.ClientIp.clientIpText :: SockAddr -> Text                                              -- M1
Shomei.Server.Middleware.TrustedProxy.parseTrustedProxies    :: [Text] -> Either Text TrustedProxies
Shomei.Server.Middleware.TrustedProxy.forwardedClient        :: TrustedProxies -> Request -> Maybe IP
Shomei.Server.Middleware.TrustedProxy.trustedProxyMiddleware :: TrustedProxies -> Middleware
Shomei.Server.Boot.edgeMiddleware :: ObservabilityConfig -> TrustedProxies -> RateLimiter -> Metrics -> Middleware
Shomei.Config.normalizeOrigin                :: Text -> Either Text Text                              -- M2
Shomei.Server.Config.cookieTransportWarnings :: ShomeiConfig -> [Text]
Shomei.Servant.Cookie.sessionCookieName, refreshCookieName :: CookieConfig -> ByteString              -- M3
Shomei.Servant.Auth.extractTokenFromHeaders  :: CookiePolicy -> Maybe Text -> Maybe Text -> Maybe (TokenSource, Text)
Shomei.Servant.Error.pcPayloadTooLarge :: ProblemSpec                                                 -- M4
Shomei.Server.Middleware.BodyLimit.bodyLimitMiddleware :: Word64 -> Middleware   -- same type, now metered
Shomei.Server.Middleware.ExceptionResponse.problemExceptionResponse :: SomeException -> Response
Shomei.Health.Server.HealthPolicy (..), defaultHealthPolicy :: HealthPolicy                           -- M5
Shomei.Health.Server.buildHealthChecksWith :: HealthPolicy -> IO (Either AuthError [StoredSigningKey]) -> IO (ProbeCheck, ProbeCheck)
Shomei.Health.Server.cachedFor :: Int -> ProbeCheck -> IO ProbeCheck
```

Contracts this plan must not break: `RateLimit.throttledPath` and `newRateLimiter :: RateLimitConfig -> IO
RateLimiter` (EP-4 rebases onto them); the request-log field set (`Logging.hs:72-82`); the health probe wire
shape (`probeContractTests` still run against `application`); and `ShomeiConfig`'s append-only rule.
