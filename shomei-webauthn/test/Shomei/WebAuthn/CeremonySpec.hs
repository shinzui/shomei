{-# LANGUAGE DataKinds #-}

-- | Tests for the real @tweag/webauthn@ ceremony interpreter
-- ('Shomei.WebAuthn.Ceremony.runWebAuthnCeremonyLibrary').
--
-- Signed wire fixtures exercise the production decoder and verifier without a browser.
module Shomei.WebAuthn.CeremonySpec (tests) where

import Crypto.WebAuthn.Encoding.WebAuthnJson qualified as WJ
import Data.Aeson (Value, eitherDecodeStrict', encode, object)
import Data.Aeson.Types (parseEither, withObject, (.:))
import Data.ByteString (ByteString)
import Data.ByteString.Char8 qualified as BC
import Data.ByteString.Lazy qualified as LBS
import Data.Either (isLeft)
import Data.Text (Text)
import Effectful (runEff)
import Shomei.Config
  ( AttestationPolicy (..),
    UserVerificationPolicy (UVDiscouraged, UVRequired),
    WebAuthnConfig (attestation, origins, userVerification),
    defaultWebAuthnConfig,
  )
import Shomei.Passkey.Ceremony.Port
  ( BeginCeremony (..),
    CredentialUserInfo (..),
    StoredCredentialForVerify (..),
    VerifiedAuthentication (..),
    VerifiedRegistration (..),
    WebAuthnError (..),
    beginAuthenticationCeremony,
    beginRegistrationCeremony,
    completeAuthenticationCeremony,
    completeRegistrationCeremony,
  )
import Shomei.Passkey.Domain (SignatureCounter (..), UserHandle (..), b64urlEncode)
import Shomei.WebAuthn.Ceremony (runWebAuthnCeremonyLibrary)
import Shomei.WebAuthn.SoftwareAuthenticator
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, testCase, (@?=))

tests :: TestTree
tests =
  testGroup
    "WebAuthn.Ceremony (real interpreter)"
    [ testCase "direct requests evidence without enforcing authenticator trust" directAttestationBoundary,
      testCase "signed ES256 registration then assertion succeeds through the real interpreter" signedRoundTrip,
      testCase "signed policy mutations fail at their intended verifier boundary" signedPolicyNegatives,
      testCase "counterless, advancing, repeated and regressed counters follow policy" signedCounterPolicy,
      testCase "begin registration produces a round-tripping options blob" beginRegistrationRoundTrips,
      testCase "begin authentication produces a round-tripping options blob" beginAuthenticationRoundTrips,
      testCase "passwordless authentication requires UV even when step-up discourages it" passwordlessRequiresUv,
      testCase "complete registration on malformed credential JSON fails closed" completeRejectsGarbage,
      testCase "empty origins fail closed before credential decoding" emptyOriginsFailClosed
    ]

sampleUser :: CredentialUserInfo
sampleUser =
  CredentialUserInfo
    { userHandle = UserHandle (BC.pack "sample-user-handle"),
      accountName = "ada@example.com",
      displayName = "Ada Lovelace"
    }

beginRegistrationRoundTrips :: IO ()
beginRegistrationRoundTrips = do
  BeginCeremony {optionsBlob = blob} <-
    runEff . runWebAuthnCeremonyLibrary defaultWebAuthnConfig $ beginRegistrationCeremony sampleUser []
  assertBool "registration optionsBlob is non-empty" (not (BC.null blob))
  assertBool "registration optionsBlob round-trips through webauthn-json" (registrationBlobRoundTrips blob)

beginAuthenticationRoundTrips :: IO ()
beginAuthenticationRoundTrips = do
  BeginCeremony {optionsBlob = blob} <-
    runEff . runWebAuthnCeremonyLibrary defaultWebAuthnConfig $
      beginAuthenticationCeremony (userVerification defaultWebAuthnConfig) []
  assertBool "authentication optionsBlob is non-empty" (not (BC.null blob))
  assertBool "authentication optionsBlob round-trips through webauthn-json" (authenticationBlobRoundTrips blob)
  decodeUserVerification blob @?= Right "preferred"

passwordlessRequiresUv :: IO ()
passwordlessRequiresUv = do
  let cfg = defaultWebAuthnConfig {userVerification = UVDiscouraged}
  BeginCeremony {optionsBlob = blob} <-
    runEff . runWebAuthnCeremonyLibrary cfg $ beginAuthenticationCeremony UVRequired []
  decodeUserVerification blob @?= Right "required"

completeRejectsGarbage :: IO ()
completeRejectsGarbage = do
  result <- runEff . runWebAuthnCeremonyLibrary defaultWebAuthnConfig $ do
    BeginCeremony {optionsBlob = blob} <- beginRegistrationCeremony sampleUser []
    completeRegistrationCeremony blob (object [])
  assertBool "malformed credential JSON yields a WebAuthnError, not a success" (isLeft result)

emptyOriginsFailClosed :: IO ()
emptyOriginsFailClosed = do
  let cfg = defaultWebAuthnConfig {origins = []}
  result <- runEff . runWebAuthnCeremonyLibrary cfg $ completeRegistrationCeremony "garbage" (object [])
  result @?= Left (WebAuthnOtherError "no allowed WebAuthn origins are configured")

-- | Decode the persisted blob back to the WJ intermediate registration options type
-- and re-encode it; the bytes must be identical (this is the recovery path the
-- interpreter's @completeRegistration@ uses).
registrationBlobRoundTrips :: ByteString -> Bool
registrationBlobRoundTrips blob = case eitherDecodeStrict' blob of
  Right opts -> LBS.toStrict (encode (opts :: WJ.WJCredentialOptionsRegistration)) == blob
  Left _ -> False

authenticationBlobRoundTrips :: ByteString -> Bool
authenticationBlobRoundTrips blob = case eitherDecodeStrict' blob of
  Right opts -> LBS.toStrict (encode (opts :: WJ.WJCredentialOptionsAuthentication)) == blob
  Left _ -> False

decodeUserVerification :: ByteString -> Either String Text
decodeUserVerification blob = do
  value <- eitherDecodeStrict' blob :: Either String Value
  parseEither (withObject "authentication options" (.: "userVerification")) value

signedConfig :: WebAuthnConfig
signedConfig = defaultWebAuthnConfig {origins = ["https://localhost"], userVerification = UVRequired}

fixedRegistration :: IO (Value, VerifiedRegistration)
fixedRegistration = do
  BeginCeremony {optionsJson} <- runEff . runWebAuthnCeremonyLibrary signedConfig $ beginRegistrationCeremony sampleUser []
  let options = freezeChallenge optionsJson
  result <- runEff . runWebAuthnCeremonyLibrary signedConfig $ completeRegistrationCeremony (LBS.toStrict (encode options)) (registrationResponse options goodPolicy {responseCounter = 0})
  case result of
    Left err -> error ("valid registration rejected: " <> show err)
    Right credential -> pure (options, credential)

storedFrom :: VerifiedRegistration -> SignatureCounter -> StoredCredentialForVerify
storedFrom VerifiedRegistration {credentialId, userHandle, publicKey, transports} counter = StoredCredentialForVerify credentialId userHandle publicKey counter transports

assertWith :: VerifiedRegistration -> SignatureCounter -> ResponsePolicy -> IO (Either WebAuthnError VerifiedAuthentication)
assertWith credential counter policy = do
  BeginCeremony {optionsJson} <- runEff . runWebAuthnCeremonyLibrary signedConfig $ beginAuthenticationCeremony UVRequired []
  let options = freezeChallenge optionsJson
  runEff . runWebAuthnCeremonyLibrary signedConfig $ completeAuthenticationCeremony (LBS.toStrict (encode options)) (storedFrom credential counter) (assertionResponse options policy)

signedRoundTrip :: IO ()
signedRoundTrip = do
  (_, credential) <- fixedRegistration
  let VerifiedRegistration {userHandle} = credential
  userHandle @?= UserHandle (BC.pack "sample-user-handle")
  result <- assertWith credential (SignatureCounter 0) goodPolicy {responseHandle = "sample-user-handle"}
  case result of
    Right VerifiedAuthentication {newSignCounter} -> newSignCounter @?= SignatureCounter 1
    Left err -> error (show err)

signedPolicyNegatives :: IO ()
signedPolicyNegatives = do
  (_, credential) <- fixedRegistration
  let valid = goodPolicy {responseHandle = "sample-user-handle"}
  sequence_
    [ assertWith credential (SignatureCounter 0) policy >>= (@?= Left expected)
    | (policy, expected) <-
        [ (valid {responseOrigin = "https://evil.example"}, WebAuthnOriginMismatch),
          (valid {responseRp = "evil.example"}, WebAuthnRpIdMismatch),
          (valid {responseChallenge = Just (b64urlEncode "wrong-challenge")}, WebAuthnChallengeMismatch),
          (valid {responseFlags = 1}, WebAuthnUserNotVerified),
          (valid {responseFlags = 4}, WebAuthnUserNotPresent),
          (valid {corruptSignature = True}, WebAuthnSignatureInvalid)
        ]
    ]
  BeginCeremony {optionsBlob = authBlob} <- runEff . runWebAuthnCeremonyLibrary signedConfig $ beginAuthenticationCeremony UVRequired []
  malformed <- runEff . runWebAuthnCeremonyLibrary signedConfig $ completeAuthenticationCeremony authBlob (storedFrom credential (SignatureCounter 0)) (object [])
  assertBool "malformed assertion fails closed" (isLeft malformed)
  emptyOrigin <- runEff . runWebAuthnCeremonyLibrary signedConfig {origins = []} $ completeAuthenticationCeremony authBlob (storedFrom credential (SignatureCounter 0)) (object [])
  emptyOrigin @?= Left (WebAuthnOtherError "no allowed WebAuthn origins are configured")
  crossUser <- assertWith credential (SignatureCounter 0) valid {responseHandle = "another-user"}
  assertBool "a correctly signed assertion from a different user fails" (isLeft crossUser)
  wrongType <- assertWith credential (SignatureCounter 0) valid {responseType = Just "webauthn.create"}
  assertBool "create client data cannot satisfy get" (isLeft wrongType)
  (options, _) <- fixedRegistration
  let register policy = runEff . runWebAuthnCeremonyLibrary signedConfig $ completeRegistrationCeremony (LBS.toStrict (encode options)) (registrationResponse options policy)
  sequence_
    [ register policy >>= (@?= Left expected)
    | (policy, expected) <-
        [ (valid {responseOrigin = "https://evil.example"}, WebAuthnOriginMismatch),
          (valid {responseRp = "evil.example"}, WebAuthnRpIdMismatch),
          (valid {responseChallenge = Just (b64urlEncode "wrong-challenge")}, WebAuthnChallengeMismatch),
          (valid {responseFlags = 4}, WebAuthnUserNotPresent),
          (valid {responseFlags = 1}, WebAuthnUserNotVerified)
        ]
    ]
  badRegistrationType <- register valid {responseType = Just "webauthn.get"}
  assertBool "get client data cannot satisfy create" (isLeft badRegistrationType)

signedCounterPolicy :: IO ()
signedCounterPolicy = do
  (_, credential) <- fixedRegistration
  let valid = goodPolicy {responseHandle = "sample-user-handle"}
  zero <- assertWith credential (SignatureCounter 0) valid {responseCounter = 0}
  case zero of
    Right VerifiedAuthentication {newSignCounter} -> newSignCounter @?= SignatureCounter 0
    Left err -> error (show err)
  advancing <- assertWith credential (SignatureCounter 3) valid {responseCounter = 4}
  case advancing of
    Right VerifiedAuthentication {newSignCounter} -> newSignCounter @?= SignatureCounter 4
    Left err -> error (show err)
  sequence_ [assertWith credential (SignatureCounter 3) valid {responseCounter = n} >>= (@?= Left WebAuthnCounterCloned) | n <- [3, 2, 0]]

directAttestationBoundary :: IO ()
directAttestationBoundary = do
  (options, _) <- fixedRegistration
  let direct = signedConfig {attestation = AttestationDirect}
  BeginCeremony {optionsJson} <- runEff . runWebAuthnCeremonyLibrary direct $ beginRegistrationCeremony sampleUser []
  parseEither (withObject "options" (.: "attestation")) optionsJson @?= Right ("direct" :: Text)
  result <- runEff . runWebAuthnCeremonyLibrary direct $ completeRegistrationCeremony (LBS.toStrict (encode options)) (registrationResponse options goodPolicy)
  assertBool "direct is a conveyance request, not a device allow-list" (not (isLeft result))
