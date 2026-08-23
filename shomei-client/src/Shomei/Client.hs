-- The 'HasClient' instances for 'RequireRole'/'RequireScope' delegate their associated
-- @Client@ type to the @AuthProtect "shomei-jwt"@ instance, which GHC cannot see is
-- terminating (the right-hand side is another application of the same family).
{-# LANGUAGE UndecidableInstances #-}
-- The @AuthClientData@ instance below is an unavoidable orphan (both the type family and
-- @AuthProtect "shomei-jwt"@ belong to servant; 'Token' belongs here) — the standard
-- servant generalized-auth client pattern. The two 'HasClient' instances are orphans for the
-- same reason. Silence the orphan warning for this module.
{-# OPTIONS_GHC -Wno-orphans #-}

-- | A typed Haskell client for the standalone Shōmei auth service.
--
-- The client functions are not hand-written: they are /derived/ from the exact same
-- 'Shomei.Servant.Api.ShomeiAPI' Servant type the server serves, via @servant-client@'s
-- 'genericClient'. So the client and server can never disagree about the wire format.
-- The 'Authenticated' (@AuthProtect "shomei-jwt"@) routes take a 'Token' (the Bearer JWT),
-- attached through @servant-client@'s generalized-authentication support
-- ('AuthClientData' + 'mkAuthenticatedRequest').
module Shomei.Client
  ( Token (..),
    ShomeiClient,
    shomeiClient,
    ShomeiRoutesClient,
    shomeiRoutesClient,
    shomeiClientEnv,
    runClient,
    ClientEnv,
    ClientError,
    signup,
    login,
    refresh,
    logout,
    me,
    session,
    -- passkey enrollment / management (Bearer):
    passkeyRegisterBegin,
    passkeyRegisterComplete,
    listPasskeys,
    deletePasskey,
    -- passkey login / MFA (unauthenticated):
    mfaComplete,
    passkeyLoginBegin,
    passkeyLoginComplete,
    -- machine tokens (OAuth2 client_credentials):
    oauthToken,
    TokenResponse (..),
    -- administration (Bearer; the caller needs the @admin@ role or the @shomei:admin@ scope):
    adminListUsers,
    AdminStatusFilter (..),
    UserPageCursor (..),
    adminGetUser,
    adminSuspendUser,
    adminReinstateUser,
    adminDeleteUser,
    adminListSessions,
    adminRevokeSessions,
    adminRevokeSession,
    adminPasswordReset,
    adminGrantRole,
    adminRevokeRole,
  )
where

import Data.Base64.Types (extractBase64)
import Data.ByteString.Base64 qualified as B64
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TE
import Network.HTTP.Client qualified as HTTP
import Network.HTTP.Client.TLS qualified as TLS
-- Explicitly, as a /type/: 'Shomei.Prelude' re-exports lens, whose @(:>)@ snoc pattern synonym
-- would otherwise win.
import Servant.API (type (:>))
import Servant.API.Experimental.Auth (AuthProtect)
import Servant.API.ResponseHeaders (getResponse)
import Servant.Client
  ( BaseUrl (..),
    ClientEnv,
    ClientError,
    ClientM,
    Scheme (..),
    mkClientEnv,
    parseBaseUrl,
    runClientM,
  )
import Servant.Client.Core
  ( AuthClientData,
    AuthenticatedRequest,
    addHeader,
    mkAuthenticatedRequest,
  )
import Servant.Client.Core.HasClient (AsClientT, HasClient (..))
import Servant.Client.Generic (genericClient)
import Shomei.Account.Admin.Api qualified as AdminAccount
import Shomei.Account.Api qualified as Account
import Shomei.Account.Dto (SignupRequest, SignupResponse)
import Shomei.Account.User.Dto (AdminStatusFilter, AdminUserResponse, AdminUsersPage, UserPageCursor, UserResponse)
import Shomei.Authorization.Api qualified as Authorization
import Shomei.Id (PasskeyId, SessionId, UserId)
import Shomei.Mfa.Api qualified as Mfa
import Shomei.Mfa.Dto (MfaCompleteRequest)
import Shomei.OAuth.Api qualified as OAuthApi
import Shomei.Passkey.Api qualified as Passkey
import Shomei.Passkey.Dto
  ( PasskeyLoginBeginResponse,
    PasskeyLoginCompleteRequest,
    PasskeyRegisterBeginResponse,
    PasskeyRegisterCompleteRequest,
    PasskeyResponse,
  )
import Shomei.Prelude
import Shomei.Servant.Api (ApplicationApi, ShomeiRoutes)
import Shomei.Servant.Api qualified as Api
import Shomei.Servant.Auth (Authenticated)
import Shomei.Servant.Authz (RequireAdmin, RequirePermission, RequireRole, RequireScope)
import Shomei.Servant.OAuth (TokenResponse (..))
import Shomei.Servant.PreHandler (CsrfProtected, PreHandlerResponses, RateLimited)
import Shomei.Session.Admin.Api qualified as AdminSession
import Shomei.Session.Api qualified as Session
import Shomei.Session.Dto (LoginRequest, LoginResponse, RefreshRequest, SessionResponse, TokenPairResponse)
import Web.FormUrlEncoded (toForm)

-- | A Bearer access token (the signed JWT the server returned from @\/v1\/auth\/login@).
newtype Token = Token {unToken :: Text}
  deriving stock (Eq, Show)

-- | Tell @servant-client@ what credential the @shomei-jwt@ scheme needs client-side.
type instance AuthClientData (AuthProtect "shomei-jwt") = Token

-- | Client-side, Shōmei's authorization combinators are indistinguishable from plain
-- authentication: the caller still presents one Bearer token, and whether the server then finds
-- the required role or scope in it is the server's business (a 403 if not). So both delegate to
-- the @AuthProtect "shomei-jwt"@ instance, and a @RequireRole \"admin\" :> …@ route's client
-- function takes exactly the same @'bearer' tok@ argument an 'Authenticated' one does.
--
-- Without these, 'genericClient' cannot derive 'ShomeiClient' at all — @ShomeiAPI@ now carries a
-- 'RequireRole' on its audit route. They are orphans for the same reason the 'AuthClientData'
-- instance above is: the class belongs to servant, the combinator to @shomei-servant@.
instance (HasClient m api) => HasClient m (RequireRole r :> api) where
  type Client m (RequireRole r :> api) = Client m (AuthProtect "shomei-jwt" :> api)
  clientWithRoute pm _ = clientWithRoute pm (Proxy :: Proxy (AuthProtect "shomei-jwt" :> api))
  hoistClientMonad pm _ = hoistClientMonad pm (Proxy :: Proxy (AuthProtect "shomei-jwt" :> api))

instance (HasClient m api) => HasClient m (RequireScope s :> api) where
  type Client m (RequireScope s :> api) = Client m (AuthProtect "shomei-jwt" :> api)
  clientWithRoute pm _ = clientWithRoute pm (Proxy :: Proxy (AuthProtect "shomei-jwt" :> api))
  hoistClientMonad pm _ = hoistClientMonad pm (Proxy :: Proxy (AuthProtect "shomei-jwt" :> api))

instance (HasClient m api) => HasClient m (RequirePermission p :> api) where
  type Client m (RequirePermission p :> api) = Client m (AuthProtect "shomei-jwt" :> api)
  clientWithRoute pm _ = clientWithRoute pm (Proxy :: Proxy (AuthProtect "shomei-jwt" :> api))
  hoistClientMonad pm _ = hoistClientMonad pm (Proxy :: Proxy (AuthProtect "shomei-jwt" :> api))

instance (HasClient m api) => HasClient m (Authenticated :> api) where
  type Client m (Authenticated :> api) = Client m (AuthProtect "shomei-jwt" :> api)
  clientWithRoute pm _ = clientWithRoute pm (Proxy :: Proxy (AuthProtect "shomei-jwt" :> api))
  hoistClientMonad pm _ = hoistClientMonad pm (Proxy :: Proxy (AuthProtect "shomei-jwt" :> api))

instance (HasClient m api) => HasClient m (RequireAdmin :> api) where
  type Client m (RequireAdmin :> api) = Client m (AuthProtect "shomei-jwt" :> api)
  clientWithRoute pm _ = clientWithRoute pm (Proxy :: Proxy (AuthProtect "shomei-jwt" :> api))
  hoistClientMonad pm _ = hoistClientMonad pm (Proxy :: Proxy (AuthProtect "shomei-jwt" :> api))

instance (HasClient m api) => HasClient m (PreHandlerResponses responses :> api) where
  type Client m (PreHandlerResponses responses :> api) = Client m api
  clientWithRoute pm _ = clientWithRoute pm (Proxy :: Proxy api)
  hoistClientMonad pm _ = hoistClientMonad pm (Proxy :: Proxy api)

instance (HasClient m api) => HasClient m (CsrfProtected :> api) where
  type Client m (CsrfProtected :> api) = Client m api
  clientWithRoute pm _ = clientWithRoute pm (Proxy :: Proxy api)
  hoistClientMonad pm _ = hoistClientMonad pm (Proxy :: Proxy api)

instance (HasClient m api) => HasClient m (RateLimited :> api) where
  type Client m (RateLimited :> api) = Client m api
  clientWithRoute pm _ = clientWithRoute pm (Proxy :: Proxy api)
  hoistClientMonad pm _ = hoistClientMonad pm (Proxy :: Proxy api)

-- | Build an 'AuthenticatedRequest' that adds @Authorization: Bearer <jwt>@.
bearer :: Token -> AuthenticatedRequest (AuthProtect "shomei-jwt")
bearer tok =
  mkAuthenticatedRequest tok \(Token jwt) req ->
    addHeader "Authorization" ("Bearer " <> jwt) req

-- | The client for the whole served tree: the @v1@ field carries the application client, and
-- @jwks@\/@health@\/@ready@ reach the unversioned root endpoints.
type ShomeiRoutesClient = ShomeiRoutes (AsClientT ClientM)

shomeiRoutesClient :: ShomeiRoutesClient
shomeiRoutesClient = genericClient

-- | The record of client functions, derived from 'ShomeiAPI' (fields match the API).
type ShomeiClient = ApplicationApi (AsClientT ClientM)

-- | The application client, reached through the @v1@ field of the root client. Each function
-- it contains already carries the @\/v1@ segment, because the segment lives in the route type
-- — so callers keep passing a bare base URL to 'shomeiClientEnv'.
shomeiClient :: ShomeiClient
shomeiClient = Api.application shomeiRoutesClient

accountClient = Api.account shomeiClient

sessionClient = Api.session shomeiClient

passkeyClient = Api.passkey shomeiClient

mfaClient = Api.mfa shomeiClient

adminAccountClient = Api.adminAccount shomeiClient

adminSessionClient = Api.adminSession shomeiClient

authorizationClient = Api.authorization shomeiClient

-- | Build a 'ClientEnv' from a base URL string, e.g. @"http:\/\/localhost:8080"@.
shomeiClientEnv :: String -> IO ClientEnv
shomeiClientEnv url = do
  base <- parseBaseUrl url
  mgr <- case baseUrlScheme base of
    Https -> HTTP.newManager TLS.tlsManagerSettings
    Http -> HTTP.newManager HTTP.defaultManagerSettings
  pure (mkClientEnv mgr base)

-- | Run a 'ClientM' action against a 'ClientEnv'.
runClient :: ClientEnv -> ClientM a -> IO (Either ClientError a)
runClient env act = runClientM act env

-- Field functions are reached via qualified selectors (@API.signup shomeiClient@) rather
-- than @OverloadedRecordDot@: a NamedRoutes field type is the @(:-)@ type-family
-- application, which record-dot's @HasField@ cannot see through, but selector application
-- reduces it to the concrete client function.

signup :: ClientEnv -> SignupRequest -> IO (Either ClientError SignupResponse)
signup env body = runClient env (getResponse <$> Account.signup accountClient body)

-- | Log in with email + password.
--
-- IMPORTANT: the returned 'LoginResponse' is a tagged sum (EP-4). On @status:"complete"@ it
-- carries @user@ + @token@ ('LoginCompleteResponse'). On @status:"mfa_required"@ it carries a
-- @ceremonyId@ and WebAuthn @options@ ('LoginMfaRequiredResponse'): the account has a passkey,
-- so the caller must run @navigator.credentials.get()@ in the browser and call 'mfaComplete'
-- with the @ceremonyId@ and the browser's @assertion@ JSON to obtain tokens. The Haskell
-- signature is unchanged; only the meaning of 'LoginResponse' widened.
login :: ClientEnv -> LoginRequest -> IO (Either ClientError LoginResponse)
login env body = runClient env (getResponse <$> Session.login sessionClient body)

-- | Rotate a refresh token. This is a bearer-mode client, so the token travels in the body and
-- the cookie/origin headers the route also accepts are left unset.
refresh :: ClientEnv -> RefreshRequest -> IO (Either ClientError TokenPairResponse)
refresh env body = runClient env (getResponse <$> Session.refresh sessionClient Nothing Nothing Nothing body)

-- | Authenticated routes take the 'AuthenticatedRequest' built from the Bearer token.
logout :: ClientEnv -> Token -> IO (Either ClientError ())
logout env tok = fmap (fmap (const ())) (runClient env (Session.logout sessionClient (bearer tok)))

me :: ClientEnv -> Token -> IO (Either ClientError UserResponse)
me env tok = runClient env (Account.me accountClient (bearer tok))

session :: ClientEnv -> Token -> IO (Either ClientError SessionResponse)
session env tok = runClient env (Session.currentSession sessionClient (bearer tok))

-- Passkey enrollment / management. These are 'Authenticated' (Bearer) routes, so each takes a
-- 'Token' and attaches it with 'bearer', exactly like 'me'/'session'/'logout'.

-- | Begin enrolling a passkey (authenticated). Returns the ceremony id and the WebAuthn
-- creation @options@ the browser feeds to @navigator.credentials.create()@.
passkeyRegisterBegin ::
  ClientEnv -> Token -> IO (Either ClientError PasskeyRegisterBeginResponse)
passkeyRegisterBegin env tok =
  runClient env (Passkey.registerBegin passkeyClient (bearer tok))

-- | Complete passkey enrollment (authenticated): submit the browser's credential JSON and an
-- optional label. Returns the stored passkey.
passkeyRegisterComplete ::
  ClientEnv -> Token -> PasskeyRegisterCompleteRequest -> IO (Either ClientError PasskeyResponse)
passkeyRegisterComplete env tok body =
  runClient env (Passkey.registerComplete passkeyClient (bearer tok) body)

-- | List the caller's enrolled passkeys (authenticated). Never includes public-key bytes.
listPasskeys ::
  ClientEnv -> Token -> IO (Either ClientError [PasskeyResponse])
listPasskeys env tok =
  runClient env (Passkey.list passkeyClient (bearer tok))

-- | Remove one of the caller's passkeys by id (authenticated). 404 if it is not theirs. The
-- 'PasskeyId' can be parsed from a 'PasskeyResponse' \'s @passkeyId@ 'Text' with
-- 'Shomei.Id.parseId'.
deletePasskey ::
  ClientEnv -> Token -> PasskeyId -> IO (Either ClientError ())
deletePasskey env tok pid =
  fmap (fmap (const ())) (runClient env (Passkey.remove passkeyClient (bearer tok) pid))

-- Passkey login / MFA. These are unauthenticated (the caller does not yet hold a token), so
-- each takes only its request body and mirrors 'login'/'refresh'.

-- | Complete an MFA step-up: after 'login' returned @status:"mfa_required"@, the browser runs
-- @navigator.credentials.get()@ and this submits the @ceremonyId@ + the @assertion@ JSON.
-- Returns the access/refresh token pair.
mfaComplete ::
  ClientEnv -> MfaCompleteRequest -> IO (Either ClientError TokenPairResponse)
mfaComplete env body = runClient env (getResponse <$> Mfa.complete mfaClient body)

-- | Begin a passwordless passkey login. Returns the ceremony id and the WebAuthn @options@
-- the browser feeds to @navigator.credentials.get()@ (the discoverable-credential picker
-- chooses the account).
passkeyLoginBegin ::
  ClientEnv -> IO (Either ClientError PasskeyLoginBeginResponse)
passkeyLoginBegin env = runClient env (Passkey.loginBegin passkeyClient)

-- | Complete a passwordless passkey login: submit the @ceremonyId@ + the browser's
-- @assertion@ JSON. The passkey IS the strong factor, so this returns a token pair directly
-- (never an MFA challenge).
passkeyLoginComplete ::
  ClientEnv -> PasskeyLoginCompleteRequest -> IO (Either ClientError TokenPairResponse)
passkeyLoginComplete env body = runClient env (getResponse <$> Passkey.loginComplete passkeyClient body)

-- Administration (EP-2). Every one of these is an 'Authenticated' route whose handler demands
-- the @admin@ role or the @shomei:admin@ scope; a token without either gets a @403@.
--
-- The mutations answer @204@\/@202@ with no body, so their wrappers discard 'NoContent' and
-- return @()@ — exactly as 'logout' and 'deletePasskey' do.

-- | One keyset page of users. @status@ filters (@"active"@ | @"suspended"@ | @"deleted"@),
-- @limit@ defaults to 50 and is clamped to 1000, and @before@ takes the previous page's
-- @nextCursor@.
adminListUsers ::
  ClientEnv -> Token -> Maybe AdminStatusFilter -> Maybe Int -> Maybe UserPageCursor -> IO (Either ClientError AdminUsersPage)
adminListUsers env tok status limit before =
  runClient env (AdminAccount.listUsers adminAccountClient (bearer tok) status limit before)

-- | One user plus the roles actually granted to them in the store.
adminGetUser :: ClientEnv -> Token -> UserId -> IO (Either ClientError AdminUserResponse)
adminGetUser env tok uid = runClient env (AdminAccount.getUser adminAccountClient (bearer tok) uid)

-- | Suspend an active user and revoke their sessions. @409@ if they are not active; @403@ if
-- the caller is the target.
adminSuspendUser :: ClientEnv -> Token -> UserId -> IO (Either ClientError ())
adminSuspendUser env tok uid =
  discard (runClient env (AdminAccount.suspendUser adminAccountClient (bearer tok) uid))

-- | Return a suspended user to service. @409@ if they are not suspended.
adminReinstateUser :: ClientEnv -> Token -> UserId -> IO (Either ClientError ())
adminReinstateUser env tok uid =
  discard (runClient env (AdminAccount.reinstateUser adminAccountClient (bearer tok) uid))

-- | Soft-delete a user (status becomes @deleted@) and revoke their sessions. The row survives.
adminDeleteUser :: ClientEnv -> Token -> UserId -> IO (Either ClientError ())
adminDeleteUser env tok uid =
  discard (runClient env (AdminAccount.deleteUser adminAccountClient (bearer tok) uid))

-- | Every session of a user, newest first, in every status.
adminListSessions :: ClientEnv -> Token -> UserId -> IO (Either ClientError [SessionResponse])
adminListSessions env tok uid = runClient env (AdminSession.listSessions adminSessionClient (bearer tok) uid)

adminRevokeSessions :: ClientEnv -> Token -> UserId -> IO (Either ClientError ())
adminRevokeSessions env tok uid =
  discard (runClient env (AdminSession.revokeSessions adminSessionClient (bearer tok) uid))

adminRevokeSession :: ClientEnv -> Token -> SessionId -> IO (Either ClientError ())
adminRevokeSession env tok sid =
  discard (runClient env (AdminSession.revokeSession adminSessionClient (bearer tok) sid))

-- | Trigger the ordinary password-reset flow for a user named by id. @409@ if they have no email.
adminPasswordReset :: ClientEnv -> Token -> UserId -> IO (Either ClientError ())
adminPasswordReset env tok uid =
  discard (runClient env (AdminAccount.passwordReset adminAccountClient (bearer tok) uid))

-- | Fetch a machine token from @POST \/oauth\/token@ with the OAuth2 @client_credentials@ grant
-- (EP-4), authenticating with @client_secret_basic@.
--
-- An empty @scopes@ list omits the @scope@ parameter entirely, which grants every scope the
-- service account is allowed. Passing scopes narrows the token to that subset; a scope outside
-- the account's allow-list is rejected with @invalid_scope@.
--
-- The failure channel is 'ClientError' as everywhere else in this module, but note that the
-- endpoint's error /body/ is an RFC 6749 object (@{"error":…,"error_description":…}@), not the
-- problem document the rest of the API returns — @\/oauth\/*@ speaks the OAuth2 wire protocol.
-- A caller that wants the code inspects the 'ClientError''s response body.
--
-- Get a @client_id@ and secret with @shomei-admin service-accounts create@.
oauthToken :: ClientEnv -> Text -> Text -> [Text] -> IO (Either ClientError TokenResponse)
oauthToken env clientId clientSecret scopes =
  fmap getResponse <$> runClient env (OAuthApi.token (Api.oauth shomeiRoutesClient) (Just basicHeader) form)
  where
    basicHeader =
      "Basic " <> extractBase64 (B64.encodeBase64 (TE.encodeUtf8 (clientId <> ":" <> clientSecret)))
    -- An absent `scope` is a server-defined default (RFC 6749 §3.3); an empty one is a malformed
    -- request. So a caller passing no scopes must send no parameter, not `scope=`.
    form =
      toForm
        ( ("grant_type" :: Text, "client_credentials" :: Text)
            : [("scope", Text.unwords scopes) | not (null scopes)]
        )

-- | Grant a role. Idempotent: re-granting a held role still succeeds. @422@ if the role is not
-- in the registry.
adminGrantRole :: ClientEnv -> Token -> UserId -> Text -> IO (Either ClientError ())
adminGrantRole env tok uid role =
  discard (runClient env (Authorization.grantRole authorizationClient (bearer tok) uid role))

-- | Revoke a role. @404@ if the user did not hold it.
adminRevokeRole :: ClientEnv -> Token -> UserId -> Text -> IO (Either ClientError ())
adminRevokeRole env tok uid role =
  discard (runClient env (Authorization.revokeRole authorizationClient (bearer tok) uid role))

-- | Throw away a 'NoContent' body, keeping the error channel.
discard :: (Functor f) => f (Either e a) -> f (Either e ())
discard = fmap (fmap (const ()))
