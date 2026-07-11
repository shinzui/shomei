-- jose 0.13 deprecates addClaim/unregisteredClaims in favour of payload
-- subtypes; Shōmei deliberately reads sid/scopes/roles as custom claims, so we
-- silence that one deprecation here (see the EP-4 Decision Log).
{-# OPTIONS_GHC -Wno-deprecations #-}

-- | Verifying a compact JWT back into Shōmei's 'AuthClaims', the @effectful@
-- 'TokenVerifier' interpreter, and the jose-error → 'TokenError' mapping.
--
-- 'verifyToken' is the EP-4 ↔ EP-5 contract: EP-5's Servant @Authenticated@
-- combinator runs inside an @AuthHandler@ (plain 'IO', not @effectful@), so it
-- calls this ordinary-'IO' verifier directly. The @effectful@ interpreter
-- 'runTokenVerifierJwt' is implemented on top of the same 'verifyToken'.
module Shomei.Jwt.Verify
  ( verifyToken,
    runTokenVerifierJwt,
    jwtErrorToTokenError,
  )
where

import Crypto.JOSE.Compact (decodeCompact)
import Crypto.JOSE.Error (Error (..), runJOSE)
import Crypto.JOSE.JWK (JWKSet)
import Crypto.JWT
  ( Audience (Audience),
    ClaimsSet,
    JWTError (..),
    NumericDate (NumericDate),
    SignedJWT,
    StringOrURI,
    allowedSkew,
    claimAud,
    claimExp,
    claimIat,
    claimIss,
    claimSub,
    defaultJWTValidationSettings,
    issuerPredicate,
    unregisteredClaims,
    verifyClaims,
  )
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Aeson.Types (parseEither)
import Data.ByteString.Lazy qualified as BSL
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.String (fromString)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text
import Effectful (Eff, IOE, (:>))
import Effectful.Dispatch.Dynamic (interpret_)
import Shomei.Config (ShomeiConfig (..))
import Shomei.Domain.Claims (AuthClaims (..))
import Shomei.Domain.Claims qualified as Domain
import Shomei.Domain.Token (AccessToken (AccessToken))
import Shomei.Effect.TokenVerifier (TokenVerifier (VerifyAccessToken))
import Shomei.Error (TokenError (..))
import Shomei.Id (parseId)
import Shomei.Prelude

issuerText :: Domain.Issuer -> Text
issuerText (Domain.Issuer t) = t

audienceText :: Domain.Audience -> Text
audienceText (Domain.Audience t) = t

-- | Build a 'StringOrURI' the same way 'Shomei.Jwt.Sign' does, so the issuer and
-- audience predicates compare equal to the values jose decodes from the token.
sou :: Text -> StringOrURI
sou = fromString . Text.unpack

-- | THE EP-4 ↔ EP-5 CONTRACT. Verify a compact JWT string against a public
-- 'JWKSet', applying the issuer and audience checks from the config with zero
-- clock skew. The 'JWKSet' supplies the candidate keys; jose tries each one.
verifyToken :: JWKSet -> ShomeiConfig -> Text -> IO (Either TokenError AuthClaims)
verifyToken jwks cfg raw = do
  let settings =
        defaultJWTValidationSettings (== sou (audienceText cfg.audience))
          & issuerPredicate
          .~ (\iss -> iss == sou (issuerText cfg.issuer))
          & allowedSkew
          .~ 0
      bytes = BSL.fromStrict (Text.encodeUtf8 raw)
  result <- runJOSE @JWTError $ do
    signed <- decodeCompact bytes
    verifyClaims settings jwks (signed :: SignedJWT)
  pure $ case result of
    Left e -> Left (jwtErrorToTokenError e)
    Right cs -> claimsToAuth cs

-- | Interpret the 'TokenVerifier' effect over a fixed public 'JWKSet'.
runTokenVerifierJwt ::
  (IOE :> es) =>
  JWKSet ->
  ShomeiConfig ->
  Eff (TokenVerifier : es) a ->
  Eff es a
runTokenVerifierJwt jwks cfg = interpret_ \case
  VerifyAccessToken (AccessToken raw) -> liftIO (verifyToken jwks cfg raw)

-- | Map jose's 'JWTError' into the core's transport-agnostic 'TokenError'.
jwtErrorToTokenError :: JWTError -> TokenError
jwtErrorToTokenError = \case
  JWTExpired -> TokenExpired
  JWTNotYetValid -> TokenOtherError "token not yet valid"
  JWTNotInIssuer -> TokenIssuerInvalid
  JWTNotInAudience -> TokenAudienceInvalid
  JWTIssuedAtFuture -> TokenOtherError "iat in the future"
  JWTClaimsSetDecodeError _ -> TokenMalformed
  JWSError e -> jwsErrorToTokenError e

-- | Map the inner JWS 'Error' (wrapped by 'JWSError') into a 'TokenError'.
jwsErrorToTokenError :: Error -> TokenError
jwsErrorToTokenError = \case
  CompactDecodeError _ -> TokenMalformed
  JSONDecodeError _ -> TokenMalformed
  JWSInvalidSignature -> TokenSignatureInvalid
  JWSNoValidSignatures -> TokenSignatureInvalid
  JWSNoSignatures -> TokenSignatureInvalid
  NoUsableKeys -> TokenSignatureInvalid
  other -> TokenOtherError (Text.pack (show other))

-- | Decode a verified jose 'ClaimsSet' back into Shōmei's 'AuthClaims'.
claimsToAuth :: ClaimsSet -> Either TokenError AuthClaims
claimsToAuth cs = do
  subTxt <- note "missing sub" (cs ^. claimSub >>= soText)
  subj <- mapLeft (const TokenMalformed) (parseId subTxt)
  sidTxt <- note "missing sid" (lookupString "sid")
  sess <- mapLeft (const TokenMalformed) (parseId sidTxt)
  issTxt <- note "missing iss" (cs ^. claimIss >>= soText)
  audTxt <- note "missing aud" (firstAudience (cs ^. claimAud))
  issuedAt' <- note "missing iat" (dateOf (cs ^. claimIat))
  expiresAt' <- note "missing exp" (dateOf (cs ^. claimExp))
  let scs = Set.fromList (map Domain.Scope (lookupStringList "scopes"))
      rls = Set.fromList (map Domain.Role (lookupStringList "roles"))
      perms = Set.fromList (map Domain.Permission (lookupStringList "permissions"))
      -- The custom claims Shōmei manages itself; everything else in the
      -- unregistered map is the consuming service's extra bag, returned verbatim.
      -- (The registered iss/sub/aud/iat/exp claims are never in this map.)
      managed = ["sid", "scopes", "roles", "permissions", "act"]
      extra =
        KeyMap.fromList
          [ (Key.fromText k, v)
          | (k, v) <- Map.toList claims,
            k `notElem` managed
          ]
  -- The @act@ claim is present only on delegated (impersonation) tokens. Absent
  -- → 'Nothing'; present but unparseable → a malformed token.
  actor' <- case lookupString "act" of
    Nothing -> Right Nothing
    Just actTxt -> Just <$> mapLeft (const TokenMalformed) (parseId actTxt)
  pure
    AuthClaims
      { subject = subj,
        sessionId = sess,
        issuer = Domain.Issuer issTxt,
        audience = Domain.Audience audTxt,
        issuedAt = issuedAt',
        expiresAt = expiresAt',
        scopes = scs,
        roles = rls,
        permissions = perms,
        actor = actor',
        extraClaims = extra
      }
  where
    note msg = maybe (Left (TokenOtherError msg)) Right
    mapLeft f = either (Left . f) Right
    -- jose serialises a StringOrURI (whether arbitrary string or URI) as a JSON
    -- string, so toJSON recovers the original text for both forms.
    soText :: StringOrURI -> Maybe Text
    soText s = case Aeson.toJSON s of
      Aeson.String t -> Just t
      _ -> Nothing
    dateOf = fmap (\(NumericDate t) -> t)
    firstAudience mau =
      mau >>= \(Audience xs) -> case xs of
        (x : _) -> soText x
        [] -> Nothing
    claims :: Map Text Aeson.Value
    claims = cs ^. unregisteredClaims
    lookupString k = case Map.lookup k claims of
      Just (Aeson.String s) -> Just s
      _ -> Nothing
    lookupStringList k = case Map.lookup k claims of
      Just v -> either (const []) id (parseEither Aeson.parseJSON v)
      Nothing -> []
