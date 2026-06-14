-- The @AuthServerData@ instance is an unavoidable orphan (the family and @AuthProtect@
-- belong to servant; the principal type is the core's 'AuthClaims') — the standard
-- generalized-auth pattern. Silence the orphan warning for this module.
{-# OPTIONS_GHC -Wno-orphans #-}

{- | The downstream service of the microservice deployment model: it verifies Shōmei's
JWTs /locally/, never calling the auth service per request.

On startup it is given the auth service's JWKS URL; a 'JwksCache' fetches the public
'JWKSet' lazily and refetches only once its TTL expires (default 15 min). Each request's
Bearer token is verified offline with @shomei-jwt@'s 'verifyToken' against the cached
keys. This service deliberately does not depend on @shomei-postgres@ and has no database.
-}
module Downstream.Service (
    JwksCache,
    newJwksCache,
    downstreamApplication,
    Project (..),
    DownstreamAPI,
) where

import Shomei.Prelude hiding (Context)

import Data.Time (NominalDiffTime, diffUTCTime)
import Control.Concurrent.MVar (MVar, modifyMVar, newMVar)

import Data.Aeson (eitherDecode)
import Network.HTTP.Client qualified as HTTP
import Crypto.JOSE.JWK (JWKSet)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text

import Network.Wai (Application, Request, requestHeaders)

import Servant.API.Experimental.Auth (AuthProtect)
import Servant (
    Context (EmptyContext, (:.)),
    Get,
    Handler,
    JSON,
    err401,
    errBody,
    serveWithContext,
    throwError,
    type (:>),
 )
import Servant.Server.Experimental.Auth (
    AuthHandler,
    AuthServerData,
    mkAuthHandler,
 )

import Shomei.Config (ShomeiConfig)
import Shomei.Domain.Claims (AuthClaims)
import Shomei.Jwt.Verify (verifyToken)

-- | A TTL-bounded cache of the auth service's public 'JWKSet'.
data JwksCache = JwksCache
    { cacheMgr :: !HTTP.Manager
    , cacheUrl :: !String
    , cacheTtl :: !NominalDiffTime
    , cacheState :: !(MVar (Maybe (JWKSet, UTCTime)))
    }

-- | Build a cache against the auth service's JWKS URL with a refetch TTL (seconds).
newJwksCache :: HTTP.Manager -> String -> NominalDiffTime -> IO JwksCache
newJwksCache mgr url ttl = do
    st <- newMVar Nothing
    pure JwksCache{cacheMgr = mgr, cacheUrl = url, cacheTtl = ttl, cacheState = st}

{- | The cached 'JWKSet', refetching only if older than the TTL. This is the ONLY place
the downstream service contacts the auth service — at most once per TTL window, never per
request.
-}
currentJwks :: JwksCache -> IO JWKSet
currentJwks cache = do
    now <- getCurrentTime
    modifyMVar cache.cacheState \st ->
        case st of
            Just (jwks, fetchedAt) | diffUTCTime now fetchedAt < cache.cacheTtl -> pure (st, jwks)
            _ -> do
                jwks <- fetchJwks cache.cacheMgr cache.cacheUrl
                pure (Just (jwks, now), jwks)

fetchJwks :: HTTP.Manager -> String -> IO JWKSet
fetchJwks mgr url = do
    req <- HTTP.parseRequest url
    resp <- HTTP.httpLbs req mgr
    case eitherDecode (HTTP.responseBody resp) of
        Right jwks -> pure jwks
        Left err -> ioError (userError ("JWKS parse failed: " <> err))

-- | A trivial business resource this downstream service owns.
data Project = Project
    { projectId :: !Text
    , projectName :: !Text
    }
    deriving stock (Generic)
    deriving anyclass (ToJSON)

{- | This service's own protected API. The combinator is a LOCAL @AuthProtect@ whose
'AuthHandler' verifies the JWT offline using the fetched JWKS; there is no Shōmei
dependency beyond the verifier and the config/claims types.
-}
type DownstreamAPI =
    AuthProtect "downstream-jwt" :> "projects" :> Get '[JSON] [Project]

type instance AuthServerData (AuthProtect "downstream-jwt") = AuthClaims

{- | The downstream WAI app: serve @\/projects@ behind the local-verification guard, using
the supplied JWKS cache and the 'ShomeiConfig' carrying the issuer/audience the auth
service signs with (so local verification matches).
-}
downstreamApplication :: JwksCache -> ShomeiConfig -> Application
downstreamApplication cache cfg =
    serveWithContext (Proxy @DownstreamAPI) (localAuthHandler cache cfg :. EmptyContext) projectsHandler

{- | The local guard: pull @Authorization: Bearer <jwt>@ and verify with the cached JWKS —
no call back to the auth service.
-}
localAuthHandler :: JwksCache -> ShomeiConfig -> AuthHandler Request AuthClaims
localAuthHandler cache cfg = mkAuthHandler \req -> do
    jwt <- case lookup "Authorization" (requestHeaders req) of
        Just v | Just b <- Text.stripPrefix "Bearer " (Text.decodeUtf8 v) -> pure b
        _ -> throwError err401{errBody = "missing bearer token"}
    jwks <- liftIO (currentJwks cache)
    res <- liftIO (verifyToken jwks cfg jwt)
    case res of
        Right claims -> pure claims
        Left _ -> throwError err401{errBody = "invalid token (local verification failed)"}

projectsHandler :: AuthClaims -> Handler [Project]
projectsHandler _claims =
    pure [Project{projectId = "proj_ms_1", projectName = "Downstream-verified Project"}]
