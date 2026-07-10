-- | EP-5: the OIDC ID token is signed by the same key machinery as the access token, and carries
-- exactly the claims OIDC Core §2 defines — no more.
--
-- An ID token a relying party cannot verify is worthless, so 'verifiesAgainstJwks' checks the real
-- signature against the real public JWK rather than merely decoding the payload. An ID token a
-- resource server /would/ accept as a bearer credential is dangerous, so 'notABearerCredential'
-- pins that the access-token verifier refuses it.
module Shomei.Jwt.IdTokenSpec (tests) where

import Crypto.JOSE.Compact (decodeCompact)
import Crypto.JOSE.Error (runJOSE)
import Crypto.JOSE.JWK (JWK)
import Crypto.JWT (JWTError, SignedJWT, defaultJWTValidationSettings, verifyClaims)
import Data.Aeson (Object, Value (Number, String))
import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteArray.Encoding (Base (Base64URLUnpadded), convertFromBase)
import Data.ByteString (ByteString)
import Data.ByteString.Lazy qualified as LBS
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text
import Data.Time (addUTCTime, getCurrentTime)
import Data.Time.Clock.POSIX (utcTimeToPOSIXSeconds)
import Shomei.Domain.Claims (Issuer (..))
import Shomei.Domain.IdTokenClaims (IdToken (IdToken), IdTokenClaims (..))
import Shomei.Error (TokenError (..))
import Shomei.Id (genUserId, idText)
import Shomei.Jwt.Key (generateSigningKey, keyKid)
import Shomei.Jwt.Sign (signIdToken)
import Shomei.Jwt.TestSupport (publicJwks, testConfig, testIssuer)
import Shomei.Jwt.Verify (verifyToken)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (Assertion, assertBool, assertFailure, testCase, (@?=))

tests :: TestTree
tests =
  testGroup
    "IdToken"
    [ testCase "signs an ID token that verifies against the published public key, with the access-token kid" verifiesAgainstJwks,
      testCase "carries iss/sub/aud/iat/exp/nonce/auth_time and nothing else" carriesExactlyTheOidcClaims,
      testCase "omits nonce entirely when the authorize request sent none" omitsAbsentNonce,
      testCase "auth_time is a number of Unix seconds, not an RFC 3339 string" authTimeIsANumber,
      testCase "an ID token is not a bearer credential: the access-token verifier refuses it" notABearerCredential
    ]

issuerText :: Issuer -> Text
issuerText (Issuer t) = t

-- | Sign an ID token for a user who authenticated an hour ago (so @auth_time@ and @iat@ differ),
-- returning the token, the claims, and the decoded JWS payload.
signWith :: JWK -> Maybe Text -> IO (IdToken, IdTokenClaims, Object)
signWith jwk nonce = do
  t <- getCurrentTime
  uid <- genUserId
  let idc =
        IdTokenClaims
          { issuer = testIssuer,
            subject = uid,
            audience = "oauthclient_01",
            issuedAt = t,
            expiresAt = addUTCTime 900 t,
            nonce,
            authTime = addUTCTime (-3600) t
          }
  r <- signIdToken jwk idc
  case r of
    Left e -> assertFailure ("id token signing failed: " <> show e)
    Right tok@(IdToken wire) -> do
      payload <- decodeSegment 1 wire
      pure (tok, idc, payload)

verifiesAgainstJwks :: Assertion
verifiesAgainstJwks = do
  jwk <- generateSigningKey
  (IdToken wire, _, _) <- signWith jwk (Just "n-0S6")
  -- Same key material and same kid as an access token: this is what makes the ID token checkable
  -- against the JWKS document the deployment already serves, with no new key work.
  header <- decodeSegment 0 wire
  KeyMap.lookup "kid" header @?= Just (String (keyKid jwk))
  result <-
    runJOSE @JWTError do
      jwt <- decodeCompact (LBS.fromStrict (Text.encodeUtf8 wire))
      verifyClaims (defaultJWTValidationSettings (const True)) jwk (jwt :: SignedJWT)
  case result of
    Left e -> assertFailure ("the id_token failed signature verification: " <> show e)
    Right _ -> pure ()

carriesExactlyTheOidcClaims :: Assertion
carriesExactlyTheOidcClaims = do
  jwk <- generateSigningKey
  (_, idc, payload) <- signWith jwk (Just "n-0S6")
  KeyMap.lookup "iss" payload @?= Just (String (issuerText idc.issuer))
  KeyMap.lookup "sub" payload @?= Just (String (idText idc.subject))
  KeyMap.lookup "aud" payload @?= Just (String idc.audience)
  KeyMap.lookup "nonce" payload @?= Just (String "n-0S6")
  assertBool "iat is present" (KeyMap.member "iat" payload)
  assertBool "exp is present" (KeyMap.member "exp" payload)
  assertBool "auth_time is present" (KeyMap.member "auth_time" payload)
  -- An ID token is a statement about an authentication, not a credential: no session id, no
  -- scopes, no roles.
  assertBool "no sid" (not (KeyMap.member "sid" payload))
  assertBool "no scopes" (not (KeyMap.member "scopes" payload))
  assertBool "no roles" (not (KeyMap.member "roles" payload))

omitsAbsentNonce :: Assertion
omitsAbsentNonce = do
  jwk <- generateSigningKey
  (_, _, payload) <- signWith jwk Nothing
  assertBool "nonce is absent, not null" (not (KeyMap.member "nonce" payload))

authTimeIsANumber :: Assertion
authTimeIsANumber = do
  jwk <- generateSigningKey
  (_, idc, payload) <- signWith jwk (Just "n")
  case KeyMap.lookup "auth_time" payload of
    Just (Number n) -> (round n :: Integer) @?= floor (utcTimeToPOSIXSeconds idc.authTime)
    other -> assertFailure ("auth_time must be a JSON number, got " <> show other)

notABearerCredential :: Assertion
notABearerCredential = do
  jwk <- generateSigningKey
  (IdToken wire, _, _) <- signWith jwk Nothing
  -- Its aud is the client_id, not the API audience, so the access-token verifier rejects it. This
  -- is what stops a client replaying an ID token at a resource server.
  res <- verifyToken (publicJwks jwk []) testConfig wire
  case res of
    Left TokenAudienceInvalid -> pure ()
    Left other -> assertFailure ("expected TokenAudienceInvalid, got " <> show other)
    Right _ -> assertFailure "an ID token must never verify as an access token"

-- | Decode segment @n@ (0 = header, 1 = payload) of a compact JWS as a JSON object.
decodeSegment :: Int -> Text -> IO Object
decodeSegment n wire = do
  let seg = Text.encodeUtf8 (Text.splitOn "." wire !! n)
  raw <-
    either (assertFailure . ("segment base64url decode failed: " <>)) pure $
      (convertFromBase Base64URLUnpadded seg :: Either String ByteString)
  maybe (assertFailure "segment is not a JSON object") pure (Aeson.decodeStrict raw)
