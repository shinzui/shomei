module Shomei.Account.Lifecycle.CostSpec (tests) where

import Data.IORef (IORef, modifyIORef', newIORef, readIORef)
import Data.Map.Strict qualified as Map
import Data.Time (UTCTime (..), fromGregorian)
import Effectful (Eff, IOE, liftIO, (:>))
import Effectful.Dispatch.Dynamic (interpose, passthrough, send)
import Shomei.Account.Email.Domain (Email, emailText, mkEmail)
import Shomei.Account.Lifecycle.Workflow
  ( RequestEmailVerification (..),
    RequestPasswordReset (..),
    requestEmailVerification,
    requestPasswordReset,
  )
import Shomei.Account.LoginId.Domain (mkLoginId)
import Shomei.Account.Password.Domain (PlainPassword (..))
import Shomei.Account.User.Store (UserStore (..))
import Shomei.Authorization.Claims.Domain (Audience (..), Issuer (..))
import Shomei.Config (ShomeiConfig, defaultShomeiConfig)
import Shomei.Error (AuthError)
import Shomei.Session.Authentication.Workflow (signup)
import Shomei.Session.Command (SignupCommand (..))
import Shomei.Test.InMemory (InMemoryPorts, World (..), emptyWorld, runInMemory)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertFailure, testCase, (@?=))

data Costs = Costs
  { userLookups :: !Int,
    tokenInserts :: !Int,
    enqueues :: !Int,
    auditInserts :: !Int
  }
  deriving stock (Eq, Show)

tests :: TestTree
tests =
  testGroup
    "CostSpec"
    [ testCase "email-verification hit costs lookup + token + enqueue + audit" do
        ref <- seededWorld
        measure ref (\w -> Map.size w.verificationTokens) (requestEmailVerification cfg (RequestEmailVerification aliceEmail))
          >>= (@?= Costs 1 1 1 1),
      testCase "email-verification miss costs only one lookup" do
        ref <- newIORef (emptyWorld fixedTime)
        measure ref (\w -> Map.size w.verificationTokens) (requestEmailVerification cfg (RequestEmailVerification aliceEmail))
          >>= (@?= Costs 1 0 0 0),
      testCase "password-reset hit costs lookup + token + enqueue + audit" do
        ref <- seededWorld
        measure ref (\w -> Map.size w.passwordResetTokens) (requestPasswordReset cfg (RequestPasswordReset aliceEmail))
          >>= (@?= Costs 1 1 1 1),
      testCase "password-reset miss costs only one lookup" do
        ref <- newIORef (emptyWorld fixedTime)
        measure ref (\w -> Map.size w.passwordResetTokens) (requestPasswordReset cfg (RequestPasswordReset aliceEmail))
          >>= (@?= Costs 1 0 0 0)
    ]

-- | Pin the deliberate residual between a known and unknown address. Delivery is represented by
-- the Notifier port call here; the server interpreter turns that call into a bounded enqueue.
measure :: IORef World -> (World -> Int) -> Eff InMemoryPorts (Either AuthError ()) -> IO Costs
measure worldRef tokenCount action = do
  lookups <- newIORef 0
  before <- readIORef worldRef
  result <- runInMemory worldRef (countEmailLookups lookups action)
  result @?= Right ()
  after <- readIORef worldRef
  lookupCount <- readIORef lookups
  pure
    Costs
      { userLookups = lookupCount,
        tokenInserts = tokenCount after - tokenCount before,
        enqueues = length after.sentNotifications - length before.sentNotifications,
        auditInserts = length after.publishedEvents - length before.publishedEvents
      }

countEmailLookups :: (UserStore :> es, IOE :> es) => IORef Int -> Eff es a -> Eff es a
countEmailLookups countRef = interpose \env -> \case
  FindUserByEmail email -> do
    liftIO (modifyIORef' countRef (+ 1))
    send (FindUserByEmail email)
  operation -> passthrough env operation

seededWorld :: IO (IORef World)
seededWorld = do
  ref <- newIORef (emptyWorld fixedTime)
  outcome <- runInMemory ref (signup cfg signupAlice)
  case outcome of
    Left err -> assertFailure ("seed signup failed: " <> show err)
    Right _ -> pure ref

cfg :: ShomeiConfig
cfg = defaultShomeiConfig (Issuer "shomei") (Audience "shomei-clients")

fixedTime :: UTCTime
fixedTime = UTCTime (fromGregorian 2026 8 27) 0

aliceEmail :: Email
aliceEmail = either (error . show) id (mkEmail "alice@example.com")

signupAlice :: SignupCommand
signupAlice =
  SignupCommand
    { loginId = either (error . show) id (mkLoginId (emailText aliceEmail)),
      email = Just aliceEmail,
      password = PlainPassword "correct horse battery staple",
      displayName = Just "Alice"
    }
