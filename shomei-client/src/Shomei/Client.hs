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
-- 'Shomei.Servant.API.ShomeiAPI' Servant type the server serves, via @servant-client@'s
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
  )
where

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
import Shomei.Id (PasskeyId)
import Shomei.Prelude
import Shomei.Servant.API (ShomeiAPI, ShomeiRoutes)
import Shomei.Servant.API qualified as API
import Shomei.Servant.Authz (RequireRole, RequireScope)
import Shomei.Servant.DTO
  ( LoginRequest,
    LoginResponse,
    MfaCompleteRequest,
    PasskeyLoginBeginResponse,
    PasskeyLoginCompleteRequest,
    PasskeyRegisterBeginResponse,
    PasskeyRegisterCompleteRequest,
    PasskeyResponse,
    RefreshRequest,
    SessionResponse,
    SignupRequest,
    SignupResponse,
    TokenPairResponse,
    UserResponse,
  )

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
type ShomeiClient = ShomeiAPI (AsClientT ClientM)

-- | The application client, reached through the @v1@ field of the root client. Each function
-- it contains already carries the @\/v1@ segment, because the segment lives in the route type
-- — so callers keep passing a bare base URL to 'shomeiClientEnv'.
shomeiClient :: ShomeiClient
shomeiClient = API.v1 shomeiRoutesClient

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
signup env body = runClient env (getResponse <$> API.signup shomeiClient body)

-- | Log in with email + password.
--
-- IMPORTANT: the returned 'LoginResponse' is a tagged sum (EP-4). On @status:"complete"@ it
-- carries @user@ + @token@ ('LoginCompleteResponse'). On @status:"mfa_required"@ it carries a
-- @ceremonyId@ and WebAuthn @options@ ('LoginMfaRequiredResponse'): the account has a passkey,
-- so the caller must run @navigator.credentials.get()@ in the browser and call 'mfaComplete'
-- with the @ceremonyId@ and the browser's @assertion@ JSON to obtain tokens. The Haskell
-- signature is unchanged; only the meaning of 'LoginResponse' widened.
login :: ClientEnv -> LoginRequest -> IO (Either ClientError LoginResponse)
login env body = runClient env (getResponse <$> API.login shomeiClient body)

-- | Rotate a refresh token. This is a bearer-mode client, so the token travels in the body and
-- the cookie/origin headers the route also accepts are left unset.
refresh :: ClientEnv -> RefreshRequest -> IO (Either ClientError TokenPairResponse)
refresh env body = runClient env (getResponse <$> API.refresh shomeiClient Nothing Nothing Nothing body)

-- | Authenticated routes take the 'AuthenticatedRequest' built from the Bearer token.
logout :: ClientEnv -> Token -> IO (Either ClientError ())
logout env tok = fmap (fmap (const ())) (runClient env (API.logout shomeiClient (bearer tok)))

me :: ClientEnv -> Token -> IO (Either ClientError UserResponse)
me env tok = runClient env (API.me shomeiClient (bearer tok))

session :: ClientEnv -> Token -> IO (Either ClientError SessionResponse)
session env tok = runClient env (API.session shomeiClient (bearer tok))

-- Passkey enrollment / management. These are 'Authenticated' (Bearer) routes, so each takes a
-- 'Token' and attaches it with 'bearer', exactly like 'me'/'session'/'logout'.

-- | Begin enrolling a passkey (authenticated). Returns the ceremony id and the WebAuthn
-- creation @options@ the browser feeds to @navigator.credentials.create()@.
passkeyRegisterBegin ::
  ClientEnv -> Token -> IO (Either ClientError PasskeyRegisterBeginResponse)
passkeyRegisterBegin env tok =
  runClient env (API.passkeyRegisterBegin shomeiClient (bearer tok))

-- | Complete passkey enrollment (authenticated): submit the browser's credential JSON and an
-- optional label. Returns the stored passkey.
passkeyRegisterComplete ::
  ClientEnv -> Token -> PasskeyRegisterCompleteRequest -> IO (Either ClientError PasskeyResponse)
passkeyRegisterComplete env tok body =
  runClient env (API.passkeyRegisterComplete shomeiClient (bearer tok) body)

-- | List the caller's enrolled passkeys (authenticated). Never includes public-key bytes.
listPasskeys ::
  ClientEnv -> Token -> IO (Either ClientError [PasskeyResponse])
listPasskeys env tok =
  runClient env (API.passkeyList shomeiClient (bearer tok))

-- | Remove one of the caller's passkeys by id (authenticated). 404 if it is not theirs. The
-- 'PasskeyId' can be parsed from a 'PasskeyResponse' \'s @passkeyId@ 'Text' with
-- 'Shomei.Id.parseId'.
deletePasskey ::
  ClientEnv -> Token -> PasskeyId -> IO (Either ClientError ())
deletePasskey env tok pid =
  fmap (fmap (const ())) (runClient env (API.passkeyDelete shomeiClient (bearer tok) pid))

-- Passkey login / MFA. These are unauthenticated (the caller does not yet hold a token), so
-- each takes only its request body and mirrors 'login'/'refresh'.

-- | Complete an MFA step-up: after 'login' returned @status:"mfa_required"@, the browser runs
-- @navigator.credentials.get()@ and this submits the @ceremonyId@ + the @assertion@ JSON.
-- Returns the access/refresh token pair.
mfaComplete ::
  ClientEnv -> MfaCompleteRequest -> IO (Either ClientError TokenPairResponse)
mfaComplete env body = runClient env (getResponse <$> API.mfaComplete shomeiClient body)

-- | Begin a passwordless passkey login. Returns the ceremony id and the WebAuthn @options@
-- the browser feeds to @navigator.credentials.get()@ (the discoverable-credential picker
-- chooses the account).
passkeyLoginBegin ::
  ClientEnv -> IO (Either ClientError PasskeyLoginBeginResponse)
passkeyLoginBegin env = runClient env (API.passkeyLoginBegin shomeiClient)

-- | Complete a passwordless passkey login: submit the @ceremonyId@ + the browser's
-- @assertion@ JSON. The passkey IS the strong factor, so this returns a token pair directly
-- (never an MFA challenge).
passkeyLoginComplete ::
  ClientEnv -> PasskeyLoginCompleteRequest -> IO (Either ClientError TokenPairResponse)
passkeyLoginComplete env body = runClient env (getResponse <$> API.passkeyLoginComplete shomeiClient body)
