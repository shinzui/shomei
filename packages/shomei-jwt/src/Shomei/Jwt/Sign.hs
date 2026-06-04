-- jose 0.13 deprecates addClaim/unregisteredClaims in favour of payload
-- subtypes; Shōmei deliberately carries sid/scopes/roles as custom claims, so we
-- silence that one deprecation here (see the EP-4 Decision Log).
{-# OPTIONS_GHC -Wno-deprecations #-}

{- | Building a @jose@ 'ClaimsSet' from Shōmei's 'AuthClaims', signing it into an
'AccessToken', and the @effectful@ 'TokenSigner' interpreter.

The standard claims map directly (@iss@, @sub@, @aud@, @iat@, @exp@); the session
id, scopes, and roles travel as the custom claims @sid@, @scopes@, @roles@. The
signing key's @kid@ is copied into the protected JWS header by 'makeJWSHeader' so
a verifier can tell which key to use.
-}
module Shomei.Jwt.Sign (
    claimsFromAuth,
    signAccessToken,
    runTokenSignerJwt,
) where

import Shomei.Prelude

import Shomei.Config (ShomeiConfig)
import Shomei.Domain.Claims (AuthClaims (..))
import Shomei.Domain.Claims qualified as Domain
import Shomei.Domain.Token (AccessToken (AccessToken))
import Shomei.Id (idText)
import Shomei.Port.TokenSigner (TokenSigner (SignAccessToken))

import Control.Exception (throwIO)
import Data.Aeson qualified as Aeson
import Data.ByteString.Lazy qualified as BSL
import Data.Set qualified as Set
import Data.String (fromString)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text
import Effectful (Eff, IOE, (:>))
import Effectful.Dispatch.Dynamic (interpret_)
import "jose" Crypto.JOSE.Compact (encodeCompact)
import "jose" Crypto.JOSE.Error (runJOSE)
import "jose" Crypto.JOSE.JWK (JWK)
import "jose" Crypto.JOSE.JWS (makeJWSHeader)
import "jose" Crypto.JWT (
    Audience (Audience),
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

issuerText :: Domain.Issuer -> Text
issuerText (Domain.Issuer t) = t

audienceText :: Domain.Audience -> Text
audienceText (Domain.Audience t) = t

{- | Build a 'StringOrURI' in the canonical form jose produces when it parses a
claim back from JSON (a scheme-bearing string becomes a URI, otherwise an
arbitrary string), so signed and verified values compare equal.
-}
sou :: Text -> StringOrURI
sou = fromString . Text.unpack

{- | Build a @jose@ 'ClaimsSet' from Shōmei's 'AuthClaims'. Standard claims map
directly; session id, scopes, and roles travel as the custom claims @sid@,
@scopes@, @roles@.
-}
claimsFromAuth :: AuthClaims -> ClaimsSet
claimsFromAuth ac =
    emptyClaimsSet
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

{- | Sign an 'AuthClaims' into an 'AccessToken' using the given (active, private)
key. 'makeJWSHeader' selects the algorithm via @bestJWSAlg@ and copies the key's
@kid@ into the protected header.
-}
signAccessToken :: JWK -> AuthClaims -> IO (Either JWTError AccessToken)
signAccessToken jwk ac = do
    result <- runJOSE @JWTError $ do
        hdr <- makeJWSHeader jwk
        signed <- signClaims jwk hdr (claimsFromAuth ac)
        pure (encodeCompact (signed :: SignedJWT))
    pure $ case result of
        Left e -> Left e
        Right wire -> Right (AccessToken (Text.decodeUtf8 (BSL.toStrict wire)))

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
