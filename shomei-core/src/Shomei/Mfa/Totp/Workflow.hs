-- | The TOTP enrollment / removal and recovery-code generation workflows (EP-7).
--
-- These are the caller-facing counterparts to 'Shomei.Mfa.Workflow', which completes a login
-- with a TOTP or recovery-code factor. Enrollment is two-step: 'enrollTotp' mints a secret (shown
-- once) and 'verifyTotpEnrollment' activates it with a first valid code. 'removeTotp' downgrades
-- the factor, gated on proof of possession. 'regenerateRecoveryCodes' issues a fresh single-use
-- set, invalidating any previous one.
--
-- The recovery-code hash is centralized in 'recoveryCodeHash' so this module and
-- 'Shomei.Mfa.Workflow' (which consumes codes) cannot drift on normalization.
module Shomei.Mfa.Totp.Workflow
  ( TotpEnrollment (..),
    TotpRemovalProof (..),
    enrollTotp,
    verifyTotpEnrollment,
    removeTotp,
    regenerateRecoveryCodes,
    recoveryCodeSetSize,
    recoveryCodeHash,
  )
where

import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Int (Int64)
import Data.Text qualified as Text
import Data.Time (addUTCTime)
import Effectful (Eff, IOE, (:>))
import Effectful.Error.Static (runErrorNoCallStack, throwError)
import Shomei.Account.LoginId.Domain (loginIdText)
import Shomei.Account.User.Domain (User (..))
import Shomei.Audit.Event.Domain qualified as Event
import Shomei.Audit.Publisher.Store (AuthEventPublisher, publishAuthEvent)
import Shomei.Authorization.Claims.Domain (Issuer (..))
import Shomei.Config (ShomeiConfig (..), TotpConfig (..))
import Shomei.Error (AuthError (..))
import Shomei.Id (TotpCredentialId, genRecoveryCodeId, genTotpCredentialId)
import Shomei.Mfa.RecoveryCode.Store (RecoveryCodeStore, consumeRecoveryCode, replaceRecoveryCodes)
import Shomei.Mfa.Totp.Algorithm (TotpSecret (..), secretToBase32, verifyTotp)
import Shomei.Mfa.Totp.Algorithm qualified as Totp
import Shomei.Mfa.Totp.Domain (NewRecoveryCode (..), NewTotpCredential (..), TotpCredential (..))
import Shomei.Mfa.Totp.Store
  ( TotpCredentialStore,
    confirmTotp,
    deleteTotpByUser,
    findTotpByUser,
    setTotpLastUsedCounter,
    upsertTotpEnrollment,
  )
import Shomei.Prelude
import Shomei.ServiceAccount.Secret (sha256Hex)
import Shomei.Session.Command (ProofContext, proofContextFor)
import Shomei.Session.LoginAttempt.Domain (AttemptFactor (..))
import Shomei.Session.LoginAttempt.Store (LoginAttemptStore)
import Shomei.Session.LoginAttempt.Workflow (AbuseGate (..), guardAbuse, recordProofFailure, recordProofSuccess)
import Shomei.Session.Token.Generator (TokenGen, generateRandomBytes)
import Shomei.Time.Store (Clock, now)

-- | The one-time enrollment payload: the Base32 secret to type/scan and the @otpauth://@ URI.
data TotpEnrollment = TotpEnrollment
  { secretBase32 :: !Text,
    otpauthUri :: !Text
  }
  deriving stock (Generic, Eq, Show)

-- | Proof presented to remove the TOTP factor: a currently valid code, or an unused recovery code.
data TotpRemovalProof
  = RemoveWithCode Text
  | RemoveWithRecoveryCode Text
  deriving stock (Generic, Eq, Show)

-- | Ten codes per generated set — the de-facto industry shape.
recoveryCodeSetSize :: Int
recoveryCodeSetSize = 10

-- | The stored hash of a recovery code: normalize (strip the dash, casefold) then SHA-256 hex.
-- The single definition both the generator here and the consumer in 'Shomei.Mfa.Workflow' use.
recoveryCodeHash :: Text -> Text
recoveryCodeHash = sha256Hex . Text.toLower . Text.filter (/= '-')

-- Field accessors (DuplicateRecordFields make @value.field@ unreliable).
tcId :: TotpCredential -> TotpCredentialId
tcId TotpCredential {totpCredentialId} = totpCredentialId

-- | Enroll (start) TOTP: mint a fresh 20-byte secret and persist it unconfirmed, replacing any
-- prior unconfirmed enrollment. Refuses when TOTP is disabled or a /confirmed/ credential
-- already exists (remove it first). The secret is returned once, never retrievable again; the
-- 'Event.TotpEnrolled' audit event fires only on confirmation ('verifyTotpEnrollment').
enrollTotp ::
  (TotpCredentialStore :> es, TokenGen :> es, Clock :> es, IOE :> es) =>
  ShomeiConfig ->
  User ->
  Eff es (Either AuthError TotpEnrollment)
enrollTotp cfg user = runErrorNoCallStack do
  unless (totpEnabled (totpConfig cfg)) (throwError TotpDisabled)
  ts <- now
  let User {userId = uid} = user
  existing <- findTotpByUser uid
  when (maybe False confirmed existing) (throwError TotpAlreadyEnrolled)
  secretBytes <- generateRandomBytes 20
  let secret = TotpSecret secretBytes
  tcid <- genTotpCredentialId
  _ <- upsertTotpEnrollment NewTotpCredential {totpCredentialId = tcid, userId = uid, secret, createdAt = ts}
  pure
    TotpEnrollment
      { secretBase32 = secretToBase32 secret,
        otpauthUri = Totp.otpauthUri (issuerLabel cfg) (accountLabel user) secret
      }

-- | Activate a pending enrollment with a first valid code. Loads the unconfirmed, unexpired
-- enrollment (else 'TotpEnrollmentNotFound'), verifies the code (with no replay bound — this is
-- the first use), and on success confirms it and consumes that code's counter. A wrong code
-- publishes 'MfaFailed' and returns 'TotpCodeInvalid'.
verifyTotpEnrollment ::
  (TotpCredentialStore :> es, AuthEventPublisher :> es, Clock :> es) =>
  ShomeiConfig ->
  User ->
  Text ->
  Eff es (Either AuthError ())
verifyTotpEnrollment cfg user code = runErrorNoCallStack do
  unless (totpEnabled (totpConfig cfg)) (throwError TotpDisabled)
  ts <- now
  let User {userId = uid} = user
  existing <- findTotpByUser uid
  cred <- case existing of
    Just c | not (confirmed c), not (enrollmentExpired cfg ts c) -> pure c
    _ -> throwError TotpEnrollmentNotFound
  case verifyTotp (secretOf cred) Nothing ts code of
    Just accepted -> do
      confirmTotp (tcId cred) ts
      setTotpLastUsedCounter (tcId cred) accepted
      publishAuthEvent (Event.TotpEnrolled (Event.TotpEnrolledData uid ts))
    Nothing -> do
      publishAuthEvent (Event.MfaFailed (Event.MfaFailedData (Just uid) "totp_invalid" ts))
      throwError TotpCodeInvalid

-- | Remove the TOTP factor, gated on proof of possession: a currently valid code, or an unused
-- recovery code (which is consumed). Refuses when no credential exists ('TotpEnrollmentNotFound')
-- or the proof fails ('TotpCodeInvalid' / 'RecoveryCodeInvalid'). Publishes 'Event.TotpRemoved'.
removeTotp ::
  ( TotpCredentialStore :> es,
    RecoveryCodeStore :> es,
    AuthEventPublisher :> es,
    LoginAttemptStore :> es,
    Clock :> es
  ) =>
  ShomeiConfig ->
  ProofContext ->
  User ->
  TotpRemovalProof ->
  Eff es (Either AuthError ())
removeTotp cfg pctx user proof = runErrorNoCallStack do
  ts <- now
  let User {userId = uid} = user
      ctx = proofContextFor pctx (loginIdText user.loginId)
      factor = case proof of
        RemoveWithCode _ -> FactorTotp
        RemoveWithRecoveryCode _ -> FactorRecoveryCode
      proofError = case proof of
        RemoveWithCode _ -> TotpCodeInvalid
        RemoveWithRecoveryCode _ -> RecoveryCodeInvalid
  gate <- guardAbuse cfg.rateLimitConfig ctx ts
  when gate.locked do
    publishAuthEvent (Event.MfaFailed (Event.MfaFailedData (Just uid) "account_locked" ts))
    throwError proofError
  cred <- maybe (throwError TotpEnrollmentNotFound) pure =<< findTotpByUser uid
  case proof of
    RemoveWithCode code ->
      case verifyTotp (secretOf cred) (lastUsedOf cred) ts code of
        Just accepted -> setTotpLastUsedCounter (tcId cred) accepted
        Nothing -> do
          recordProofFailure cfg.rateLimitConfig ctx FactorTotp ts
          publishAuthEvent (Event.MfaFailed (Event.MfaFailedData (Just uid) "totp_invalid" ts))
          throwError TotpCodeInvalid
    RemoveWithRecoveryCode rc -> do
      ok <- consumeRecoveryCode uid (recoveryCodeHash rc) ts
      if ok
        then publishAuthEvent (Event.RecoveryCodeUsed (Event.RecoveryCodeUsedData uid ts))
        else do
          recordProofFailure cfg.rateLimitConfig ctx FactorRecoveryCode ts
          publishAuthEvent (Event.MfaFailed (Event.MfaFailedData (Just uid) "recovery_invalid" ts))
          throwError RecoveryCodeInvalid
  recordProofSuccess ctx factor gate.standingLockout ts
  deleteTotpByUser uid
  publishAuthEvent (Event.TotpRemoved (Event.TotpRemovedData uid ts))

-- | Generate a fresh set of 'recoveryCodeSetSize' single-use codes, replacing any previous set,
-- and return the plaintext codes (shown once). Codes back up passkey-only users too, so this is
-- allowed whether or not TOTP is enrolled.
regenerateRecoveryCodes ::
  (RecoveryCodeStore :> es, TokenGen :> es, AuthEventPublisher :> es, Clock :> es, IOE :> es) =>
  ShomeiConfig ->
  User ->
  Eff es (Either AuthError [Text])
regenerateRecoveryCodes _cfg user = runErrorNoCallStack do
  ts <- now
  let User {userId = uid} = user
  codes <- forM [1 .. recoveryCodeSetSize] \_ -> formatRecoveryCode <$> generateRandomBytes 10
  ids <- forM [1 .. recoveryCodeSetSize] \_ -> genRecoveryCodeId
  let rows =
        zipWith
          (\rid code -> NewRecoveryCode {recoveryCodeId = rid, codeHash = recoveryCodeHash code, createdAt = ts})
          ids
          codes
  replaceRecoveryCodes uid rows
  publishAuthEvent (Event.RecoveryCodesGenerated (Event.RecoveryCodesGeneratedData uid recoveryCodeSetSize ts))
  pure codes

-- Helpers --------------------------------------------------------------------

confirmed :: TotpCredential -> Bool
confirmed TotpCredential {confirmedAt} = isJust confirmedAt

secretOf :: TotpCredential -> TotpSecret
secretOf TotpCredential {secret} = secret

lastUsedOf :: TotpCredential -> Maybe Int64
lastUsedOf TotpCredential {lastUsedCounter} = lastUsedCounter

-- | An unconfirmed enrollment older than @totpConfig.enrollmentTTL@ is treated as absent.
enrollmentExpired :: ShomeiConfig -> UTCTime -> TotpCredential -> Bool
enrollmentExpired cfg ts TotpCredential {createdAt} =
  addUTCTime (enrollmentTTL (totpConfig cfg)) createdAt <= ts

-- | The issuer label for the @otpauth://@ URI, made label-safe (@:@ and @/@ break the URI).
issuerLabel :: ShomeiConfig -> Text
issuerLabel cfg = case cfg.issuer of
  Issuer t -> labelSafe t

-- | The account label: the user's login identifier, made label-safe.
accountLabel :: User -> Text
accountLabel User {loginId} = labelSafe (loginIdText loginId)

labelSafe :: Text -> Text
labelSafe = Text.map (\c -> if c == ':' || c == '/' then '_' else c)

-- | Format 10 random bytes as a @XXXXX-XXXXX@ code over the Crockford Base32 alphabet (no
-- ambiguous characters for codes users type by hand).
formatRecoveryCode :: ByteString -> Text
formatRecoveryCode bytes =
  let chars = [Text.index crockford (fromIntegral b `mod` 32) | b <- BS.unpack bytes]
      (a, b) = splitAt 5 chars
   in Text.pack a <> "-" <> Text.pack b

crockford :: Text
crockford = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"
