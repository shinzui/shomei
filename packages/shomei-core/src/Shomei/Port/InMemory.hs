{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}

{- | A pure, in-memory interpreter for every Shōmei port, backing the EP-2 test suite.

A single mutable 'World' (held in an 'IORef') holds the user/credential/session/
refresh-token/signing-key stores plus the published-event log, a fixed test clock, and
a deterministic token counter. 'runInMemory' stacks an interpreter for every port over
'IOE'. There is no database, JWT library, or network here: the
'Shomei.Port.PasswordHasher' fake tags and compares plaintext, the
'Shomei.Port.TokenGen' fake emits @rt-0@, @rt-1@, … and the
'Shomei.Port.TokenSigner'/'Shomei.Port.TokenVerifier' fakes round-trip 'AuthClaims'
through JSON.
-}
module Shomei.Port.InMemory (
    World (..),
    emptyWorld,
    runInMemory,

    -- * Individual interpreters

    {- | Exported so an assembly can compose a /hybrid/ stack — e.g. these
    in-memory store/support interpreters together with EP-4's real @jose@
    'Shomei.Port.TokenSigner'/'Shomei.Port.TokenVerifier' interpreters — keeping
    the same effect order as 'runInMemory'. ('Shomei.Servant''s end-to-end test
    uses exactly that hybrid so signing/verification exercise real ES256.)
    -}
    runUserStore,
    runCredentialStore,
    runSessionStore,
    runRefreshTokenStore,
    runPasswordHasher,
    runAuthEventPublisher,
    runSigningKeyStore,
    runClock,
    runTokenGen,
) where

import Shomei.Prelude

import Data.Aeson (eitherDecode, encode)
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
import Shomei.Domain.Email (Email)
import Shomei.Domain.Event qualified as Event
import Shomei.Domain.Password (PasswordHash (..), PlainPassword (..))
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
import Shomei.Error (TokenError (..))
import Shomei.Id (
    RefreshTokenId,
    SessionId,
    UserId,
    genCredentialId,
    genRefreshTokenId,
    genSessionId,
    genUserId,
 )

import Shomei.Port.AuthEventPublisher (AuthEventPublisher (..))
import Shomei.Port.Clock (Clock (..))
import Shomei.Port.CredentialStore (CredentialStore (..))
import Shomei.Port.PasswordHasher (PasswordHasher (..))
import Shomei.Port.RefreshTokenStore (RefreshTokenStore (..))
import Shomei.Port.SessionStore (SessionStore (..))
import Shomei.Port.SigningKeyStore (SigningKeyStore (..))
import Shomei.Port.TokenGen (TokenGen (..))
import Shomei.Port.TokenSigner (TokenSigner (..))
import Shomei.Port.TokenVerifier (TokenVerifier (..))
import Shomei.Port.UserStore (UserStore (..))

-- | The whole mutable test world.
data World = World
    { users :: !(Map UserId User)
    , credsByEmail :: !(Map Email Credential)
    , sessions :: !(Map SessionId Session)
    , refreshTokens :: !(Map RefreshTokenId PersistedRefreshToken)
    , refreshByHash :: !(Map RefreshTokenHash RefreshTokenId)
    , signingKeys :: !(Map Text StoredSigningKey)
    , publishedEvents :: ![Event.AuthEvent]
    -- ^ newest-first
    , clock :: !UTCTime
    -- ^ fixed test time
    , tokenCounter :: !Int
    -- ^ deterministic opaque tokens
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
        , signingKeys = Map.empty
        , publishedEvents = []
        , clock = t
        , tokenCounter = 0
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
                    , createdAt = w.clock
                    , updatedAt = w.clock
                    }
        liftIO (modifyIORef' ref (#users %~ Map.insert uid u))
        pure u
    FindUserById uid -> liftIO ((Map.lookup uid . (.users)) <$> readIORef ref)
    FindUserByEmail e -> liftIO (findByEmail e <$> readIORef ref)
    UpdateUserStatus uid st ->
        liftIO (modifyIORef' ref (#users %~ Map.adjust (#status .~ st) uid))
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

-- | Run an 'Eff' computation that uses every port against a shared in-memory 'World'.
runInMemory ::
    IORef World ->
    Eff
        [ UserStore
        , CredentialStore
        , SessionStore
        , RefreshTokenStore
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
        . runRefreshTokenStore ref
        . runSessionStore ref
        . runCredentialStore ref
        . runUserStore ref
