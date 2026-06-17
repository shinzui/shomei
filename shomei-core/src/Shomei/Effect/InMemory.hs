{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}

{- | A pure, in-memory interpreter for every Shōmei port, backing the EP-2 test suite.

A single mutable 'World' (held in an 'IORef') holds the user/credential/session/
refresh-token/signing-key stores plus the published-event log, a fixed test clock, and
a deterministic token counter. 'runInMemory' stacks an interpreter for every port over
'IOE'. There is no database, JWT library, or network here: the
'Shomei.Effect.PasswordHasher' fake tags and compares plaintext, the
'Shomei.Effect.TokenGen' fake emits @rt-0@, @rt-1@, … and the
'Shomei.Effect.TokenSigner'/'Shomei.Effect.TokenVerifier' fakes round-trip 'AuthClaims'
through JSON.
-}
module Shomei.Effect.InMemory (
    World (..),
    emptyWorld,
    runInMemory,

    -- * Individual interpreters

    {- | Exported so an assembly can compose a /hybrid/ stack — e.g. these
    in-memory store/support interpreters together with EP-4's real @jose@
    'Shomei.Effect.TokenSigner'/'Shomei.Effect.TokenVerifier' interpreters — keeping
    the same effect order as 'runInMemory'. ('Shomei.Servant''s end-to-end test
    uses exactly that hybrid so signing/verification exercise real ES256.)
    -}
    runUserStore,
    runCredentialStore,
    runSessionStore,
    runRefreshTokenStore,
    runVerificationTokenStore,
    runPasswordResetTokenStore,
    runLoginAttemptStore,
    runPasskeyStore,
    runPendingCeremonyStore,
    runNotifier,
    runPasswordHasher,
    runAuthEventPublisher,
    runSigningKeyStore,
    runClock,
    runTokenGen,
    runWebAuthnCeremonyFake,
) where

import Shomei.Prelude

import Data.Aeson (Value, eitherDecode, eitherDecodeStrict', encode, object)
import Data.Aeson qualified as Aeson
import Data.Aeson.Types (Parser, parseMaybe, withObject, (.:))
import Data.ByteString (ByteString)
import Data.ByteString.Lazy qualified as LBS
import Data.Generics.Labels ()
import Data.IORef (IORef, modifyIORef', readIORef, writeIORef)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (listToMaybe)
import Data.Text qualified as Text
import Data.Text.Lazy qualified as TL
import Data.Text.Lazy.Encoding qualified as TLE

import Effectful (Eff, IOE, runEff, (:>))
import Effectful.Dispatch.Dynamic (interpret_)

import Shomei.Domain.Claims (AuthClaims)
import Shomei.Domain.Credential (Credential (..))
import Shomei.Domain.Passkey (
    NewPasskeyCredential (..),
    PasskeyCredential (..),
    PendingCeremony (..),
    PublicKeyBytes,
    SignatureCounter (..),
    UserHandle,
    WebAuthnCredentialId,
 )
import Shomei.Domain.Email (Email)
import Shomei.Domain.Event qualified as Event
import Shomei.Domain.LoginAttempt (
    AccountKey,
    AccountLockout (..),
    LoginAttempt (..),
    LoginOutcome (..),
    NewLoginAttempt (..),
 )
import Shomei.Domain.Notification (Notification)
import Shomei.Domain.OneTimeToken (OneTimeTokenHash, OneTimeTokenStatus (..))
import Shomei.Domain.Password (PasswordHash (..), PlainPassword (..))
import Shomei.Domain.PasswordResetToken (NewPasswordResetToken (..), PersistedPasswordResetToken (..))
import Shomei.Domain.RefreshToken (
    NewRefreshToken (..),
    PersistedRefreshToken (..),
    RefreshToken (..),
    RefreshTokenHash (..),
    RefreshTokenStatus (..),
 )
import Shomei.Domain.Session (NewSession (..), Session (..), SessionStatus (..))
import Shomei.Domain.SigningKey (SigningKeyStatus (..), StoredSigningKey (..))
import Shomei.Domain.Token (AccessToken (..))
import Shomei.Domain.User (NewUser (..), User (..), UserStatus (..))
import Shomei.Domain.VerificationToken (NewVerificationToken (..), PersistedVerificationToken (..))
import Shomei.Error (TokenError (..))
import Shomei.Id (
    CeremonyId,
    PasskeyId,
    PasswordResetTokenId,
    RefreshTokenId,
    SessionId,
    UserId,
    VerificationTokenId,
    genCredentialId,
    genPasskeyId,
    genPasswordResetTokenId,
    genRefreshTokenId,
    genSessionId,
    genUserId,
    genVerificationTokenId,
 )

import Shomei.Effect.AuthEventPublisher (AuthEventPublisher (..))
import Shomei.Effect.Clock (Clock (..))
import Shomei.Effect.CredentialStore (CredentialStore (..))
import Shomei.Effect.LoginAttemptStore (LoginAttemptStore (..))
import Shomei.Effect.Notifier (Notifier (..))
import Shomei.Effect.PasskeyStore (PasskeyStore (..))
import Shomei.Effect.PasswordHasher (PasswordHasher (..))
import Shomei.Effect.PasswordResetTokenStore (PasswordResetTokenStore (..))
import Shomei.Effect.PendingCeremonyStore (PendingCeremonyStore (..))
import Shomei.Effect.RefreshTokenStore (RefreshTokenStore (..))
import Shomei.Effect.SessionStore (SessionStore (..))
import Shomei.Effect.SigningKeyStore (SigningKeyStore (..))
import Shomei.Effect.TokenGen (TokenGen (..))
import Shomei.Effect.TokenSigner (TokenSigner (..))
import Shomei.Effect.TokenVerifier (TokenVerifier (..))
import Shomei.Effect.UserStore (UserStore (..))
import Shomei.Effect.VerificationTokenStore (VerificationTokenStore (..))
import Shomei.Effect.WebAuthnCeremony (
    BeginCeremony (..),
    StoredCredentialForVerify (..),
    VerifiedAuthentication (..),
    VerifiedRegistration (..),
    WebAuthnCeremony (..),
    WebAuthnError (..),
 )

-- | The whole mutable test world.
data World = World
    { users :: !(Map UserId User)
    , credsByEmail :: !(Map Email Credential)
    , sessions :: !(Map SessionId Session)
    , refreshTokens :: !(Map RefreshTokenId PersistedRefreshToken)
    , refreshByHash :: !(Map RefreshTokenHash RefreshTokenId)
    , verificationTokens :: !(Map VerificationTokenId PersistedVerificationToken)
    , verificationByHash :: !(Map OneTimeTokenHash VerificationTokenId)
    , passwordResetTokens :: !(Map PasswordResetTokenId PersistedPasswordResetToken)
    , passwordResetByHash :: !(Map OneTimeTokenHash PasswordResetTokenId)
    , signingKeys :: !(Map Text StoredSigningKey)
    , loginAttempts :: ![LoginAttempt]
    -- ^ newest-first append-only attempt log (EP-2 brute-force protection)
    , accountLockouts :: !(Map AccountKey AccountLockout)
    , passkeys :: !(Map PasskeyId PasskeyCredential)
    , pendingCeremonies :: !(Map CeremonyId PendingCeremony)
    , publishedEvents :: ![Event.AuthEvent]
    -- ^ newest-first
    , sentNotifications :: ![Notification]
    -- ^ newest-first
    , clock :: !UTCTime
    -- ^ fixed test time
    , tokenCounter :: !Int
    -- ^ deterministic opaque tokens
    , ceremonyCounter :: !Int
    -- ^ deterministic WebAuthn ceremony challenges (fake interpreter)
    }
    deriving stock (Generic)

emptyWorld :: UTCTime -> World
emptyWorld t =
    World
        { users = Map.empty
        , credsByEmail = Map.empty
        , sessions = Map.empty
        , refreshTokens = Map.empty
        , refreshByHash = Map.empty
        , verificationTokens = Map.empty
        , verificationByHash = Map.empty
        , passwordResetTokens = Map.empty
        , passwordResetByHash = Map.empty
        , signingKeys = Map.empty
        , loginAttempts = []
        , accountLockouts = Map.empty
        , passkeys = Map.empty
        , pendingCeremonies = Map.empty
        , publishedEvents = []
        , sentNotifications = []
        , clock = t
        , tokenCounter = 0
        , ceremonyCounter = 0
        }

-- Token signer/verifier fakes: round-trip claims through JSON.

renderClaims :: AuthClaims -> Text
renderClaims = TL.toStrict . TLE.decodeUtf8 . encode

parseClaims :: Text -> Either TokenError AuthClaims
parseClaims t = case eitherDecode (TLE.encodeUtf8 (TL.fromStrict t)) of
    Left _ -> Left TokenMalformed
    Right c -> Right c

-- | Walk to the root of a refresh-token family by following @parentTokenId@ links.
rootOf :: Map RefreshTokenId PersistedRefreshToken -> RefreshTokenId -> RefreshTokenId
rootOf m tid = case Map.lookup tid m of
    Just t -> maybe tid (rootOf m) t.parentTokenId
    Nothing -> tid

runUserStore :: (IOE :> es) => IORef World -> Eff (UserStore : es) a -> Eff es a
runUserStore ref = interpret_ \case
    CreateUser nu -> do
        uid <- genUserId
        w <- liftIO (readIORef ref)
        let u =
                User
                    { userId = uid
                    , email = nu.email
                    , displayName = nu.displayName
                    , status = UserActive
                    , emailVerifiedAt = Nothing
                    , createdAt = w.clock
                    , updatedAt = w.clock
                    }
        liftIO (modifyIORef' ref (#users %~ Map.insert uid u))
        pure u
    FindUserById uid -> liftIO ((Map.lookup uid . (.users)) <$> readIORef ref)
    FindUserByEmail e -> liftIO (findByEmail e <$> readIORef ref)
    UpdateUserStatus uid st ->
        liftIO (modifyIORef' ref (#users %~ Map.adjust (#status .~ st) uid))
    MarkUserEmailVerified uid t ->
        liftIO (modifyIORef' ref (#users %~ Map.adjust (#emailVerifiedAt .~ Just t) uid))
  where
    findByEmail e w = listToMaybe [u | u <- Map.elems w.users, u.email == e]

runCredentialStore :: (IOE :> es) => IORef World -> Eff (CredentialStore : es) a -> Eff es a
runCredentialStore ref = interpret_ \case
    CreatePasswordCredential uid e h -> do
        cid <- genCredentialId
        w <- liftIO (readIORef ref)
        let c =
                PasswordCredential
                    { credentialId = cid
                    , userId = uid
                    , email = e
                    , passwordHash = h
                    , createdAt = w.clock
                    , updatedAt = w.clock
                    }
        liftIO (modifyIORef' ref (#credsByEmail %~ Map.insert e c))
        pure c
    FindPasswordCredentialByEmail e ->
        liftIO ((Map.lookup e . (.credsByEmail)) <$> readIORef ref)
    UpdatePasswordHash uid h ->
        liftIO
            ( modifyIORef'
                ref
                (#credsByEmail %~ Map.map (\c -> if c.userId == uid then c & #passwordHash .~ h else c))
            )

runSessionStore :: (IOE :> es) => IORef World -> Eff (SessionStore : es) a -> Eff es a
runSessionStore ref = interpret_ \case
    CreateSession ns -> do
        sid <- genSessionId
        let s = mkSession sid ns
        liftIO (modifyIORef' ref (#sessions %~ Map.insert sid s))
        pure s
    FindSessionById sid -> liftIO ((Map.lookup sid . (.sessions)) <$> readIORef ref)
    RevokeSession sid t ->
        liftIO (modifyIORef' ref (#sessions %~ Map.adjust (revoke t) sid))
    RevokeAllUserSessions uid t ->
        liftIO
            ( modifyIORef'
                ref
                (#sessions %~ Map.map (\s -> if s.userId == uid then revoke t s else s))
            )
  where
    revoke t s = s & #status .~ SessionRevoked & #revokedAt .~ Just t

-- Build a fresh Session from a NewSession (kept separate to avoid a long inline record).
mkSession :: SessionId -> NewSession -> Session
mkSession sid ns =
    Session
        { sessionId = sid
        , userId = ns.userId
        , status = SessionActive
        , createdAt = ns.createdAt
        , expiresAt = ns.expiresAt
        , revokedAt = Nothing
        , actor = ns.actor
        }

runRefreshTokenStore :: (IOE :> es) => IORef World -> Eff (RefreshTokenStore : es) a -> Eff es a
runRefreshTokenStore ref = interpret_ \case
    CreateRefreshToken nrt -> do
        rid <- genRefreshTokenId
        let prt = mkPersisted rid nrt
        liftIO
            ( modifyIORef'
                ref
                ( (#refreshTokens %~ Map.insert rid prt)
                    . (#refreshByHash %~ Map.insert nrt.tokenHash rid)
                )
            )
        pure prt
    FindRefreshTokenByHash h ->
        liftIO (lookupByHash h <$> readIORef ref)
    MarkRefreshTokenUsed rid t ->
        liftIO (modifyIORef' ref (#refreshTokens %~ Map.adjust (markUsed t) rid))
    RevokeRefreshTokenFamily rid t ->
        liftIO (modifyIORef' ref (revokeFamily rid t))
    RevokeSessionRefreshTokens sid t ->
        liftIO
            ( modifyIORef'
                ref
                (#refreshTokens %~ Map.map (\tok -> if tok.sessionId == sid then revoke t tok else tok))
            )
    RevokeAllUserRefreshTokens uid t ->
        liftIO
            ( modifyIORef'
                ref
                ( \w ->
                    w
                        & #refreshTokens
                        %~ Map.map
                            ( \tok ->
                                case Map.lookup tok.sessionId w.sessions of
                                    Just s | s.userId == uid -> revoke t tok
                                    _ -> tok
                            )
                )
            )
  where
    markUsed t tok = tok & #status .~ RefreshTokenUsed & #usedAt .~ Just t
    revoke t tok = tok & #status .~ RefreshTokenRevoked & #revokedAt .~ Just t
    lookupByHash h w = do
        rid <- Map.lookup h w.refreshByHash
        Map.lookup rid w.refreshTokens
    revokeFamily rid t w =
        let m = w.refreshTokens
            target = rootOf m rid
            m' = Map.map (\tok -> if rootOf m tok.refreshTokenId == target then revoke t tok else tok) m
         in w & #refreshTokens .~ m'

mkPersisted :: RefreshTokenId -> NewRefreshToken -> PersistedRefreshToken
mkPersisted rid nrt =
    PersistedRefreshToken
        { refreshTokenId = rid
        , sessionId = nrt.sessionId
        , tokenHash = nrt.tokenHash
        , parentTokenId = nrt.parentTokenId
        , status = RefreshTokenActive
        , createdAt = nrt.createdAt
        , expiresAt = nrt.expiresAt
        , usedAt = Nothing
        , revokedAt = Nothing
        }

runVerificationTokenStore :: (IOE :> es) => IORef World -> Eff (VerificationTokenStore : es) a -> Eff es a
runVerificationTokenStore ref = interpret_ \case
    CreateVerificationToken nvt -> do
        tid <- genVerificationTokenId
        let tok = mkVerificationToken tid nvt
        liftIO
            ( modifyIORef'
                ref
                ( (#verificationTokens %~ Map.insert tid tok)
                    . (#verificationByHash %~ Map.insert nvt.tokenHash tid)
                )
            )
        pure tok
    FindVerificationTokenByHash h ->
        liftIO (lookupVerification h <$> readIORef ref)
    MarkVerificationTokenConsumed tid t ->
        liftIO (modifyIORef' ref (#verificationTokens %~ Map.adjust (consume t) tid))
    RevokeUserVerificationTokens uid t ->
        liftIO (modifyIORef' ref (#verificationTokens %~ Map.map (\tok -> if tok.userId == uid then revoke t tok else tok)))
  where
    lookupVerification h w = do
        tid <- Map.lookup h w.verificationByHash
        Map.lookup tid w.verificationTokens
    consume t tok = tok & #status .~ OneTimeTokenConsumed & #consumedAt .~ Just t
    revoke t tok = tok & #status .~ OneTimeTokenRevoked & #revokedAt .~ Just t

mkVerificationToken :: VerificationTokenId -> NewVerificationToken -> PersistedVerificationToken
mkVerificationToken tid nvt =
    PersistedVerificationToken
        { verificationTokenId = tid
        , userId = nvt.userId
        , tokenHash = nvt.tokenHash
        , status = OneTimeTokenActive
        , createdAt = nvt.createdAt
        , expiresAt = nvt.expiresAt
        , consumedAt = Nothing
        , revokedAt = Nothing
        }

runPasswordResetTokenStore :: (IOE :> es) => IORef World -> Eff (PasswordResetTokenStore : es) a -> Eff es a
runPasswordResetTokenStore ref = interpret_ \case
    CreatePasswordResetToken nrt -> do
        tid <- genPasswordResetTokenId
        let tok = mkPasswordResetToken tid nrt
        liftIO
            ( modifyIORef'
                ref
                ( (#passwordResetTokens %~ Map.insert tid tok)
                    . (#passwordResetByHash %~ Map.insert nrt.tokenHash tid)
                )
            )
        pure tok
    FindPasswordResetTokenByHash h ->
        liftIO (lookupReset h <$> readIORef ref)
    MarkPasswordResetTokenConsumed tid t ->
        liftIO (modifyIORef' ref (#passwordResetTokens %~ Map.adjust (consume t) tid))
    RevokeUserPasswordResetTokens uid t ->
        liftIO (modifyIORef' ref (#passwordResetTokens %~ Map.map (\tok -> if tok.userId == uid then revoke t tok else tok)))
  where
    lookupReset h w = do
        tid <- Map.lookup h w.passwordResetByHash
        Map.lookup tid w.passwordResetTokens
    consume t tok = tok & #status .~ OneTimeTokenConsumed & #consumedAt .~ Just t
    revoke t tok = tok & #status .~ OneTimeTokenRevoked & #revokedAt .~ Just t

mkPasswordResetToken :: PasswordResetTokenId -> NewPasswordResetToken -> PersistedPasswordResetToken
mkPasswordResetToken tid nrt =
    PersistedPasswordResetToken
        { passwordResetTokenId = tid
        , userId = nrt.userId
        , tokenHash = nrt.tokenHash
        , status = OneTimeTokenActive
        , createdAt = nrt.createdAt
        , expiresAt = nrt.expiresAt
        , consumedAt = Nothing
        , revokedAt = Nothing
        }

runLoginAttemptStore :: (IOE :> es) => IORef World -> Eff (LoginAttemptStore : es) a -> Eff es a
runLoginAttemptStore ref = interpret_ \case
    RecordLoginAttempt na ->
        liftIO (modifyIORef' ref (#loginAttempts %~ (toAttempt na :)))
    CountRecentFailuresByAccount k cutoff ->
        liftIO (countAccountFailures k cutoff <$> readIORef ref)
    CountRecentFailuresByIp ip cutoff ->
        liftIO (countWith (\a -> a.clientIp == ip) cutoff <$> readIORef ref)
    GetAccountLockout k ->
        liftIO ((Map.lookup k . (.accountLockouts)) <$> readIORef ref)
    SetAccountLockout lo ->
        liftIO (modifyIORef' ref (#accountLockouts %~ Map.insert lo.accountKey lo))
    ClearAccountLockout k ->
        liftIO (modifyIORef' ref (#accountLockouts %~ Map.delete k))
  where
    toAttempt na =
        LoginAttempt
            { accountKey = na.accountKey
            , clientIp = na.clientIp
            , outcome = na.outcome
            , occurredAt = na.occurredAt
            }
    -- Pure windowed failure count (used for the per-IP throttle).
    countWith p cutoff w =
        length
            [ a | a <- w.loginAttempts, p a, a.outcome == LoginFailure, a.occurredAt >= cutoff
            ]
    -- Per-account failures within the window AND strictly after the most recent success,
    -- so a successful login resets the account's brute-force progress (counter-reset-on-success)
    -- while the window still bounds the lookback.
    countAccountFailures k cutoff w =
        let successes =
                [ a.occurredAt | a <- w.loginAttempts, a.accountKey == k, a.outcome == LoginSuccess
                ]
            lastSuccess = if null successes then Nothing else Just (maximum successes)
            afterSuccess a = maybe True (\ls -> a.occurredAt > ls) lastSuccess
         in length
                [ a
                | a <- w.loginAttempts
                , a.accountKey == k
                , a.outcome == LoginFailure
                , a.occurredAt >= cutoff
                , afterSuccess a
                ]

{- | Field accessors for the EP-1 passkey records. 'OverloadedRecordDot' is unreliable
for these @DuplicateRecordFields@ records (MasterPlan 3 discovery), so read them with
plain record-pattern matching instead of @value.field@.
-}
pkUserId :: PasskeyCredential -> UserId
pkUserId PasskeyCredential{userId} = userId

pkCredentialId :: PasskeyCredential -> WebAuthnCredentialId
pkCredentialId PasskeyCredential{credentialId} = credentialId

pkUserHandle :: PasskeyCredential -> UserHandle
pkUserHandle PasskeyCredential{userHandle} = userHandle

pcCeremonyId :: PendingCeremony -> CeremonyId
pcCeremonyId PendingCeremony{ceremonyId} = ceremonyId

pcExpiresAt :: PendingCeremony -> UTCTime
pcExpiresAt PendingCeremony{expiresAt} = expiresAt

runPasskeyStore :: (IOE :> es) => IORef World -> Eff (PasskeyStore : es) a -> Eff es a
runPasskeyStore ref = interpret_ \case
    CreatePasskey NewPasskeyCredential{userId, credentialId, userHandle, publicKey, signCounter, transports, label, createdAt} -> do
        pid <- genPasskeyId
        let pc =
                PasskeyCredential
                    { passkeyId = pid
                    , userId
                    , credentialId
                    , userHandle
                    , publicKey
                    , signCounter
                    , transports
                    , label
                    , createdAt
                    , lastUsedAt = Nothing
                    }
        liftIO (modifyIORef' ref (#passkeys %~ Map.insert pid pc))
        pure pc
    FindPasskeysByUser uid ->
        liftIO ((\w -> [p | p <- Map.elems w.passkeys, pkUserId p == uid]) <$> readIORef ref)
    FindPasskeyByCredentialId cid ->
        liftIO ((\w -> listToMaybe [p | p <- Map.elems w.passkeys, pkCredentialId p == cid]) <$> readIORef ref)
    FindPasskeysByUserHandle uh ->
        liftIO ((\w -> [p | p <- Map.elems w.passkeys, pkUserHandle p == uh]) <$> readIORef ref)
    UpdatePasskeySignCounter pid c t ->
        liftIO (modifyIORef' ref (#passkeys %~ Map.adjust (\p -> p & #signCounter .~ c & #lastUsedAt .~ Just t) pid))
    DeletePasskey uid pid ->
        liftIO (modifyIORef' ref (#passkeys %~ Map.update (\p -> if pkUserId p == uid then Nothing else Just p) pid))
    CountPasskeysByUser uid ->
        liftIO ((\w -> length [p | p <- Map.elems w.passkeys, pkUserId p == uid]) <$> readIORef ref)

runPendingCeremonyStore :: (IOE :> es) => IORef World -> Eff (PendingCeremonyStore : es) a -> Eff es a
runPendingCeremonyStore ref = interpret_ \case
    PutPendingCeremony pc ->
        liftIO (modifyIORef' ref (#pendingCeremonies %~ Map.insert (pcCeremonyId pc) pc))
    TakePendingCeremony cid now' -> liftIO do
        w <- readIORef ref
        case Map.lookup cid w.pendingCeremonies of
            Nothing -> pure Nothing
            Just pc -> do
                -- Consume-once: remove the row regardless, so an expired take also
                -- clears the stale row; return it only if it is still live.
                modifyIORef' ref (#pendingCeremonies %~ Map.delete cid)
                pure (if pcExpiresAt pc > now' then Just pc else Nothing)
    DeleteExpiredCeremonies now' ->
        liftIO (modifyIORef' ref (#pendingCeremonies %~ Map.filter (\pc -> pcExpiresAt pc > now')))

runPasswordHasher :: IORef World -> Eff (PasswordHasher : es) a -> Eff es a
runPasswordHasher _ref = interpret_ \case
    HashPassword (PlainPassword pw) -> pure (PasswordHash ("argon2-fake:" <> pw))
    VerifyPassword (PlainPassword pw) (PasswordHash h) -> pure (h == "argon2-fake:" <> pw)

runTokenSigner :: Eff (TokenSigner : es) a -> Eff es a
runTokenSigner = interpret_ \case
    SignAccessToken claims -> pure (AccessToken (renderClaims claims))

runTokenVerifier :: Eff (TokenVerifier : es) a -> Eff es a
runTokenVerifier = interpret_ \case
    VerifyAccessToken (AccessToken t) -> pure (parseClaims t)

runAuthEventPublisher :: (IOE :> es) => IORef World -> Eff (AuthEventPublisher : es) a -> Eff es a
runAuthEventPublisher ref = interpret_ \case
    PublishAuthEvent ev -> liftIO (modifyIORef' ref (#publishedEvents %~ (ev :)))

runNotifier :: (IOE :> es) => IORef World -> Eff (Notifier : es) a -> Eff es a
runNotifier ref = interpret_ \case
    SendNotification n -> liftIO (modifyIORef' ref (#sentNotifications %~ (n :)))

runSigningKeyStore :: (IOE :> es) => IORef World -> Eff (SigningKeyStore : es) a -> Eff es a
runSigningKeyStore ref = interpret_ \case
    ListActiveSigningKeys ->
        liftIO (activeKeys <$> readIORef ref)
    FindSigningKeyByKid kid ->
        liftIO ((Map.lookup kid . (.signingKeys)) <$> readIORef ref)
    InsertSigningKey k ->
        liftIO (modifyIORef' ref (#signingKeys %~ Map.insert k.keyId k))
    UpdateSigningKeyStatus kid st _t ->
        liftIO (modifyIORef' ref (#signingKeys %~ Map.adjust (#status .~ st) kid))
  where
    activeKeys w = [k | k <- Map.elems w.signingKeys, k.status == KeyActive]

runClock :: (IOE :> es) => IORef World -> Eff (Clock : es) a -> Eff es a
runClock ref = interpret_ \case
    Now -> liftIO ((.clock) <$> readIORef ref)

runTokenGen :: (IOE :> es) => IORef World -> Eff (TokenGen : es) a -> Eff es a
runTokenGen ref = interpret_ \case
    GenerateOpaqueToken -> liftIO do
        w <- readIORef ref
        let n = w.tokenCounter
        writeIORef ref (w & #tokenCounter .~ (n + 1))
        pure (RefreshToken ("rt-" <> Text.pack (show n)))
    HashRefreshToken (RefreshToken t) -> pure (RefreshTokenHash ("hash:" <> t))

{- | A deterministic, cryptography-free fake of 'WebAuthnCeremony' for tests
(EP-3/EP-4 drive their workflows through this without a real authenticator).

The contract a test must follow:

  * A /begin/ step ('BeginRegistrationCeremony' / 'BeginAuthenticationCeremony')
    returns a 'BeginCeremony' whose @optionsJson@ is the canned object
    @{ "challenge": "ceremony-challenge-N" }@ (N from a per-'World' counter) and
    whose @optionsBlob@ is the UTF-8 'Data.Aeson.encode' of that same object, so the
    blob and the JSON always agree on the challenge.

  * To complete, the test crafts a credential 'Value' echoing the blob's challenge
    plus the credential fields it wants verified — an object with keys
    @challenge@ (matching the begin step), and base64url-without-padding strings
    @credentialId@, @userHandle@, @publicKey@. 'CompleteRegistrationCeremony'
    succeeds with those fields and @signCounter = 0@ when the challenges match,
    else returns @Left WebAuthnChallengeMismatch@ (or @Left WebAuthnDecodeError@ for
    malformed JSON).

  * 'CompleteAuthenticationCeremony' additionally requires the crafted
    @credentialId@ to equal the @StoredCredentialForVerify@'s; on success it returns
    @newSignCounter = stored + 1@ and @cloneWarning = False@, on a credential-id
    mismatch @Left WebAuthnSignatureInvalid@, on a challenge mismatch
    @Left WebAuthnChallengeMismatch@.
-}
runWebAuthnCeremonyFake :: (IOE :> es) => IORef World -> Eff (WebAuthnCeremony : es) a -> Eff es a
runWebAuthnCeremonyFake ref = interpret_ \case
    BeginRegistrationCeremony _userInfo _exclude -> liftIO (mkCannedCeremony ref)
    BeginAuthenticationCeremony _allow -> liftIO (mkCannedCeremony ref)
    CompleteRegistrationCeremony blob credJson -> pure (fakeCompleteRegistration blob credJson)
    CompleteAuthenticationCeremony blob stored credJson ->
        pure (fakeCompleteAuthentication blob stored credJson)

-- Build a canned begin result with a deterministic, counter-derived challenge.
mkCannedCeremony :: IORef World -> IO BeginCeremony
mkCannedCeremony ref = do
    w <- readIORef ref
    let n = w.ceremonyCounter
    writeIORef ref (w & #ceremonyCounter .~ (n + 1))
    let chal = "ceremony-challenge-" <> Text.pack (show n)
        optionsJson = object ["challenge" Aeson..= chal]
    pure BeginCeremony{optionsJson, optionsBlob = LBS.toStrict (encode optionsJson)}

-- The challenge baked into a begin step's options blob.
blobChallenge :: ByteString -> Maybe Text
blobChallenge blob = case eitherDecodeStrict' blob of
    Right v -> parseMaybe (withObject "options" (.: "challenge")) v
    Left _ -> Nothing

-- Parse the test-crafted credential JSON into (challenge, credentialId, userHandle, publicKey).
credentialFields :: Value -> Parser (Text, WebAuthnCredentialId, UserHandle, PublicKeyBytes)
credentialFields = withObject "credential" $ \o ->
    (,,,) <$> o .: "challenge" <*> o .: "credentialId" <*> o .: "userHandle" <*> o .: "publicKey"

fakeCompleteRegistration :: ByteString -> Value -> Either WebAuthnError VerifiedRegistration
fakeCompleteRegistration blob credJson =
    case parseMaybe credentialFields credJson of
        Nothing -> Left (WebAuthnDecodeError "fake: malformed credential JSON")
        Just (chal, cid, uh, pk)
            | blobChallenge blob == Just chal ->
                Right
                    VerifiedRegistration
                        { credentialId = cid
                        , userHandle = uh
                        , publicKey = pk
                        , signCounter = SignatureCounter 0
                        , transports = []
                        }
            | otherwise -> Left WebAuthnChallengeMismatch

fakeCompleteAuthentication
    :: ByteString -> StoredCredentialForVerify -> Value -> Either WebAuthnError VerifiedAuthentication
fakeCompleteAuthentication blob StoredCredentialForVerify{credentialId = storedCid, signCounter = SignatureCounter n} credJson =
    case parseMaybe credentialFields credJson of
        Nothing -> Left (WebAuthnDecodeError "fake: malformed credential JSON")
        Just (chal, cid, _uh, _pk)
            | blobChallenge blob /= Just chal -> Left WebAuthnChallengeMismatch
            | storedCid /= cid -> Left WebAuthnSignatureInvalid
            | otherwise ->
                Right
                    VerifiedAuthentication
                        { credentialId = storedCid
                        , newSignCounter = SignatureCounter (n + 1)
                        , cloneWarning = False
                        }

-- | Run an 'Eff' computation that uses every port against a shared in-memory 'World'.
runInMemory ::
    IORef World ->
    Eff
        [ UserStore
        , CredentialStore
        , SessionStore
        , RefreshTokenStore
        , VerificationTokenStore
        , PasswordResetTokenStore
        , LoginAttemptStore
        , PasskeyStore
        , PendingCeremonyStore
        , Notifier
        , WebAuthnCeremony
        , PasswordHasher
        , TokenSigner
        , TokenVerifier
        , AuthEventPublisher
        , SigningKeyStore
        , Clock
        , TokenGen
        , IOE
        ]
        a ->
    IO a
runInMemory ref =
    runEff
        . runTokenGen ref
        . runClock ref
        . runSigningKeyStore ref
        . runAuthEventPublisher ref
        . runTokenVerifier
        . runTokenSigner
        . runPasswordHasher ref
        . runWebAuthnCeremonyFake ref
        . runNotifier ref
        . runPendingCeremonyStore ref
        . runPasskeyStore ref
        . runLoginAttemptStore ref
        . runPasswordResetTokenStore ref
        . runVerificationTokenStore ref
        . runRefreshTokenStore ref
        . runSessionStore ref
        . runCredentialStore ref
        . runUserStore ref
