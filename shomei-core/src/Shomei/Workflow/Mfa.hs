{- | The second-factor (MFA step-up) and passwordless passkey login workflows (EP-4).

'prepareMfaChallenge' is the step-up branch of 'Shomei.Workflow.login': after a correct
password for an account that has a passkey (and @mfaRequired@), it begins a WebAuthn
authentication ceremony restricted to the user's credentials, stashes it consume-once, and
returns the ceremony id + browser options WITHOUT issuing a token. 'completeMfa' finishes
that step-up: it consumes the pending ceremony, verifies the browser's assertion against the
user's stored passkey, and mints the session/tokens. 'beginPasswordlessLogin' /
'completePasswordlessLogin' authenticate with the passkey ALONE (no password): begin emits
options for a discoverable credential, complete resolves the account from the asserted
credential id, verifies, and mints tokens.

All token-minting paths share 'Shomei.Workflow.Session.issueSession' so the tail never
drifts. The EP-1 passkey/ceremony records are read via plain record-pattern matching, not
@value.field@ dot syntax, because @OverloadedRecordDot@/@HasField@ is unreliable for those
@DuplicateRecordFields@ records (a MasterPlan-3 discovery).
-}
module Shomei.Workflow.Mfa (
    prepareMfaChallenge,
    completeMfa,
    beginPasswordlessLogin,
    completePasswordlessLogin,
) where

import Shomei.Prelude

import Data.Aeson (Value)
import Data.Aeson.Types (parseMaybe, withObject, (.:))
import Data.ByteString (ByteString)
import Data.Time (addUTCTime)

import Effectful (Eff, IOE, (:>))
import Effectful.Error.Static (Error, runErrorNoCallStack, throwError)

import Shomei.Config (ShomeiConfig (..), WebAuthnConfig (..))
import Shomei.Domain.Event qualified as Event
import Shomei.Domain.Passkey (
    CeremonyKind (AuthenticationCeremony),
    PasskeyCredential (..),
    PendingCeremony (..),
    WebAuthnCredentialId,
 )
import Shomei.Domain.Token (TokenPair)
import Shomei.Domain.User (User (..), UserStatus (UserActive))
import Shomei.Error (AuthError (..))
import Shomei.Id (CeremonyId, UserId, genCeremonyId)

import Shomei.Effect.AuthEventPublisher (AuthEventPublisher, publishAuthEvent)
import Shomei.Effect.Clock (Clock, now)
import Shomei.Effect.PasskeyStore (
    PasskeyStore,
    findPasskeyByCredentialId,
    findPasskeysByUser,
    updatePasskeySignCounter,
 )
import Shomei.Effect.PendingCeremonyStore (PendingCeremonyStore, putPendingCeremony, takePendingCeremony)
import Shomei.Effect.RefreshTokenStore (RefreshTokenStore)
import Shomei.Effect.SessionStore (SessionStore)
import Shomei.Effect.TokenGen (TokenGen)
import Shomei.Effect.TokenSigner (TokenSigner)
import Shomei.Effect.UserStore (UserStore, findUserById)
import Shomei.Effect.WebAuthnCeremony (
    BeginCeremony (..),
    StoredCredentialForVerify (..),
    VerifiedAuthentication (..),
    WebAuthnCeremony,
    beginAuthenticationCeremony,
    completeAuthenticationCeremony,
 )

import Shomei.Workflow.Session (issueSession)

{- | The step-up branch of 'Shomei.Workflow.login'. Begins a WebAuthn authentication
ceremony whose @allowCredentials@ is restricted to this user's enrolled passkeys, stashes
the consume-once pending ceremony (bound to the user, expiring after the configured TTL),
publishes 'MfaChallenged', and returns the ceremony id + the browser-facing options. NO
token is issued: the caller returns this as the @mfa_required@ outcome.
-}
prepareMfaChallenge ::
    ( PasskeyStore :> es
    , PendingCeremonyStore :> es
    , WebAuthnCeremony :> es
    , AuthEventPublisher :> es
    , IOE :> es
    ) =>
    ShomeiConfig ->
    User ->
    UTCTime ->
    Eff es (CeremonyId, Value)
prepareMfaChallenge cfg user ts = do
    let User{userId = uid} = user
    creds <- findPasskeysByUser uid
    let allowIds = map (\PasskeyCredential{credentialId} -> credentialId) creds
    BeginCeremony{optionsJson, optionsBlob} <- beginAuthenticationCeremony allowIds
    cid <- genCeremonyId
    putPendingCeremony
        PendingCeremony
            { ceremonyId = cid
            , userId = Just uid
            , kind = AuthenticationCeremony
            , optionsBlob = optionsBlob
            , createdAt = ts
            , expiresAt = addUTCTime (pendingCeremonyTTL (webauthnConfig cfg)) ts
            }
    publishAuthEvent (Event.MfaChallenged (Event.MfaChallengedData uid cid ts))
    pure (cid, optionsJson)

{- | Finish a password-then-passkey step-up. The client posts the ceremony id from the
'MfaRequired' challenge plus the browser's signed assertion. We consume the pending ceremony
(rejecting a missing/expired/consumed/non-authentication/no-user ceremony with a 404-mapped
'PendingCeremonyNotFound'), verify the assertion against the user's stored passkey, confirm
the asserted credential is owned by that user, bump the sign counter, publish 'MfaSucceeded',
and mint tokens via the shared 'issueSession'. A verification failure publishes 'MfaFailed'
and returns 'MfaAssertionInvalid'.
-}
completeMfa ::
    ( UserStore :> es
    , SessionStore :> es
    , RefreshTokenStore :> es
    , PasskeyStore :> es
    , PendingCeremonyStore :> es
    , WebAuthnCeremony :> es
    , TokenSigner :> es
    , AuthEventPublisher :> es
    , Clock :> es
    , TokenGen :> es
    ) =>
    ShomeiConfig ->
    CeremonyId ->
    Value ->
    Eff es (Either AuthError (User, TokenPair))
completeMfa cfg ceremonyId assertion = runErrorNoCallStack do
    ts <- now
    PendingCeremony{kind, userId = mUid, optionsBlob} <-
        maybe (throwError PendingCeremonyNotFound) pure =<< takePendingCeremony ceremonyId ts
    when (kind /= AuthenticationCeremony) (throwError PendingCeremonyNotFound)
    uid <- maybe (throwError PendingCeremonyNotFound) pure mUid
    user <- maybe (throwError InvalidCredentials) pure =<< findUserById uid
    let User{status = userStatus} = user
    when (userStatus /= UserActive) (throwError UserNotActive)
    (passkey, verified) <- verifyAssertion (Just uid) optionsBlob assertion
    let PasskeyCredential{userId = pkUid, passkeyId} = passkey
        VerifiedAuthentication{newSignCounter} = verified
    when (pkUid /= uid) (failMfa (Just uid) "credential not owned by user")
    updatePasskeySignCounter passkeyId newSignCounter ts
    (sid, pair) <- issueSession cfg user ts
    publishAuthEvent (Event.MfaSucceeded (Event.MfaSucceededData uid sid ts))
    pure (user, pair)

{- | Begin a passwordless login: emit authentication options with NO @allowCredentials@ so
the browser offers its discoverable passkeys, stash the pending ceremony with no user
attached, and hand the client the ceremony id + options.
-}
beginPasswordlessLogin ::
    ( PendingCeremonyStore :> es
    , WebAuthnCeremony :> es
    , Clock :> es
    , IOE :> es
    ) =>
    ShomeiConfig ->
    Eff es (Either AuthError (CeremonyId, Value))
beginPasswordlessLogin cfg = runErrorNoCallStack do
    ts <- now
    BeginCeremony{optionsJson, optionsBlob} <- beginAuthenticationCeremony []
    cid <- genCeremonyId
    putPendingCeremony
        PendingCeremony
            { ceremonyId = cid
            , userId = Nothing
            , kind = AuthenticationCeremony
            , optionsBlob = optionsBlob
            , createdAt = ts
            , expiresAt = addUTCTime (pendingCeremonyTTL (webauthnConfig cfg)) ts
            }
    pure (cid, optionsJson)

{- | Finish a passwordless login: consume the pending ceremony, resolve the user from the
asserted credential id (via 'findPasskeyByCredentialId', whose result carries the owning
user), verify, bump the counter, publish 'MfaSucceeded', and mint tokens.
-}
completePasswordlessLogin ::
    ( UserStore :> es
    , SessionStore :> es
    , RefreshTokenStore :> es
    , PasskeyStore :> es
    , PendingCeremonyStore :> es
    , WebAuthnCeremony :> es
    , TokenSigner :> es
    , AuthEventPublisher :> es
    , Clock :> es
    , TokenGen :> es
    ) =>
    ShomeiConfig ->
    CeremonyId ->
    Value ->
    Eff es (Either AuthError (User, TokenPair))
completePasswordlessLogin cfg ceremonyId assertion = runErrorNoCallStack do
    ts <- now
    PendingCeremony{kind, optionsBlob} <-
        maybe (throwError PendingCeremonyNotFound) pure =<< takePendingCeremony ceremonyId ts
    when (kind /= AuthenticationCeremony) (throwError PendingCeremonyNotFound)
    (passkey, verified) <- verifyAssertion Nothing optionsBlob assertion
    let PasskeyCredential{userId = pkUid, passkeyId} = passkey
        VerifiedAuthentication{newSignCounter} = verified
    user <- maybe (throwError InvalidCredentials) pure =<< findUserById pkUid
    let User{status = userStatus} = user
    when (userStatus /= UserActive) (throwError UserNotActive)
    updatePasskeySignCounter passkeyId newSignCounter ts
    (sid, pair) <- issueSession cfg user ts
    publishAuthEvent (Event.MfaSucceeded (Event.MfaSucceededData pkUid sid ts))
    pure (user, pair)

{- | Verify a WebAuthn assertion against the stored passkey it names. Reads the credential
id from the assertion JSON (the lookup key — the cryptographic verification still happens in
the ceremony interpreter), looks the passkey up to build the verifier input, and calls
'completeAuthenticationCeremony'. On a decode/verify failure, a clone-counter warning, or a
missing credential, publishes 'MfaFailed' and throws 'MfaAssertionInvalid'. Returns the
looked-up passkey (so callers can read its owning user) alongside the verified result.
-}
verifyAssertion ::
    ( PasskeyStore :> es
    , WebAuthnCeremony :> es
    , AuthEventPublisher :> es
    , Clock :> es
    , Error AuthError :> es
    ) =>
    Maybe UserId ->
    ByteString ->
    Value ->
    Eff es (PasskeyCredential, VerifiedAuthentication)
verifyAssertion mUid blob assertion = do
    cid <- maybe (failMfa mUid "missing credential id") pure (assertionCredentialId assertion)
    passkey <- maybe (failMfa mUid "unknown credential") pure =<< findPasskeyByCredentialId cid
    let PasskeyCredential{credentialId, userHandle, publicKey, signCounter, transports} = passkey
        stored =
            StoredCredentialForVerify
                { credentialId
                , userHandle
                , publicKey
                , signCounter
                , transports
                }
    res <- completeAuthenticationCeremony blob stored assertion
    case res of
        Left _ -> failMfa mUid "assertion verification failed"
        Right verified ->
            let VerifiedAuthentication{cloneWarning} = verified
             in if cloneWarning
                    then failMfa mUid "signature counter clone warning"
                    else pure (passkey, verified)

{- | Publish 'MfaFailed' and abort with the generic 'MfaAssertionInvalid'. The reason is
recorded in the audit event only; the HTTP body the caller eventually returns stays generic.
-}
failMfa ::
    (AuthEventPublisher :> es, Clock :> es, Error AuthError :> es) =>
    Maybe UserId ->
    Text ->
    Eff es a
failMfa mUid reason = do
    ts <- now
    publishAuthEvent (Event.MfaFailed (Event.MfaFailedData mUid reason ts))
    throwError MfaAssertionInvalid

{- | Read the credential id out of the browser's assertion JSON, the key used to look the
stored passkey up. The deterministic fake interpreter uses @"credentialId"@; a real
@webauthn-json@ assertion uses @"rawId"@ (or @"id"@). All three are base64url text decoded
by 'WebAuthnCredentialId''s 'FromJSON'. This is the one place the core peeks into the
assertion JSON, and only for a lookup key — the cryptographic verification is entirely in the
ceremony interpreter.
-}
assertionCredentialId :: Value -> Maybe WebAuthnCredentialId
assertionCredentialId v =
    parseField "credentialId" <|> parseField "rawId" <|> parseField "id"
  where
    parseField k = parseMaybe (withObject "assertion" (\o -> o .: k)) v
