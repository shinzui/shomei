{-# LANGUAGE DataKinds #-}

{- | Tests for the real @tweag/webauthn@ ceremony interpreter
('Shomei.WebAuthn.Ceremony.runWebAuthnCeremonyLibrary').

These exercise the interpreter's plumbing — the part EP-2..EP-4 depend on but that the
upstream library does not test for us:

  * a /begin/ step produces browser-facing options JSON plus an opaque @optionsBlob@,
    and that blob round-trips through the @webauthn-json@ encoding (decode it back to the
    intermediate options type and re-encode — byte-identical), which is exactly how a
    /complete/ step recovers the options it must verify against;
  * a /complete/ step on a malformed credential payload fails with a 'WebAuthnError'
    rather than throwing.

The full cryptographic register→authenticate ceremony (real ECDSA signatures through
@verifyRegistrationResponse@/@verifyAuthenticationResponse@) is proven by EP-1's M0
spike, which ran the upstream library's own software-authenticator emulation suite on
this exact patched build (see the EP-1 plan). Re-deriving a valid COSE signature here
would require vendoring that emulator, which is out of scope for this package's test.
-}
module Shomei.WebAuthn.CeremonySpec (tests) where

import Data.Aeson (eitherDecodeStrict', encode, object)
import Data.ByteString (ByteString)
import Data.ByteString.Char8 qualified as BC
import Data.ByteString.Lazy qualified as LBS
import Data.Either (isLeft)

import Effectful (runEff)

import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, testCase)

import Crypto.WebAuthn.Encoding.WebAuthnJson qualified as WJ

import Shomei.Config (defaultWebAuthnConfig)
import Shomei.Domain.Passkey (UserHandle (..))
import Shomei.Effect.WebAuthnCeremony (
    BeginCeremony (..),
    CredentialUserInfo (..),
    beginAuthenticationCeremony,
    beginRegistrationCeremony,
    completeRegistrationCeremony,
 )
import Shomei.WebAuthn.Ceremony (runWebAuthnCeremonyLibrary)

tests :: TestTree
tests =
    testGroup
        "WebAuthn.Ceremony (real interpreter)"
        [ testCase "begin registration produces a round-tripping options blob" beginRegistrationRoundTrips
        , testCase "begin authentication produces a round-tripping options blob" beginAuthenticationRoundTrips
        , testCase "complete registration on malformed credential JSON fails closed" completeRejectsGarbage
        ]

sampleUser :: CredentialUserInfo
sampleUser =
    CredentialUserInfo
        { userHandle = UserHandle (BC.pack "sample-user-handle")
        , accountName = "ada@example.com"
        , displayName = "Ada Lovelace"
        }

beginRegistrationRoundTrips :: IO ()
beginRegistrationRoundTrips = do
    BeginCeremony{optionsBlob = blob} <-
        runEff . runWebAuthnCeremonyLibrary defaultWebAuthnConfig $ beginRegistrationCeremony sampleUser []
    assertBool "registration optionsBlob is non-empty" (not (BC.null blob))
    assertBool "registration optionsBlob round-trips through webauthn-json" (registrationBlobRoundTrips blob)

beginAuthenticationRoundTrips :: IO ()
beginAuthenticationRoundTrips = do
    BeginCeremony{optionsBlob = blob} <-
        runEff . runWebAuthnCeremonyLibrary defaultWebAuthnConfig $ beginAuthenticationCeremony []
    assertBool "authentication optionsBlob is non-empty" (not (BC.null blob))
    assertBool "authentication optionsBlob round-trips through webauthn-json" (authenticationBlobRoundTrips blob)

completeRejectsGarbage :: IO ()
completeRejectsGarbage = do
    result <- runEff . runWebAuthnCeremonyLibrary defaultWebAuthnConfig $ do
        BeginCeremony{optionsBlob = blob} <- beginRegistrationCeremony sampleUser []
        completeRegistrationCeremony blob (object [])
    assertBool "malformed credential JSON yields a WebAuthnError, not a success" (isLeft result)

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
