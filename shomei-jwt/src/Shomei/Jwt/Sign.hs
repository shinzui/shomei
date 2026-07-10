-- jose 0.13 deprecates addClaim/unregisteredClaims in favour of payload
-- subtypes; Shōmei deliberately carries sid/scopes/roles as custom claims, so we
-- silence that one deprecation here (see the EP-4 Decision Log).
{-# OPTIONS_GHC -Wno-deprecations #-}

-- | Building a @jose@ 'ClaimsSet' from Shōmei's 'AuthClaims', signing it into an
-- 'AccessToken', and the @effectful@ 'TokenSigner' interpreter.
--
-- The standard claims map directly (@iss@, @sub@, @aud@, @iat@, @exp@); the session
-- id, scopes, and roles travel as the custom claims @sid@, @scopes@, @roles@. The
-- protected JWS header's @alg@ is chosen from the key material ('algForKey') and the
-- signing key's @kid@ is copied in by hand so a verifier can tell which key to use.
module Shomei.Jwt.Sign
  ( claimsFromAuth,
    claimsFromIdToken,
    signAccessToken,
    signIdToken,
    runTokenSignerJwt,
  )
where

import Control.Exception (throwIO)
import Crypto.JOSE.Compact (encodeCompact)
import Crypto.JOSE.Error (runJOSE)
import Crypto.JOSE.Header (newHeaderParamProtected)
import Crypto.JOSE.JWA.JWK (KeyMaterial (ECKeyMaterial, RSAKeyMaterial))
import Crypto.JOSE.JWA.JWS (Alg (ES256, RS256))
import Crypto.JOSE.JWK (JWK, jwkMaterial)
import Crypto.JOSE.JWS (newJWSHeaderProtected)
import Crypto.JOSE.JWS qualified as JWS
import Crypto.JWT
  ( Audience (Audience),
    ClaimsSet,
    JWTError,
    NumericDate (NumericDate),
    SignedJWT,
    StringOrURI,
    addClaim,
    claimAud,
    claimExp,
    claimIat,
    claimIss,
    claimSub,
    emptyClaimsSet,
    signClaims,
  )
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString.Lazy qualified as BSL
import Data.Set qualified as Set
import Data.String (fromString)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text
import Data.Time.Clock.POSIX (utcTimeToPOSIXSeconds)
import Effectful (Eff, IOE, (:>))
import Effectful.Dispatch.Dynamic (interpret_)
import Shomei.Config (ShomeiConfig)
import Shomei.Domain.Claims (AuthClaims (..))
import Shomei.Domain.Claims qualified as Domain
import Shomei.Domain.IdTokenClaims (IdToken (IdToken), IdTokenClaims (..))
import Shomei.Domain.Token (AccessToken (AccessToken))
import Shomei.Effect.TokenSigner (TokenSigner (SignAccessToken, SignIdToken))
import Shomei.Id (idText)
import Shomei.Jwt.Key (keyKid)
import Shomei.Prelude

issuerText :: Domain.Issuer -> Text
issuerText (Domain.Issuer t) = t

audienceText :: Domain.Audience -> Text
audienceText (Domain.Audience t) = t

-- | Build a 'StringOrURI' in the canonical form jose produces when it parses a
-- claim back from JSON (a scheme-bearing string becomes a URI, otherwise an
-- arbitrary string), so signed and verified values compare equal.
sou :: Text -> StringOrURI
sou = fromString . Text.unpack

-- | Build a @jose@ 'ClaimsSet' from Shōmei's 'AuthClaims'. Standard claims map
-- directly; session id, scopes, and roles travel as the custom claims @sid@,
-- @scopes@, @roles@.
claimsFromAuth :: AuthClaims -> ClaimsSet
claimsFromAuth ac =
  withActor $
    -- 'addExtra' seeds the custom claims into the base FIRST, then the standard
    -- registered claims (iss/sub/aud/iat/exp via typed slots) and the managed
    -- custom claims (sid/scopes/roles below, act in 'withActor') are applied on
    -- top, so a same-named custom key is always overwritten by Shōmei's value.
    -- Combined with 'mkExtraClaims' dropping reserved keys at construction, a
    -- service (or attacker-influenced input) can never forge a standard claim.
    addExtra ac.extraClaims emptyClaimsSet
      & claimIss
      ?~ sou (issuerText ac.issuer)
      & claimSub
      ?~ sou (idText ac.subject)
      & claimAud
      ?~ Audience [sou (audienceText ac.audience)]
      & claimIat
      ?~ NumericDate ac.issuedAt
      & claimExp
      ?~ NumericDate ac.expiresAt
      & addClaim "sid" (Aeson.String (idText ac.sessionId))
      & addClaim "scopes" (Aeson.toJSON (Set.toList ac.scopes))
      & addClaim "roles" (Aeson.toJSON (Set.toList ac.roles))
  where
    addExtra obj cs = KeyMap.foldrWithKey (\k v -> addClaim (Key.toText k) v) cs obj
    -- Add the @act@ claim only for delegated tokens, leaving ordinary tokens
    -- byte-identical to before this field existed.
    withActor cs = case ac.actor of
      Just uid -> cs & addClaim "act" (Aeson.String (idText uid))
      Nothing -> cs

-- | The JWS algorithm to sign with for a given key, chosen directly from the key
-- material so the header can never disagree with the key. Crucially we pick 'RS256'
-- (RSASSA-PKCS1-v1_5) for RSA keys — NOT the RSASSA-PSS variant @jose@'s
-- @bestJWSAlg@/@makeJWSHeader@ would prefer (PS512), which the legacy gateway and
-- downstream verifiers reject. Our generators only ever produce EC or RSA keys.
algForKey :: JWK -> Alg
algForKey jwk = case view jwkMaterial jwk of
  RSAKeyMaterial _ -> RS256
  ECKeyMaterial _ -> ES256
  _ -> ES256

-- | Sign an 'AuthClaims' into an 'AccessToken' using the given (active, private)
-- key. The protected header's @alg@ is pinned by 'algForKey' (RS256 for RSA, ES256
-- for EC) rather than negotiated by @makeJWSHeader@, and the key's @kid@ is copied
-- into the header by hand so a verifier can select the right key.
signAccessToken :: JWK -> AuthClaims -> IO (Either JWTError AccessToken)
signAccessToken jwk ac = do
  let hdr =
        newJWSHeaderProtected (algForKey jwk)
          & JWS.kid
          ?~ newHeaderParamProtected (keyKid jwk)
  result <- runJOSE @JWTError $ do
    signed <- signClaims jwk hdr (claimsFromAuth ac)
    pure (encodeCompact (signed :: SignedJWT))
  pure $ case result of
    Left e -> Left e
    Right wire -> Right (AccessToken (Text.decodeUtf8 (BSL.toStrict wire)))

-- | Build a @jose@ 'ClaimsSet' for an OIDC ID token (OIDC Core §2), mirroring 'claimsFromAuth'.
--
-- Deliberately narrow. @aud@ is the @client_id@, not the API audience, so the token cannot be
-- replayed at a resource server; and there is no @sid@, no @scopes@, and no @roles@, because an ID
-- token is a statement about an authentication, not a bearer credential.
--
-- @auth_time@ is a JSON /number/ of Unix seconds, as OIDC Core requires — not an RFC 3339 string,
-- which is what @toJSON \@UTCTime@ would produce and what a relying party would reject.
claimsFromIdToken :: IdTokenClaims -> ClaimsSet
claimsFromIdToken idc =
  withNonce $
    emptyClaimsSet
      & claimIss
      ?~ sou (issuerText idc.issuer)
      & claimSub
      ?~ sou (idText idc.subject)
      & claimAud
      ?~ Audience [sou idc.audience]
      & claimIat
      ?~ NumericDate idc.issuedAt
      & claimExp
      ?~ NumericDate idc.expiresAt
      & addClaim "auth_time" (Aeson.Number (fromIntegral (unixSeconds idc.authTime)))
  where
    unixSeconds :: UTCTime -> Integer
    unixSeconds = floor . utcTimeToPOSIXSeconds

    -- Present only when the authorize request sent one, so a client that sent no nonce does not
    -- receive a null it must then decide how to interpret.
    withNonce cs = case idc.nonce of
      Just n -> cs & addClaim "nonce" (Aeson.String n)
      Nothing -> cs

-- | Sign an 'IdTokenClaims' with the same active key, @alg@ and @kid@ as 'signAccessToken', so the
-- ID token verifies against the very JWKS document this deployment already publishes.
signIdToken :: JWK -> IdTokenClaims -> IO (Either JWTError IdToken)
signIdToken jwk idc = do
  let hdr =
        newJWSHeaderProtected (algForKey jwk)
          & JWS.kid
          ?~ newHeaderParamProtected (keyKid jwk)
  result <- runJOSE @JWTError $ do
    signed <- signClaims jwk hdr (claimsFromIdToken idc)
    pure (encodeCompact (signed :: SignedJWT))
  pure $ case result of
    Left e -> Left e
    Right wire -> Right (IdToken (Text.decodeUtf8 (BSL.toStrict wire)))

-- | Interpret the 'TokenSigner' effect by signing with a fixed active private key.
runTokenSignerJwt ::
  (IOE :> es) =>
  JWK ->
  ShomeiConfig ->
  Eff (TokenSigner : es) a ->
  Eff es a
runTokenSignerJwt jwk _cfg = interpret_ \case
  SignAccessToken ac -> do
    r <- liftIO (signAccessToken jwk ac)
    case r of
      Right tok -> pure tok
      Left e -> liftIO (throwIO (userError ("token signing failed: " <> show e)))
  SignIdToken idc -> do
    r <- liftIO (signIdToken jwk idc)
    case r of
      Right tok -> pure tok
      Left e -> liftIO (throwIO (userError ("id token signing failed: " <> show e)))
