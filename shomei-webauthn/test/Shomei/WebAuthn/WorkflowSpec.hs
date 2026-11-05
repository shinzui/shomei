{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE TypeOperators #-}

module Shomei.WebAuthn.WorkflowSpec (tests) where

import Control.Monad (forM_)
import Data.Aeson (Value, encode)
import Data.Aeson.Types (parseMaybe, withObject, (.:))
import Data.ByteString.Lazy qualified as LBS
import Data.IORef (IORef, modifyIORef', newIORef, readIORef)
import Data.Map.Strict qualified as Map
import Data.Time (UTCTime (..), addUTCTime, fromGregorian)
import Effectful (Eff, IOE, liftIO, runEff, (:>))
import Effectful.Dispatch.Dynamic (interpose)
import Shomei.Account.LoginId.Domain (LoginId, mkLoginId)
import Shomei.Account.Password.Domain (PlainPassword (..))
import Shomei.Account.User.Domain (NewUser (..), User (..))
import Shomei.Account.User.Store (createUser)
import Shomei.Audit.Event.Domain qualified as Event
import Shomei.Authorization.Claims.Domain (Audience (..), Issuer (..))
import Shomei.Config (ShomeiConfig (..), UserVerificationPolicy (..), WebAuthnConfig (..), defaultShomeiConfig, defaultWebAuthnConfig)
import Shomei.Error (AuthError (..))
import Shomei.Id (genCeremonyId)
import Shomei.Mfa.Workflow (MfaCompletion (..), beginPasswordlessLogin, completeMfa, completePasswordlessLogin)
import Shomei.Passkey.Ceremony.Port
import Shomei.Passkey.Ceremony.Store (putPendingCeremony)
import Shomei.Passkey.Domain (CeremonyKind (..), PasskeyCredential (..), PendingCeremony (..), SignatureCounter (..), b64urlDecode)
import Shomei.Passkey.Workflow (beginPasskeyRegistration, completePasskeyRegistration)
import Shomei.Session.Authentication.Workflow (LoginResult (..), MfaChallenge (..), login, signup)
import Shomei.Session.Command (ClientContext (..), LoginCommand (..), ProofContext (..), SignupCommand (..))
import Shomei.Session.LoginAttempt.Domain (AccountKey (..), ClientIp (..))
import Shomei.Test.InMemory (InMemoryPorts, World (..), emptyWorld, runInMemory)
import Shomei.WebAuthn.Ceremony (runWebAuthnCeremonyLibrary)
import Shomei.WebAuthn.SoftwareAuthenticator
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

-- Storage, Clock, signing and password hashes use the normal fake stack. Only the
-- ceremony effect is interposed, and every completion runs the production verifier.
-- Freeze each challenge after the real begin step so fixture payloads are reproducible.
realCeremonies :: (WebAuthnCeremony :> es, IOE :> es) => WebAuthnConfig -> Eff es a -> Eff es a
realCeremonies cfg = interpose \_ -> \case
  BeginRegistrationCeremony u ids -> liftIO (freeze =<< runEff (runWebAuthnCeremonyLibrary cfg (beginRegistrationCeremony u ids)))
  BeginAuthenticationCeremony uv ids -> liftIO (freeze =<< runEff (runWebAuthnCeremonyLibrary cfg (beginAuthenticationCeremony uv ids)))
  CompleteRegistrationCeremony b v -> liftIO (runEff (runWebAuthnCeremonyLibrary cfg (completeRegistrationCeremony b v)))
  CompleteAuthenticationCeremony b c v -> liftIO (runEff (runWebAuthnCeremonyLibrary cfg (completeAuthenticationCeremony b c v)))
  where
    freeze BeginCeremony {optionsJson} = let v = freezeChallenge optionsJson in pure (BeginCeremony v (LBS.toStrict (encode v)))

cfg :: ShomeiConfig
cfg = (defaultShomeiConfig (Issuer "test") (Audience "test")) {webauthnConfig = defaultWebAuthnConfig {origins = ["https://localhost"], userVerification = UVDiscouraged}}

runHybrid :: IORef World -> Eff InMemoryPorts a -> IO a
runHybrid ref = runInMemory ref . realCeremonies cfg.webauthnConfig

fixedTime :: UTCTime
fixedTime = UTCTime (fromGregorian 2026 1 1) 0

right :: (Show e) => Either e a -> IO a
right = either (assertFailure . show) pure

proof :: ProofContext
proof = ProofContext (ClientIp "fixture") AccountKey

fixtureLoginId :: LoginId
fixtureLoginId = either (error . show) id (mkLoginId "fixture-user")

fixturePassword :: PlainPassword
fixturePassword = PlainPassword "correct horse battery staple"

seed :: IO (IORef World, User, ResponsePolicy)
seed = do
  ref <- newIORef (emptyWorld fixedTime)
  (user, _) <- right =<< runHybrid ref (signup cfg (SignupCommand fixtureLoginId Nothing fixturePassword Nothing))
  (cid, options) <- right =<< runHybrid ref (beginPasskeyRegistration cfg user.userId)
  handle <- case parseMaybe (withObject "options" (\o -> o .: "user" >>= withObject "user" (.: "id"))) options of
    Just value -> right (b64urlDecode value)
    Nothing -> assertFailure "fixture options lack user handle"
  let policy = goodPolicy {responseHandle = handle, responseCounter = 0}
  _ <- right =<< runHybrid ref (completePasskeyRegistration cfg user.userId cid (registrationResponse options policy) Nothing)
  replay <- runHybrid ref (completePasskeyRegistration cfg user.userId cid (registrationResponse options policy) Nothing)
  replay @?= Left PendingCeremonyNotFound
  pure (ref, user, policy)

tests :: TestTree
tests =
  testGroup
    "signed WebAuthn workflows"
    [ testCase "signed enrollment, password step-up and passwordless login persist counters and audit winners" do
        (ref, user, policy) <- seed
        challenge <- right =<< runHybrid ref (login cfg (ClientContext (ClientIp "fixture") (AccountKey "fixture-user")) (LoginCommand fixtureLoginId fixturePassword False))
        case challenge of
          MfaRequired MfaChallenge {ceremonyId, options} -> do
            _ <- right =<< runHybrid ref (completeMfa cfg proof ceremonyId (MfaPasskey (assertionResponse options policy {responseCounter = 1, responseFlags = 1})))
            replay <- runHybrid ref (completeMfa cfg proof ceremonyId (MfaPasskey (assertionResponse options policy {responseCounter = 1})))
            replay @?= Left PendingCeremonyNotFound
          _ -> assertFailure "expected password step-up"
        (cid, options) <- right =<< runHybrid ref (beginPasswordlessLogin cfg)
        (resolved, _) <- right =<< runHybrid ref (completePasswordlessLogin cfg proof cid (assertionResponse options policy {responseCounter = 2}))
        resolved.userId @?= user.userId
        world <- readIORef ref
        map (\PasskeyCredential {signCounter} -> signCounter) (Map.elems world.passkeys) @?= [SignatureCounter 2]
        length [() | Event.MfaSucceeded _ <- world.publishedEvents] @?= 2
        (replayCid, replayOptions) <- right =<< runHybrid ref (beginPasswordlessLogin cfg)
        cloned <- runHybrid ref (completePasswordlessLogin cfg proof replayCid (assertionResponse replayOptions policy {responseCounter = 2}))
        cloned @?= Left MfaAssertionInvalid
        afterClone <- readIORef ref
        length [() | Event.MfaFailed _ <- afterClone.publishedEvents] @?= 1,
      testCase "passwordless always requires UV; signed bad proofs consume once and audit failures" do
        forM_ [UVPreferred, UVDiscouraged] \uv -> do
          (ref, _, policy) <- seed
          let run :: Eff InMemoryPorts a -> IO a
              run = runInMemory ref . realCeremonies cfg.webauthnConfig {userVerification = uv}
          (cid, options) <- right =<< run (beginPasswordlessLogin cfg)
          failed <- run (completePasswordlessLogin cfg proof cid (assertionResponse options policy {responseCounter = 1, responseFlags = 1}))
          failed @?= Left MfaAssertionInvalid
          replay <- run (completePasswordlessLogin cfg proof cid (assertionResponse options policy {responseCounter = 1}))
          replay @?= Left PendingCeremonyNotFound
          world <- readIORef ref
          length [() | Event.MfaFailed _ <- world.publishedEvents] @?= 1
          assertBool "failed proof recorded in shared abuse budget" (not (null world.loginAttempts)),
      testCase "a correctly signed credential owned by another user fails the step-up owner check" do
        (ref, _, policy) <- seed
        let bobLogin = either (error . show) id (mkLoginId "bob-fixture")
        bob <- runHybrid ref (createUser (NewUser bobLogin Nothing Nothing))
        (cid, options) <- runHybrid ref do
          BeginCeremony {optionsJson, optionsBlob} <- beginAuthenticationCeremony UVRequired []
          cid <- genCeremonyId
          putPendingCeremony (PendingCeremony cid (Just bob.userId) AuthenticationCeremony optionsBlob fixedTime (addUTCTime 300 fixedTime))
          pure (cid, optionsJson)
        wrongOwner <- runHybrid ref (completeMfa cfg proof cid (MfaPasskey (assertionResponse options policy {responseCounter = 1})))
        wrongOwner @?= Left MfaAssertionInvalid
        world <- readIORef ref
        length [() | Event.MfaFailed _ <- world.publishedEvents] @?= 1
        length [() | Event.MfaSucceeded _ <- world.publishedEvents] @?= 0,
      testCase "expired signed ceremony fails before minting or counter advancement" do
        (ref, _, policy) <- seed
        (cid, options) <- right =<< runHybrid ref (beginPasswordlessLogin cfg)
        modifyIORef' ref (\w -> w {clock = addUTCTime 301 fixedTime})
        expired <- runHybrid ref (completePasswordlessLogin cfg proof cid (assertionResponse options policy {responseCounter = 1}))
        expired @?= Left PendingCeremonyNotFound
        world <- readIORef ref
        map (\PasskeyCredential {signCounter} -> signCounter) (Map.elems world.passkeys) @?= [SignatureCounter 0]
    ]
