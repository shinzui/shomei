-- The @AuthClientData@ instance below is an unavoidable orphan (both the type family and
-- @AuthProtect "shomei-jwt"@ belong to servant; 'Token' belongs here) — the standard
-- servant generalized-auth client pattern. Silence the orphan warning for this module.
{-# OPTIONS_GHC -Wno-orphans #-}

{- | A typed Haskell client for the standalone Shōmei auth service.

The client functions are not hand-written: they are /derived/ from the exact same
'Shomei.Servant.API.ShomeiAPI' Servant type the server serves, via @servant-client@'s
'genericClient'. So the client and server can never disagree about the wire format.
The 'Authenticated' (@AuthProtect "shomei-jwt"@) routes take a 'Token' (the Bearer JWT),
attached through @servant-client@'s generalized-authentication support
('AuthClientData' + 'mkAuthenticatedRequest').
-}
module Shomei.Client (
    Token (..),
    ShomeiClient,
    shomeiClient,
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
) where

import Shomei.Prelude

import "http-client" Network.HTTP.Client qualified as HTTP
import "http-client-tls" Network.HTTP.Client.TLS qualified as TLS

import "servant" Servant.API.Experimental.Auth (AuthProtect)
import "servant-client" Servant.Client (
    BaseUrl (..),
    ClientEnv,
    ClientError,
    ClientM,
    Scheme (..),
    mkClientEnv,
    parseBaseUrl,
    runClientM,
 )
import "servant-client-core" Servant.Client.Core (
    AuthClientData,
    AuthenticatedRequest,
    addHeader,
    mkAuthenticatedRequest,
 )
import "servant-client-core" Servant.Client.Core.HasClient (AsClientT)
import "servant-client-core" Servant.Client.Generic (genericClient)

import Shomei.Servant.API (ShomeiAPI)
import Shomei.Servant.API qualified as API
import Shomei.Servant.DTO (
    LoginRequest,
    LoginResponse,
    RefreshRequest,
    SessionResponse,
    SignupRequest,
    SignupResponse,
    TokenPairResponse,
    UserResponse,
 )

-- | A Bearer access token (the signed JWT the server returned from @\/auth\/login@).
newtype Token = Token {unToken :: Text}
    deriving stock (Eq, Show)

-- | Tell @servant-client@ what credential the @shomei-jwt@ scheme needs client-side.
type instance AuthClientData (AuthProtect "shomei-jwt") = Token

-- | Build an 'AuthenticatedRequest' that adds @Authorization: Bearer <jwt>@.
bearer :: Token -> AuthenticatedRequest (AuthProtect "shomei-jwt")
bearer tok =
    mkAuthenticatedRequest tok \(Token jwt) req ->
        addHeader "Authorization" ("Bearer " <> jwt) req

-- | The record of client functions, derived from 'ShomeiAPI' (fields match the API).
type ShomeiClient = ShomeiAPI (AsClientT ClientM)

shomeiClient :: ShomeiClient
shomeiClient = genericClient

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
signup env body = runClient env (API.signup shomeiClient body)

login :: ClientEnv -> LoginRequest -> IO (Either ClientError LoginResponse)
login env body = runClient env (API.login shomeiClient body)

refresh :: ClientEnv -> RefreshRequest -> IO (Either ClientError TokenPairResponse)
refresh env body = runClient env (API.refresh shomeiClient body)

-- | Authenticated routes take the 'AuthenticatedRequest' built from the Bearer token.
logout :: ClientEnv -> Token -> IO (Either ClientError ())
logout env tok = fmap (fmap (const ())) (runClient env (API.logout shomeiClient (bearer tok)))

me :: ClientEnv -> Token -> IO (Either ClientError UserResponse)
me env tok = runClient env (API.me shomeiClient (bearer tok))

session :: ClientEnv -> Token -> IO (Either ClientError SessionResponse)
session env tok = runClient env (API.session shomeiClient (bearer tok))
