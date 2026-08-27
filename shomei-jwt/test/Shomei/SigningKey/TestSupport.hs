-- | Shared fixtures for the sign/verify/interpreter specs.
module Shomei.SigningKey.TestSupport
  ( testIssuer,
    testAudience,
    testConfig,
    mkClaims,
    mkClaimsWith,
    publicJwks,
    coreFields,
  )
where

import Crypto.JOSE.JWK (JWK, JWKSet)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Time (UTCTime, addUTCTime)
import Data.Time.Clock.POSIX (utcTimeToPOSIXSeconds)
import Shomei.Authorization.Claims.Domain (Audience (..), AuthClaims (..), Issuer (..), Permission (..), Role (..), Scope (..))
import Shomei.Config (ShomeiConfig (..), defaultShomeiConfig)
import Shomei.Id (genSessionId, genUserId, idText)
import Shomei.SigningKey.Jwks.Jwt (KeySet (..), keySetPublicJwks)

testIssuer :: Issuer
testIssuer = Issuer "https://shomei.test"

testAudience :: Audience
testAudience = Audience "shomei-clients"

testConfig :: ShomeiConfig
testConfig = defaultShomeiConfig testIssuer testAudience

-- | Build claims valid from @t@ for one hour, with two scopes and one role.
mkClaims :: ShomeiConfig -> UTCTime -> IO AuthClaims
mkClaims cfg t = mkClaimsWith cfg t (addUTCTime 3600 t)

-- | Build claims with explicit @issuedAt@ and @expiresAt@ (used by the expiry test).
mkClaimsWith :: ShomeiConfig -> UTCTime -> UTCTime -> IO AuthClaims
mkClaimsWith cfg iat expd = do
  uid <- genUserId
  sid <- genSessionId
  pure
    AuthClaims
      { subject = uid,
        sessionId = sid,
        issuer = cfg.issuer,
        audience = cfg.audience,
        issuedAt = iat,
        expiresAt = expd,
        authTime = iat,
        scopes = Set.fromList [Scope "read", Scope "write"],
        roles = Set.fromList [Role "user"],
        permissions = Set.fromList [Permission "projects:write", Permission "billing:read"],
        actor = Nothing,
        extraClaims = mempty
      }

-- | The public 'JWKSet' for an active key plus any additional keys.
publicJwks :: JWK -> [JWK] -> JWKSet
publicJwks active others = keySetPublicJwks (KeySet active others)

-- | The claim fields that must survive a sign/verify round trip (timestamps are
-- excluded because JWT numeric dates are truncated to whole seconds). Identifiers
-- are compared by their rendered text form.
coreFields :: AuthClaims -> (Text, Text, Issuer, Audience, Set Scope, Set Role, Set Permission, Integer)
coreFields ac =
  ( idText ac.subject,
    idText ac.sessionId,
    ac.issuer,
    ac.audience,
    ac.scopes,
    ac.roles,
    ac.permissions,
    floor (utcTimeToPOSIXSeconds ac.authTime)
  )
