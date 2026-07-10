-- | The second-factor (MFA step-up) and passwordless passkey login workflows (EP-4).
--
-- 'prepareMfaChallenge' is the step-up branch of 'Shomei.Workflow.login': after a correct
-- password for an account that has a passkey (and @mfaRequired@), it begins a WebAuthn
-- authentication ceremony restricted to the user's credentials, stashes it consume-once, and
-- returns the ceremony id + browser options WITHOUT issuing a token. 'completeMfa' finishes
-- that step-up: it consumes the pending ceremony, verifies the browser's assertion against the
-- user's stored passkey, and mints the session/tokens. 'beginPasswordlessLogin' /
-- 'completePasswordlessLogin' authenticate with the passkey ALONE (no password): begin emits
-- options for a discoverable credential, complete resolves the account from the asserted
-- credential id, verifies, and mints tokens.
--
-- All token-minting paths share 'Shomei.Workflow.Session.issueSession' so the tail never
-- drifts. The EP-1 passkey/ceremony records are read via plain record-pattern matching, not
-- @value.field@ dot syntax, because @OverloadedRecordDot@/@HasField@ is unreliable for those
-- @DuplicateRecordFields@ records (a MasterPlan-3 discovery).
module Shomei.Workflow.Mfa
  ( prepareMfaChallenge,
    completeMfa,
    MfaCompletion (..),
    beginPasswordlessLogin,
    completePasswordlessLogin,
  )
where

import Data.Aeson (Value, object)
import Data.Aeson.Types (parseMaybe, withObject, (.:))
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Time (addUTCTime)
import Effectful (Eff, IOE, (:>))
import Effectful.Error.Static (Error, runErrorNoCallStack, throwError)
import Shomei.Config (ShomeiConfig (..), WebAuthnConfig (..))
import Shomei.Domain.Event qualified as Event
import Shomei.Domain.Passkey
  ( CeremonyKind (AuthenticationCeremony),
    PasskeyCredential (..),
    PendingCeremony (..),
    WebAuthnCredentialId,
  )
import Shomei.Domain.Token (TokenPair)
import Shomei.Domain.Totp (TotpCredential (..))
import Shomei.Domain.User (User (..), UserStatus (UserActive))
import Shomei.Effect.AuthEventPublisher (AuthEventPublisher, publishAuthEvent)
import Shomei.Effect.AuthUnitOfWork (AuthUnitOfWork)
import Shomei.Effect.ClaimsEnricher (ClaimsEnricher)
import Shomei.Effect.Clock (Clock, now)
import Shomei.Effect.PasskeyStore
  ( PasskeyStore,
    findPasskeyByCredentialId,
    findPasskeysByUser,
    updatePasskeySignCounter,
  )
import Shomei.Effect.PendingCeremonyStore (PendingCeremonyStore, putPendingCeremony, takePendingCeremony)
import Shomei.Effect.RecoveryCodeStore (RecoveryCodeStore, consumeRecoveryCode, countUnusedRecoveryCodes)
import Shomei.Effect.RoleStore (RoleStore)
import Shomei.Effect.TokenGen (TokenGen)
import Shomei.Effect.TokenSigner (TokenSigner)
import Shomei.Effect.TotpCredentialStore (TotpCredentialStore, findTotpByUser, setTotpLastUsedCounter)
import Shomei.Effect.UserStore (UserStore, findUserById)
import Shomei.Effect.WebAuthnCeremony
  ( BeginCeremony (..),
    StoredCredentialForVerify (..),
    VerifiedAuthentication (..),
    WebAuthnCeremony,
    beginAuthenticationCeremony,
    completeAuthenticationCeremony,
  )
import Shomei.Error (AuthError (..))
import Shomei.Id (CeremonyId, UserId, genCeremonyId)
import Shomei.Prelude
import Shomei.Totp (verifyTotp)
import Shomei.Workflow.Session (ensureEmailVerified, issueSession)
import Shomei.Workflow.Totp (recoveryCodeHash)

-- | How a client completes an MFA challenge. Exactly one arm is populated by the HTTP layer's
-- 'Shomei.Servant.DTO.MfaCompleteRequest' decoder: 'MfaPasskey' is the legacy WebAuthn assertion,
-- 'MfaTotp' a six-digit code, 'MfaRecoveryCode' a single-use recovery code.
data MfaCompletion
  = MfaPasskey Value
  | MfaTotp Text
  | MfaRecoveryCode Text
  deriving stock (Generic, Eq, Show)

-- Field accessors for the TOTP credential (DuplicateRecordFields make @value.field@ unreliable).
totpConfirmed :: TotpCredential -> Bool
totpConfirmed TotpCredential {confirmedAt} = isJust confirmedAt

-- | The step-up branch of 'Shomei.Workflow.login'. Begins a WebAuthn authentication
-- ceremony whose @allowCredentials@ is restricted to this user's enrolled passkeys, stashes
-- the consume-once pending ceremony (bound to the user, expiring after the configured TTL),
-- publishes 'MfaChallenged', and returns the ceremony id + the browser-facing options. NO
-- token is issued: the caller returns this as the @mfa_required@ outcome.
prepareMfaChallenge ::
  ( PasskeyStore :> es,
    PendingCeremonyStore :> es,
    WebAuthnCeremony :> es,
    TotpCredentialStore :> es,
    RecoveryCodeStore :> es,
    AuthEventPublisher :> es,
    IOE :> es
  ) =>
  ShomeiConfig ->
  User ->
  UTCTime ->
  Eff es (CeremonyId, Value, [Text])
prepareMfaChallenge cfg user ts = do
  let User {userId = uid} = user
  creds <- findPasskeysByUser uid
  mTotp <- findTotpByUser uid
  unusedRecovery <- countUnusedRecoveryCodes uid
  let hasPasskey = not (null creds)
      hasTotp = maybe False totpConfirmed mTotp
      methods =
        ["passkey" | hasPasskey]
          <> ["totp" | hasTotp]
          <> ["recovery_code" | unusedRecovery > 0]
  -- Passkey-holders get a real WebAuthn ceremony (options carry the challenge); a TOTP-only
  -- user gets an empty options object and no ceremony call — the empty @optionsBlob@ is what
  -- 'completeMfa' checks to refuse a passkey assertion for a challenge that never began one.
  (optionsJson, optionsBlob) <-
    if hasPasskey
      then do
        let allowIds = map (\PasskeyCredential {credentialId} -> credentialId) creds
        BeginCeremony {optionsJson, optionsBlob} <- beginAuthenticationCeremony allowIds
        pure (optionsJson, optionsBlob)
      else pure (object [], BS.empty)
  cid <- genCeremonyId
  putPendingCeremony
    PendingCeremony
      { ceremonyId = cid,
        userId = Just uid,
        kind = AuthenticationCeremony,
        optionsBlob = optionsBlob,
        createdAt = ts,
        expiresAt = addUTCTime (pendingCeremonyTTL (webauthnConfig cfg)) ts
      }
  publishAuthEvent (Event.MfaChallenged (Event.MfaChallengedData uid cid ts))
  pure (cid, optionsJson, methods)

-- | Finish a password-then-passkey step-up. The client posts the ceremony id from the
-- 'MfaRequired' challenge plus the browser's signed assertion. We consume the pending ceremony
-- (rejecting a missing/expired/consumed/non-authentication/no-user ceremony with a 404-mapped
-- 'PendingCeremonyNotFound'), verify the assertion against the user's stored passkey, confirm
-- the asserted credential is owned by that user, bump the sign counter, publish 'MfaSucceeded',
-- and mint tokens via the shared 'issueSession'. A verification failure publishes 'MfaFailed'
-- and returns 'MfaAssertionInvalid'.
completeMfa ::
  ( UserStore :> es,
    AuthUnitOfWork :> es,
    PasskeyStore :> es,
    PendingCeremonyStore :> es,
    WebAuthnCeremony :> es,
    TotpCredentialStore :> es,
    RecoveryCodeStore :> es,
    TokenSigner :> es,
    RoleStore :> es,
    ClaimsEnricher :> es,
    AuthEventPublisher :> es,
    Clock :> es,
    TokenGen :> es
  ) =>
  ShomeiConfig ->
  CeremonyId ->
  MfaCompletion ->
  Eff es (Either AuthError (User, TokenPair))
completeMfa cfg ceremonyId completion = runErrorNoCallStack do
  ts <- now
  PendingCeremony {kind, userId = mUid, optionsBlob} <-
    maybe (throwError PendingCeremonyNotFound) pure =<< takePendingCeremony ceremonyId ts
  when (kind /= AuthenticationCeremony) (throwError PendingCeremonyNotFound)
  uid <- maybe (throwError PendingCeremonyNotFound) pure mUid
  user <- maybe (throwError InvalidCredentials) pure =<< findUserById uid
  let User {status = userStatus} = user
  when (userStatus /= UserActive) (throwError UserNotActive)
  -- 'login' already gates before handing out a ceremony id, so this rarely fires; it keeps
  -- the guarantee local to every path that can issue a token.
  either throwError pure (ensureEmailVerified cfg user)
  -- Each arm proves the factor (spending the consume-once ceremony on any outcome); all three
  -- converge on the shared 'issueSession' tail.
  case completion of
    MfaPasskey assertion -> do
      -- The ceremony must have begun a WebAuthn challenge; a TOTP-only user's empty blob cannot
      -- carry an assertion, so refuse it rather than let the ceremony interpreter fail obscurely.
      when (BS.null optionsBlob) (failMfa (Just uid) "no passkey ceremony was begun")
      (passkey, verified) <- verifyAssertion (Just uid) optionsBlob assertion
      let PasskeyCredential {userId = pkUid, passkeyId} = passkey
          VerifiedAuthentication {newSignCounter} = verified
      when (pkUid /= uid) (failMfa (Just uid) "credential not owned by user")
      updatePasskeySignCounter passkeyId newSignCounter ts
    MfaTotp code -> completeTotp uid ts code
    MfaRecoveryCode code -> completeRecovery uid ts code
  (sid, pair) <- issueSession cfg user ts
  publishAuthEvent (Event.MfaSucceeded (Event.MfaSucceededData uid sid ts))
  pure (user, pair)

-- | Verify a presented TOTP code against the user's /confirmed/ credential and persist the
-- accepted counter (RFC 6238 replay defense). Any failure — no credential, unconfirmed, wrong
-- code, replayed counter — publishes 'MfaFailed' and throws 'TotpCodeInvalid'.
completeTotp ::
  (TotpCredentialStore :> es, AuthEventPublisher :> es, Clock :> es, Error AuthError :> es) =>
  UserId ->
  UTCTime ->
  Text ->
  Eff es ()
completeTotp uid ts code = do
  mtc <- findTotpByUser uid
  case mtc of
    Just TotpCredential {totpCredentialId, secret, lastUsedCounter, confirmedAt}
      | isJust confirmedAt ->
          case verifyTotp secret lastUsedCounter ts code of
            Just accepted -> setTotpLastUsedCounter totpCredentialId accepted
            Nothing -> failTyped (Just uid) "totp_invalid" TotpCodeInvalid
    _ -> failTyped (Just uid) "totp_invalid" TotpCodeInvalid

-- | Spend a recovery code to complete the challenge: normalize (strip the dash, casefold), hash,
-- and consume via the store's compare-and-set. Success publishes 'RecoveryCodeUsed'; a miss
-- publishes 'MfaFailed' and throws 'RecoveryCodeInvalid'.
completeRecovery ::
  (RecoveryCodeStore :> es, AuthEventPublisher :> es, Clock :> es, Error AuthError :> es) =>
  UserId ->
  UTCTime ->
  Text ->
  Eff es ()
completeRecovery uid ts code = do
  ok <- consumeRecoveryCode uid (recoveryCodeHash code) ts
  if ok
    then publishAuthEvent (Event.RecoveryCodeUsed (Event.RecoveryCodeUsedData uid ts))
    else failTyped (Just uid) "recovery_invalid" RecoveryCodeInvalid

-- | Publish 'MfaFailed' with the reason (recorded only in the audit event) and abort with a
-- specific typed error. Unlike 'failMfa' (which always throws the generic 'MfaAssertionInvalid'),
-- this lets the TOTP and recovery arms surface their own machine codes.
failTyped ::
  (AuthEventPublisher :> es, Clock :> es, Error AuthError :> es) =>
  Maybe UserId ->
  Text ->
  AuthError ->
  Eff es a
failTyped mUid reason err = do
  ts <- now
  publishAuthEvent (Event.MfaFailed (Event.MfaFailedData mUid reason ts))
  throwError err

-- | Begin a passwordless login: emit authentication options with NO @allowCredentials@ so
-- the browser offers its discoverable passkeys, stash the pending ceremony with no user
-- attached, and hand the client the ceremony id + options.
beginPasswordlessLogin ::
  ( PendingCeremonyStore :> es,
    WebAuthnCeremony :> es,
    Clock :> es,
    IOE :> es
  ) =>
  ShomeiConfig ->
  Eff es (Either AuthError (CeremonyId, Value))
beginPasswordlessLogin cfg = runErrorNoCallStack do
  ts <- now
  BeginCeremony {optionsJson, optionsBlob} <- beginAuthenticationCeremony []
  cid <- genCeremonyId
  putPendingCeremony
    PendingCeremony
      { ceremonyId = cid,
        userId = Nothing,
        kind = AuthenticationCeremony,
        optionsBlob = optionsBlob,
        createdAt = ts,
        expiresAt = addUTCTime (pendingCeremonyTTL (webauthnConfig cfg)) ts
      }
  pure (cid, optionsJson)

-- | Finish a passwordless login: consume the pending ceremony, resolve the user from the
-- asserted credential id (via 'findPasskeyByCredentialId', whose result carries the owning
-- user), verify, bump the counter, publish 'MfaSucceeded', and mint tokens.
completePasswordlessLogin ::
  ( UserStore :> es,
    AuthUnitOfWork :> es,
    PasskeyStore :> es,
    PendingCeremonyStore :> es,
    WebAuthnCeremony :> es,
    TokenSigner :> es,
    RoleStore :> es,
    ClaimsEnricher :> es,
    AuthEventPublisher :> es,
    Clock :> es,
    TokenGen :> es
  ) =>
  ShomeiConfig ->
  CeremonyId ->
  Value ->
  Eff es (Either AuthError (User, TokenPair))
completePasswordlessLogin cfg ceremonyId assertion = runErrorNoCallStack do
  ts <- now
  PendingCeremony {kind, optionsBlob} <-
    maybe (throwError PendingCeremonyNotFound) pure =<< takePendingCeremony ceremonyId ts
  when (kind /= AuthenticationCeremony) (throwError PendingCeremonyNotFound)
  (passkey, verified) <- verifyAssertion Nothing optionsBlob assertion
  let PasskeyCredential {userId = pkUid, passkeyId} = passkey
      VerifiedAuthentication {newSignCounter} = verified
  user <- maybe (throwError InvalidCredentials) pure =<< findUserById pkUid
  let User {status = userStatus} = user
  when (userStatus /= UserActive) (throwError UserNotActive)
  -- The assertion is already verified above, so the account's existence is not in question.
  either throwError pure (ensureEmailVerified cfg user)
  updatePasskeySignCounter passkeyId newSignCounter ts
  (sid, pair) <- issueSession cfg user ts
  publishAuthEvent (Event.MfaSucceeded (Event.MfaSucceededData pkUid sid ts))
  pure (user, pair)

-- | Verify a WebAuthn assertion against the stored passkey it names. Reads the credential
-- id from the assertion JSON (the lookup key — the cryptographic verification still happens in
-- the ceremony interpreter), looks the passkey up to build the verifier input, and calls
-- 'completeAuthenticationCeremony'. On a decode/verify failure, a clone-counter warning, or a
-- missing credential, publishes 'MfaFailed' and throws 'MfaAssertionInvalid'. Returns the
-- looked-up passkey (so callers can read its owning user) alongside the verified result.
verifyAssertion ::
  ( PasskeyStore :> es,
    WebAuthnCeremony :> es,
    AuthEventPublisher :> es,
    Clock :> es,
    Error AuthError :> es
  ) =>
  Maybe UserId ->
  ByteString ->
  Value ->
  Eff es (PasskeyCredential, VerifiedAuthentication)
verifyAssertion mUid blob assertion = do
  cid <- maybe (failMfa mUid "missing credential id") pure (assertionCredentialId assertion)
  passkey <- maybe (failMfa mUid "unknown credential") pure =<< findPasskeyByCredentialId cid
  let PasskeyCredential {credentialId, userHandle, publicKey, signCounter, transports} = passkey
      stored =
        StoredCredentialForVerify
          { credentialId,
            userHandle,
            publicKey,
            signCounter,
            transports
          }
  res <- completeAuthenticationCeremony blob stored assertion
  case res of
    Left _ -> failMfa mUid "assertion verification failed"
    Right verified ->
      let VerifiedAuthentication {cloneWarning} = verified
       in if cloneWarning
            then failMfa mUid "signature counter clone warning"
            else pure (passkey, verified)

-- | Publish 'MfaFailed' and abort with the generic 'MfaAssertionInvalid'. The reason is
-- recorded in the audit event only; the HTTP body the caller eventually returns stays generic.
failMfa ::
  (AuthEventPublisher :> es, Clock :> es, Error AuthError :> es) =>
  Maybe UserId ->
  Text ->
  Eff es a
failMfa mUid reason = do
  ts <- now
  publishAuthEvent (Event.MfaFailed (Event.MfaFailedData mUid reason ts))
  throwError MfaAssertionInvalid

-- | Read the credential id out of the browser's assertion JSON, the key used to look the
-- stored passkey up. The deterministic fake interpreter uses @"credentialId"@; a real
-- @webauthn-json@ assertion uses @"rawId"@ (or @"id"@). All three are base64url text decoded
-- by 'WebAuthnCredentialId''s 'FromJSON'. This is the one place the core peeks into the
-- assertion JSON, and only for a lookup key — the cryptographic verification is entirely in the
-- ceremony interpreter.
assertionCredentialId :: Value -> Maybe WebAuthnCredentialId
assertionCredentialId v =
  parseField "credentialId" <|> parseField "rawId" <|> parseField "id"
  where
    parseField k = parseMaybe (withObject "assertion" (\o -> o .: k)) v
