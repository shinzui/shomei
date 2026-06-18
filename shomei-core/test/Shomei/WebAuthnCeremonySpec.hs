{-# LANGUAGE DataKinds #-}

-- | Pure tests for the deterministic fake 'WebAuthnCeremony' interpreter
-- ('Shomei.Effect.InMemory.runWebAuthnCeremonyFake'). They prove the contract EP-3/EP-4
-- rely on: a begin step emits an options blob carrying a deterministic challenge, and a
-- complete step succeeds when the test echoes that challenge back inside a crafted
-- credential JSON (and fails closed on a mismatch). No cryptography or database is
-- involved — the real ceremony is exercised by @shomei-webauthn@'s end-to-end test.
module Shomei.WebAuthnCeremonySpec (tests) where

import Data.Aeson (Value, eitherDecodeStrict', object, (.=))
import Data.Aeson.Types (parseMaybe, withObject, (.:))
import Data.ByteString (ByteString)
import Data.ByteString.Char8 qualified as BC
import Data.IORef (newIORef)
import Data.Text (Text)
import Data.Time (UTCTime (..), fromGregorian)
import Effectful (runEff)
import Shomei.Config (ShomeiConfig (..), defaultShomeiConfig, defaultWebAuthnConfig)
import Shomei.Domain.Claims (Audience (..), Issuer (..))
import Shomei.Domain.Passkey
  ( PublicKeyBytes (..),
    SignatureCounter (..),
    UserHandle (..),
    WebAuthnCredentialId (..),
  )
import Shomei.Effect.InMemory (emptyWorld, runWebAuthnCeremonyFake)
import Shomei.Effect.WebAuthnCeremony
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
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (testCase, (@?=))

tests :: TestTree
tests =
  testGroup
    "WebAuthnCeremony (fake interpreter)"
    [ testCase "register then authenticate round-trips deterministically" registerThenAuthenticate,
      testCase "webauthnConfig default is present in defaultShomeiConfig" configHasWebAuthnDefault
    ]

t0 :: UTCTime
t0 = UTCTime (fromGregorian 2026 1 1) 0

cidBytes, uhBytes, pkBytes :: ByteString
cidBytes = BC.pack "fake-credential-id"
uhBytes = BC.pack "fake-user-handle"
pkBytes = BC.pack "fake-public-key-bytes"

sampleUser :: CredentialUserInfo
sampleUser =
  CredentialUserInfo
    { userHandle = UserHandle uhBytes,
      accountName = "alice@example.com",
      displayName = "Alice"
    }

-- | The challenge baked into a begin step's options blob (the test echoes it back).
challengeOf :: ByteString -> Text
challengeOf blob = case eitherDecodeStrict' blob of
  Right v -> case parseMaybe (withObject "options" (.: "challenge")) v of
    Just c -> c
    Nothing -> error "challengeOf: no challenge in options blob"
  Left e -> error ("challengeOf: " <> e)

-- | A credential JSON of the shape the fake expects (base64url bytes via the newtypes' JSON).
credentialJson :: Text -> ByteString -> ByteString -> ByteString -> Value
credentialJson chal cid uh pk =
  object
    [ "challenge" .= chal,
      "credentialId" .= WebAuthnCredentialId cid,
      "userHandle" .= UserHandle uh,
      "publicKey" .= PublicKeyBytes pk
    ]

registerThenAuthenticate :: IO ()
registerThenAuthenticate = do
  ref <- newIORef (emptyWorld t0)
  (regResult, wrongResult, authResult) <- runEff . runWebAuthnCeremonyFake ref $ do
    BeginCeremony {optionsBlob = regBlob} <- beginRegistrationCeremony sampleUser []
    regResult <-
      completeRegistrationCeremony regBlob (credentialJson (challengeOf regBlob) cidBytes uhBytes pkBytes)
    wrongResult <-
      completeRegistrationCeremony regBlob (credentialJson "not-the-challenge" cidBytes uhBytes pkBytes)
    BeginCeremony {optionsBlob = authBlob} <- beginAuthenticationCeremony [WebAuthnCredentialId cidBytes]
    let stored =
          StoredCredentialForVerify
            { credentialId = WebAuthnCredentialId cidBytes,
              userHandle = UserHandle uhBytes,
              publicKey = PublicKeyBytes pkBytes,
              signCounter = SignatureCounter 0,
              transports = []
            }
    authResult <-
      completeAuthenticationCeremony authBlob stored (credentialJson (challengeOf authBlob) cidBytes uhBytes pkBytes)
    pure (regResult, wrongResult, authResult)
  regResult
    @?= Right
      VerifiedRegistration
        { credentialId = WebAuthnCredentialId cidBytes,
          userHandle = UserHandle uhBytes,
          publicKey = PublicKeyBytes pkBytes,
          signCounter = SignatureCounter 0,
          transports = []
        }
  wrongResult @?= (Left WebAuthnChallengeMismatch :: Either WebAuthnError VerifiedRegistration)
  authResult
    @?= Right
      VerifiedAuthentication
        { credentialId = WebAuthnCredentialId cidBytes,
          newSignCounter = SignatureCounter 1,
          cloneWarning = False
        }

configHasWebAuthnDefault :: IO ()
configHasWebAuthnDefault =
  webauthnConfig (defaultShomeiConfig (Issuer "shomei") (Audience "shomei-clients")) @?= defaultWebAuthnConfig
