# Access-token policy and actor-format upgrades

Access-token verification requires a positive, finite lifetime ceiling. Shōmei derives it from
the greatest configured human, machine and impersonation access-token TTL. A token must have
`exp > iat`, and `exp - iat` must fit that ceiling. Clock skew changes timestamp comparisons;
it does not enlarge the lifetime budget. An independently deployed verifier must configure the
issuer's longest legitimate TTL explicitly. In the downstream example,
`DOWNSTREAM_MAX_TOKEN_LIFETIME_SECONDS` defaults to 1800 and rejects invalid or nonpositive values
at startup. It can be tightened or increased to match the deployment.

Direct JWT consumers construct `VerifierSettings` with `maxTokenLifetime`, call
`validateVerifierSettings` before serving requests, then use `verifyTokenWith`. There is no
unbounded lifetime option. `legacyActorDeadline = Nothing` rejects legacy string actors;
`Just deadline` accepts them only before that finite UTC instant.

New delegated JWTs carry `act: {"sub":"user_…"}`, matching the actor representation in
[RFC 8693 section 4.1](https://www.rfc-editor.org/rfc/rfc8693.html#section-4.1) and introspection.
Shōmei accepts exactly that single-identity object and refuses chains and malformed values.
A present invalid actor always invalidates the token. It can never become an ordinary token by
discarding its delegation identity.

To upgrade an existing deployment, coordinate every issuer and consumer, including embedded hosts:

1. Choose one Unix-second cutoff that covers the complete rollout, the longest outstanding token
   lifetime and the greatest verifier clock skew. Configure `SHOMEI_LEGACY_ACTOR_UNTIL_UNIX` (Dhall
   `legacyActorUntilUnix`) on new readers. During the first issuer rollout, also set
   `SHOMEI_EMIT_LEGACY_ACTOR=true` (Dhall `emitLegacyActor`). This lets upgraded replicas keep
   emitting strings while old replicas and downstream readers are being replaced.
2. Upgrade all readers to the dual reader and verify a canary path before allowing object emission.
   Then set `SHOMEI_EMIT_LEGACY_ACTOR=false` and roll the issuer configuration. Leave the finite
   read deadline installed while the last legitimate string tokens expire.
3. After the cutoff, string actors are refused automatically. Legacy emission is also bounded:
   even when its flag remains true, a mint uses an object unless its expiry plus the issuer's skew
   fits before the cutoff. Size the rollout window accordingly. Remove the obsolete settings after
   completing the transition.

An old verifier that drops object actors is unsafe after object emission begins; retain the dual
reader during rollback. To resume legacy issuance within the existing window, use the explicit
flag while keeping that reader and the same deadline. Do not change signing keys or algorithms as
an incidental format rollback. The existing typ-less-token compatibility setting is separate.

`sid` remains the correlation and session-revocation identifier. Shōmei deliberately does not mint
`jti` or promise per-access-token revocation. Hosts cannot inject `act`, `jti`, `nbf`, or other
reserved claims through the extension bag. For request authentication, bearer schemes are
case-insensitive, separators are ASCII spaces, and malformed or duplicate credentials are refused.
An explicit malformed Authorization header does not fall back to a cookie.

Route captures may fail syntax parsing with HTTP 400 before authentication. This performs no
resource lookup and reveals only identifier syntax. Valid captures still pass the normal
authentication and authorization checks before any protected resource is read.
