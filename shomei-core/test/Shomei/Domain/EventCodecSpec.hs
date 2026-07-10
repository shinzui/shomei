-- | Pure round-trip tests for 'reconstructAuthEvent'. For a representative value of every
-- 'AuthEvent' constructor, assert that @reconstructAuthEvent event_type (toJSON dataRecord)@
-- returns @Right (Constructor dataRecord)@ — i.e. the read path inverts what the write path
-- ('Shomei.Postgres.AuthEventPublisher.projectAuthEvent') stores. This is the primary guard
-- against the @event_type@/payload mapping drifting from the writer.
--
-- If a new 'AuthEvent' constructor is added, add a case here (and the @event_type@ string is
-- exercised by the writer's mapping). The @allEventTypes@ count assertion catches a missing
-- constructor cheaply.
module Shomei.Domain.EventCodecSpec (tests) where

import Data.Aeson (ToJSON, toJSON)
import Data.Aeson qualified as Aeson
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (UTCTime (..), fromGregorian, secondsToDiffTime)
import Data.UUID qualified as UUID
import Shomei.Config (ServiceAccountId (..))
import Shomei.Domain.Claims (Role (..), Scope (..))
import Shomei.Domain.Email (Email, mkEmail)
import Shomei.Domain.Event
import Shomei.Domain.EventCodec (reconstructAuthEvent)
import Shomei.Domain.LoginAttempt (AccountKey (..), ClientIp (..))
import Shomei.Domain.LoginId (LoginId, loginIdFromEmail)
import Shomei.Id
  ( CeremonyId,
    PasskeyId,
    RefreshTokenId,
    SessionId,
    UserId,
    ceremonyIdFromUUID,
    passkeyIdFromUUID,
    refreshTokenIdFromUUID,
    sessionIdFromUUID,
    userIdFromUUID,
  )
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (testCase, (@?=))

-- Fixtures -------------------------------------------------------------------

t0 :: UTCTime
t0 = UTCTime (fromGregorian 2026 6 17) (secondsToDiffTime 0)

t1 :: UTCTime
t1 = UTCTime (fromGregorian 2026 6 17) (secondsToDiffTime 3600)

uid :: UserId
uid = userIdFromUUID (UUID.fromWords 0 0 0 1)

uid2 :: UserId
uid2 = userIdFromUUID (UUID.fromWords 0 0 0 2)

sid :: SessionId
sid = sessionIdFromUUID (UUID.fromWords 0 0 0 3)

rtid :: RefreshTokenId
rtid = refreshTokenIdFromUUID (UUID.fromWords 0 0 0 4)

pkid :: PasskeyId
pkid = passkeyIdFromUUID (UUID.fromWords 0 0 0 5)

cid :: CeremonyId
cid = ceremonyIdFromUUID (UUID.fromWords 0 0 0 6)

aliceEmail :: Email
aliceEmail = case mkEmail "alice@example.com" of
  Right e -> e
  Left err -> error ("bad test email: " <> show err)

aliceLogin :: LoginId
aliceLogin = loginIdFromEmail aliceEmail

-- | Assert that the event survives @project → toJSON → reconstruct@.
check :: (ToJSON a) => Text -> a -> AuthEvent -> TestTree
check ty dataRecord expected =
  testCase (Text.unpack ty) (reconstructAuthEvent ty (toJSON dataRecord) @?= Right expected)

-- Tests ----------------------------------------------------------------------

tests :: TestTree
tests =
  testGroup
    "Shomei.Domain.EventCodec"
    [ testGroup "round-trips every constructor" roundTrips,
      testUnknownType,
      testConstructorCount,
      testOldSessionRevokedDecodes
    ]

-- | One assertion per 'AuthEvent' constructor. The @event_type@ strings here MUST match
-- 'Shomei.Postgres.AuthEventPublisher.projectAuthEvent' verbatim.
roundTrips :: [TestTree]
roundTrips =
  [ let d = UserRegisteredData uid aliceLogin (Just aliceEmail) t0 in check "user_registered" d (UserRegistered d),
    let d = LoginSucceededData uid sid t0 in check "login_succeeded" d (LoginSucceeded d),
    let d = LoginFailedData aliceLogin t0 in check "login_failed" d (LoginFailed d),
    let d = SessionStartedData sid uid t0 in check "session_started" d (SessionStarted d),
    let d = SessionRevokedData sid (Just uid2) t0 in check "session_revoked" d (SessionRevoked d),
    let d = RefreshTokenRotatedData sid rtid t0 in check "refresh_token_rotated" d (RefreshTokenRotated d),
    let d = RefreshTokenReuseDetectedData sid rtid t0 in check "refresh_token_reuse_detected" d (RefreshTokenReuseDetected d),
    let d = EmailVerificationRequestedData uid aliceEmail t0 in check "email_verification_requested" d (EmailVerificationRequested d),
    let d = EmailVerifiedData uid aliceEmail t0 in check "email_verified" d (EmailVerified d),
    let d = PasswordResetRequestedData uid aliceEmail t0 in check "password_reset_requested" d (PasswordResetRequested d),
    let d = PasswordResetCompletedData uid t0 in check "password_reset_completed" d (PasswordResetCompleted d),
    let d = PasswordChangedData uid t0 in check "password_changed" d (PasswordChanged d),
    let d = UserSuspendedData uid (Just uid2) t0 in check "user_suspended" d (UserSuspended d),
    let d = UserDeletedData uid (Just uid2) t0 in check "user_deleted" d (UserDeleted d),
    let d = UserReinstatedData uid (Just uid2) t0 in check "user_reinstated" d (UserReinstated d),
    let d = AccountLockedData (AccountKey "k-abc") (ClientIp "1.2.3.4") 5 t1 t0 in check "account_locked" d (AccountLocked d),
    let d = LoginThrottledData (ClientIp "1.2.3.4") 5 t0 in check "login_throttled" d (LoginThrottled d),
    let d = PasskeyRegisteredData uid pkid t0 in check "passkey_registered" d (PasskeyRegistered d),
    let d = PasskeyRemovedData uid pkid t0 in check "passkey_removed" d (PasskeyRemoved d),
    let d = MfaChallengedData uid cid t0 in check "mfa_challenged" d (MfaChallenged d),
    let d = MfaSucceededData uid sid t0 in check "mfa_succeeded" d (MfaSucceeded d),
    let d = MfaFailedData (Just uid) "bad assertion" t0 in check "mfa_failed" d (MfaFailed d),
    -- EP-7 TOTP / recovery-code factor management.
    let d = TotpEnrolledData uid t0 in check "totp_enrolled" d (TotpEnrolled d),
    let d = TotpRemovedData uid t0 in check "totp_removed" d (TotpRemoved d),
    let d = RecoveryCodesGeneratedData uid 10 t0 in check "recovery_codes_generated" d (RecoveryCodesGenerated d),
    let d = RecoveryCodeUsedData uid t0 in check "recovery_code_used" d (RecoveryCodeUsed d),
    let d = ImpersonationStartedData uid2 uid sid "support ticket" (Just "TICKET-1") (Just "1.2.3.4") t0 in check "impersonation_started" d (ImpersonationStarted d),
    let d = ImpersonationStoppedData uid2 uid sid t0 in check "impersonation_stopped" d (ImpersonationStopped d),
    let d = ImpersonationActionBlockedData uid2 uid sid "password_change" t0 in check "impersonation_action_blocked" d (ImpersonationActionBlocked d),
    let d = ServiceTokenIssuedData uid sid (ServiceAccountId "connector:rei") (Set.singleton (Scope "kawa:ingest")) (Just uid2) t0 in check "service_token_issued" d (ServiceTokenIssued d),
    -- EP-6 on-behalf-of: subject (the user) is uid; actor (the service's backing user) is uid2.
    let d = ServiceOnBehalfIssuedData "svcacct_01" uid2 uid sid (Set.singleton (Scope "kawa:ingest")) t0 in check "service_on_behalf_issued" d (ServiceOnBehalfIssued d),
    -- An HTTP grant records the acting admin; a CLI bootstrap grant / default role records none.
    let d = RoleGrantedData uid (Role "admin") (Just uid2) t0 in check "role_granted" d (RoleGranted d),
    let d = RoleRevokedData uid (Role "admin") Nothing t0 in check "role_revoked" d (RoleRevoked d),
    -- EP-4 service-account lifecycle. The payload never carries the secret, only the account's
    -- public identifiers and its backing user.
    let d = ServiceAccountCreatedData "svcacct_01" "svcacct_01" uid "rei connector" (Set.singleton (Scope "kawa:ingest")) t0
     in check "service_account_created" d (ServiceAccountCreated d),
    let d = ServiceAccountSecretRotatedData "svcacct_01" "svcacct_01" uid t0
     in check "service_account_secret_rotated" d (ServiceAccountSecretRotated d),
    let d = ServiceAccountRevokedData "svcacct_01" "svcacct_01" uid t0
     in check "service_account_revoked" d (ServiceAccountRevoked d),
    -- EP-5 OAuth-client lifecycle. No backing user, so no user id in the payload at all.
    let d = OAuthClientCreatedData "oauthclient_01" "oauthclient_01" "confidential" "grafana" ["https://grafana.example.com/callback"] (Set.singleton (Scope "openid")) t0
     in check "oauth_client_created" d (OAuthClientCreated d),
    let d = OAuthClientRevokedData "oauthclient_01" "oauthclient_01" t0
     in check "oauth_client_revoked" d (OAuthClientRevoked d),
    let d = OAuthCodeIssuedData "oauthclient_01" uid (Set.singleton (Scope "openid")) t0
     in check "oauth_code_issued" d (OAuthCodeIssued d)
  ]

-- | An unrecognized @event_type@ is a 'Left', never a crash.
testUnknownType :: TestTree
testUnknownType =
  testCase "unknown event_type yields Left" $
    case reconstructAuthEvent "not_a_real_event" (toJSON ()) of
      Left _ -> pure ()
      Right _ -> error "expected Left for unknown event_type"

-- | Guard: the round-trip list must cover every 'AuthEvent' constructor (currently 35).
testConstructorCount :: TestTree
testConstructorCount =
  testCase "covers all 39 AuthEvent constructors" (length roundTrips @?= 39)

-- | EP-2 widened 'SessionRevokedData' with @revokedBy@. Rows written before that exist in every
-- deployment's @shomei_auth_events@ (logout, refresh-token reuse, stopping an impersonation all
-- write them), and they carry no such key. Decoding one must still succeed, yielding 'Nothing' —
-- which is precisely what those rows mean: nobody administrative revoked that session.
--
-- This is the compatibility rule for every future widening of an event payload: add 'Maybe'
-- fields, never required ones.
testOldSessionRevokedDecodes :: TestTree
testOldSessionRevokedDecodes =
  testCase "a pre-EP-2 session_revoked payload decodes with revokedBy = Nothing" $
    reconstructAuthEvent "session_revoked" oldPayload @?= Right (SessionRevoked expected)
  where
    oldPayload =
      Aeson.object
        [ "sessionId" Aeson..= sid,
          "occurredAt" Aeson..= t0
        ]
    expected = SessionRevokedData sid Nothing t0
