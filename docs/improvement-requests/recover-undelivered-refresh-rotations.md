---
type: Improvement Request
title: Stop revoking sessions when a rotated refresh token never reached the client
description: Treat a replay of a spent refresh token whose replacement was never used as a retry, while keeping theft detection.
timestamp: "2026-11-01T21:33:00Z"
generated:
  by: process:claude-code
  at: "2026-11-01T20:39:41Z"
requestId: IR-4
status: rejected
resolution: "Rejected 2026-11-01: a fix that keeps Shōmei's strict reuse-detection contract was found outside this change, so Shōmei will not accept a replayed spent token; the analysed design, its security argument, and the theft window it would have accepted are preserved in the withdrawn docs/plans/69-recover-undelivered-refresh-token-rotations-without-weakening-theft-detection.md."
targetPlan: docs/plans/69-recover-undelivered-refresh-token-rotations-without-weakening-theft-detection.md
origin: mori://tan/tan-ng-labs/plans/12-keep-labs-sign-ins-alive-and-add-a-remember-me-option
---

# Recover undelivered refresh-token rotations

**Rejected on 2026-11-01.** A fix that does not require Shōmei to accept a replayed spent
token was found, so the reuse-detection contract in `docs/user/security.md` stays exactly as
it is. The design that would have implemented this request, with its security argument and
the bounded theft window it would have accepted, is preserved in the withdrawn
[ExecPlan 69](../plans/69-recover-undelivered-refresh-token-rotations-without-weakening-theft-detection.md)
in case the trade is ever reconsidered. The evidence and analysis below are kept as recorded.

A rotated refresh token can be lost on its way to the client. Shōmei commits the
rotation before the client has the new token, so a client that never receives
the response still holds the spent one. Its next refresh looks like theft, and
Shōmei revokes the session. On the labs intranet this signed a user out twice in
25 hours, both times from 365-day remembered sessions.

## Evidence

Observed on `mori://tan/tan-ng-labs`, running Shōmei `sha256:94e65408…` and
nagare-access `sha256:58813d48…`, the enforcer deployed with `mori://shinzui/nagare`
v0.11.0. Times are UTC.

| | First sign-out | Second sign-out |
|---|---|---|
| Session | `01a18454-9e2c-7494-89c2-20db7f827aa8` | `01a19340-178f-7447-a733-b4d81a89a2b0` |
| Rotation | 2026-10-31 17:50:46 | 2026-11-01 19:41:19 |
| Browser requests carrying the token | 1, disconnected after 1.75s | 4, all disconnected after about 1.17s |
| `refresh_token_reuse_detected` | 2026-10-31 18:25:11 | 2026-11-01 19:56:01 |
| Gap | 34m 25s | 14m 42s |

In both cases the gateway logged Envoy's downstream-disconnect result (status `0`,
flag `DR`) on every browser request carrying the rotated token, and the upstream
portal answered `200` after the browser had gone. In the second case the
replacement token's `used_at` is empty: it was never presented by anyone. The
first session's final replacement is also unused. The replayed token ID in each
alarm is the `oldTokenId` of the session's last `refresh_token_rotated` event.

The rotation at 2026-11-01 19:41:19 is the only one of the six recorded while its
gateway logs were available where the browser requests were dropped.

## Why the client cannot prevent this

nagare-access is a reverse proxy, so it delivers rotated cookies on the upstream
response. The window between the rotation and the `Set-Cookie` reaching the
browser includes the upstream's latency. A browser can abort in that window by
closing a tab, navigating, timing out a fetch, sleeping or losing its network.

The enforcer already coalesces concurrent refreshes and replays the result for 30
seconds (`defaultRefreshReuseSeconds`), as described in
`mori://shinzui/nagare/plans/211-keep-protected-site-sessions-across-concurrent-refreshes-and-shomei-outages`.
That protects against bursts but not against these gaps, which can last as long as
a laptop stays closed. Its map is also in memory, so every enforcer restart loses
it. Any other Shōmei client that holds refresh tokens has the same exposure.

## Current behavior

In `shomei-core/src/Shomei/Session/Authentication/Workflow.hs`, `refreshFrom` sends
every presentation of a `used` token to `reuseDetected`, which revokes the session
and its tokens. `docs/user/security.md` documents this contract. It does not check
whether the token's replacement has been used, although
`shomei_refresh_tokens.parent_token_id` and `used_at` already record that.

## Proposed behavior

When a `used` token is presented and its direct replacement is still unused, treat
the presentation as a retry of an undelivered rotation:

1. Atomically retire the unused replacement and issue a new one, keeping the same
   compare-and-swap single-winner guarantee as a normal rotation.
2. Return a normal token pair and record a distinct auth event, so retries can be
   counted and audited separately from rotations.

When the replacement has been used, the alarm fires exactly as it does today.

This must not create a way around theft detection. Today a `revoked` token returns
`SessionRevoked` without revoking the session (`refreshFrom`, the
`RefreshTokenRevoked` case). If a thief replayed a stolen token first, the
legitimate client would then be told its session had ended while the thief kept
it. So a replacement retired by this path must be distinguishable from one revoked
for other reasons, and presenting it must revoke the session and raise the alarm.
Theft is then still detected, on the legitimate client's next refresh.

## Questions to settle in design

- **Time bound:** should the retry apply only for a limited time after rotation?
  The labs gaps were 15 and 34 minutes, and a closed laptop could make them days.
  A shorter bound narrows the replay window but leaves long gaps signing people out.
- **Concurrent replays:** two simultaneous presentations of one spent token must
  still have exactly one winner. Decide what the loser receives, because the
  documented contract treats a concurrent loser as reuse.
- **Scope:** whether this applies to OAuth client sessions (`OAuthClientRefresh`) or
  only to first-party sessions (`BespokeRefresh`), and whether it is on by default
  or a `ShomeiConfig` setting.
- **Unresolved retries:** whether a session that keeps retrying without ever using a
  replacement should eventually trip the alarm.

## Acceptance

- Replaying a spent token whose replacement was never used returns a working token
  pair, leaves the session active and records the new event.
- Replaying a spent token whose replacement has been used revokes the session and
  raises `refresh_token_reuse_detected`, as it does today.
- If a thief replays first, the legitimate client's next refresh revokes the session
  and raises the alarm, and a test covers this ordering.
- Concurrent replays of one spent token issue at most one usable replacement, and a
  test covers this under real database concurrency.
- The refresh token's expiry stays capped at the session's `expiresAt`, and the retry
  keeps `remembered` unchanged.
- `docs/user/security.md` describes the new contract and the theft window it accepts.
