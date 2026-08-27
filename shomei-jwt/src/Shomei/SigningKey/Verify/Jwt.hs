-- jose 0.13 deprecates addClaim/unregisteredClaims in favour of payload
-- subtypes; Shōmei deliberately reads sid/scopes/roles/permissions as custom
-- claims, so we silence that one deprecation here (see the EP-4 Decision Log).
{-# OPTIONS_GHC -Wno-deprecations #-}

-- | Verifying a compact JWT back into Shōmei's 'AuthClaims', the @effectful@
-- 'TokenVerifier' interpreter, and the jose-error → 'TokenError' mapping.
--
-- 'verifyToken' is the EP-4 ↔ EP-5 contract: EP-5's Servant @Authenticated@
-- combinator runs inside an @AuthHandler@ (plain 'IO', not @effectful@), so it
-- calls this ordinary-'IO' verifier directly. The @effectful@ interpreter
-- 'runTokenVerifierJwt' is implemented on top of the same 'verifyToken'.
module Shomei.SigningKey.Verify.Jwt
  ( VerifierSettings (..),
    verifierSettingsFromConfig,
    KidSelectingKeys (..),
    checkStringOrUri,
    verifyTokenWith,
    verifyToken,
    runTokenVerifierJwt,
    jwtErrorToTokenError,
  )
where

import Crypto.JOSE.Compact (decodeCompact)
import Crypto.JOSE.Error (Error (..), runJOSE)
import Crypto.JOSE.Header (HasKid (kid), HasTyp (typ), param)
import Crypto.JOSE.JWA.JWS (Alg (ES256, RS256))
import Crypto.JOSE.JWK (JWKSet (JWKSet), jwkKid)
import Crypto.JOSE.JWK.Store (VerificationKeyStore (getVerificationKeys))
import Crypto.JOSE.JWS (header, signatures, validationSettingsAlgorithms)
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
    stringOrUri,
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
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text
import Data.Time (NominalDiffTime)
import Effectful (Eff, IOE, (:>))
import Effectful.Dispatch.Dynamic (interpret_)
import Shomei.Authorization.Claims.Domain (AuthClaims (..))
import Shomei.Authorization.Claims.Domain qualified as Domain
import Shomei.Config (ShomeiConfig (..), SigningKeyConfig (..))
import Shomei.Error (TokenError (..))
import Shomei.Id (parseId)
import Shomei.Prelude
import Shomei.Session.Token.Domain (AccessToken (AccessToken))
import Shomei.SigningKey.Verifier (TokenVerifier (VerifyAccessToken))

issuerText :: Domain.Issuer -> Text
issuerText (Domain.Issuer t) = t

audienceText :: Domain.Audience -> Text
audienceText (Domain.Audience t) = t

-- | Verification policy separated from the server's larger configuration so
-- downstream hosts can choose strict token-type enforcement independently.
data VerifierSettings = VerifierSettings
  { issuer :: !Domain.Issuer,
    audience :: !Domain.Audience,
    allowedClockSkew :: !NominalDiffTime,
    requireTokenType :: !Bool
  }
  deriving stock (Eq, Show)

verifierSettingsFromConfig :: ShomeiConfig -> VerifierSettings
verifierSettingsFromConfig cfg =
  VerifierSettings
    { issuer = cfg.issuer,
      audience = cfg.audience,
      allowedClockSkew = fromIntegral cfg.signingKeyConfig.allowedClockSkewSeconds,
      requireTokenType = False
    }

-- | A verification key store that returns only the key named by the protected
-- @kid@ header. Missing and unknown identifiers deliberately return no keys.
newtype KidSelectingKeys = KidSelectingKeys JWKSet

instance (Applicative m, HasKid h) => VerificationKeyStore m (h p) payload KidSelectingKeys where
  getVerificationKeys hdr _payload (KidSelectingKeys (JWKSet keys)) =
    pure case preview (kid . _Just . param) hdr of
      Just wanted -> filter ((== Just wanted) . view jwkKid) keys
      Nothing -> []

-- | Validate the RFC 7519 StringOrURI shape without using its partial
-- 'IsString' instance.
checkStringOrUri :: Text -> Either Text ()
checkStringOrUri value = case preview stringOrUri value of
  Just (_ :: StringOrURI) -> Right ()
  Nothing -> Left "contains ':' but is not a valid URI (RFC 7519 StringOrURI)"

-- | Verify with explicit policy. The protected @kid@ chooses exactly one public
-- key and the accepted JWS algorithms are pinned to Shōmei's ES256/RS256 set.
verifyTokenWith :: VerifierSettings -> JWKSet -> Text -> IO (Either TokenError AuthClaims)
verifyTokenWith verifierSettings jwks raw = do
  let bytes = BSL.fromStrict (Text.encodeUtf8 raw)
      matches wanted = maybe (const False) (==) (preview stringOrUri wanted)
      settings =
        defaultJWTValidationSettings (matches (audienceText verifierSettings.audience))
          & issuerPredicate
          .~ matches (issuerText verifierSettings.issuer)
          & allowedSkew
          .~ verifierSettings.allowedClockSkew
          & validationSettingsAlgorithms
          .~ Set.fromList [ES256, RS256]
  decoded <- runJOSE @JWTError do
    signed <- decodeCompact bytes
    pure (signed :: SignedJWT)
  case decoded of
    Left err -> pure (Left (jwtErrorToTokenError err))
    Right signed -> do
      let headerKid = signed ^? signatures . header . kid . _Just . param
          headerType = signed ^? signatures . header . typ . _Just . param
      result <- runJOSE @JWTError (verifyClaims settings (KidSelectingKeys jwks) signed)
      pure case result of
        Left (JWSError NoUsableKeys) -> Left (TokenKeyNotFound headerKid)
        Left err -> Left (jwtErrorToTokenError err)
        Right claims -> checkTokenType verifierSettings headerType *> claimsToAuth claims

-- | THE core/Servant contract. Existing callers receive the hardened verifier
-- through the unchanged public function.
verifyToken :: JWKSet -> ShomeiConfig -> Text -> IO (Either TokenError AuthClaims)
verifyToken jwks cfg = verifyTokenWith (verifierSettingsFromConfig cfg) jwks

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
  AlgorithmNotImplemented -> TokenSignatureInvalid
  AlgorithmMismatch _ -> TokenSignatureInvalid
  KeyMismatch _ -> TokenSignatureInvalid
  JWSInvalidSignature -> TokenSignatureInvalid
  JWSNoValidSignatures -> TokenSignatureInvalid
  JWSNoSignatures -> TokenSignatureInvalid
  NoUsableKeys -> TokenKeyNotFound Nothing
  other -> TokenOtherError (Text.pack (show other))

checkTokenType :: VerifierSettings -> Maybe Text -> Either TokenError ()
checkTokenType settings = \case
  Nothing
    | settings.requireTokenType -> Left (TokenOtherError "missing typ header")
    | otherwise -> Right ()
  Just tokenType
    | Text.toCaseFold tokenType `elem` ["at+jwt", "application/at+jwt"] -> Right ()
    | otherwise -> Left (TokenOtherError ("typ " <> tokenType <> " is not at+jwt"))

-- | Decode a verified jose 'ClaimsSet' back into Shōmei's 'AuthClaims'.
claimsToAuth :: ClaimsSet -> Either TokenError AuthClaims
claimsToAuth cs = do
  subTxt <- note "missing sub" (cs ^. claimSub >>= soText)
  subj <- mapLeft (const TokenMalformed) (parseId subTxt)
  sidTxt <- note "missing sid" (lookupString "sid")
  sess <- mapLeft (const TokenMalformed) (parseId sidTxt)
  issTxt <- note "missing iss" (cs ^. claimIss >>= soText)
  audTxt <- exactAudience (cs ^. claimAud)
  issuedAt' <- note "missing iat" (dateOf (cs ^. claimIat))
  expiresAt' <- note "missing exp" (dateOf (cs ^. claimExp))
  authTime' <- case Map.lookup "auth_time" claims of
    Nothing -> Right issuedAt'
    Just value -> case parseEither Aeson.parseJSON value of
      Left _ -> Left TokenMalformed
      Right (NumericDate t) -> Right t
  scopeValues <- lookupStringList "scopes"
  roleValues <- lookupStringList "roles"
  permissionValues <- lookupStringList "permissions"
  let scs = Set.fromList (map Domain.Scope scopeValues)
      rls = Set.fromList (map Domain.Role roleValues)
      perms = Set.fromList (map Domain.Permission permissionValues)
      -- The custom claims Shōmei manages itself; everything else in the
      -- unregistered map is the consuming service's extra bag, returned verbatim.
      -- (The registered iss/sub/aud/iat/exp claims are never in this map.)
      managed = Domain.reservedClaimKeys
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
        authTime = authTime',
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
    exactAudience = \case
      Nothing -> Left (TokenOtherError "missing aud")
      Just (Audience [singleAudience]) -> maybe (Left TokenAudienceInvalid) Right (soText singleAudience)
      Just _ -> Left TokenAudienceInvalid
    claims :: Map Text Aeson.Value
    claims = cs ^. unregisteredClaims
    lookupString k = case Map.lookup k claims of
      Just (Aeson.String s) -> Just s
      _ -> Nothing
    lookupStringList k = case Map.lookup k claims of
      Just v -> mapLeft (const TokenMalformed) (parseEither Aeson.parseJSON v)
      Nothing -> Right []
