{-# LANGUAGE EmptyDataDecls #-}
{-# LANGUAGE StandaloneKindSignatures #-}
{-# LANGUAGE UndecidableInstances #-}

-- | Role/scope authorization as /enforcing/ Servant combinators.
--
-- Writing @RequireRole "admin" :> ...@ in a route type authenticates the caller and rejects a
-- principal that lacks the role with @403@ — with no handler code at all. The handler still
-- receives the 'AuthUser', exactly as it would under 'Authenticated'.
--
-- __These combinators replace 'Authenticated', they do not accompany it.__ A route carries
-- @RequireRole "admin" :> sub@ /instead of/ @Authenticated :> sub@: the instance below runs the
-- very same 'AuthHandler' from the Servant 'Servant.Context' that 'Authenticated' would, so the
-- token extraction, the CSRF gate, and the verifier are shared. Writing both would authenticate
-- twice and give the handler two 'AuthUser' arguments.
--
-- Why a combinator rather than a handler guard: a guard the route author forgets to call ships
-- a silently unprotected route, and the route type says otherwise. A combinator whose /absence/
-- of enforcement is impossible is the point. (These types were phantoms with no 'HasServer'
-- instance until MasterPlan 7 EP-1; a route that carried one enforced nothing.)
--
-- The guard functions 'requireRole' / 'requireScope' remain exported for composite conditions
-- a single type-level symbol cannot express — "role @admin@ OR scope @shomei:admin@" — which
-- the admin HTTP API needs.
--
-- These are Shōmei's built-in, flat, tier-1 authorization primitives: they read static claims
-- from an already-minted JWT. They are deliberately not resource-scoped
-- (@RequireRole \"editor\"@ cannot mean "editor /of this project/") and cannot revoke access
-- before the token expires. See @docs\/user\/security.md@ for where that boundary lies.
module Shomei.Servant.Authz
  ( RequireRole,
    RequireScope,
    requireRole,
    requireScope,
  )
where

import Data.Aeson qualified as Aeson
import Data.Kind (Type)
import Data.Set qualified as Set
import Data.Text qualified as Text
import GHC.TypeLits (KnownSymbol, Symbol, symbolVal)
import Network.Wai (Request)
import Servant
  ( Context,
    Handler,
    Proxy (..),
    ServerError (..),
    err403,
    errBody,
    throwError,
    type (:>),
  )
import Servant.Server.Experimental.Auth (AuthHandler, unAuthHandler)
import Servant.Server.Internal
  ( DelayedIO,
    HasContextEntry,
    HasServer (..),
    addAuthCheck,
    delayedFailFatal,
    getContextEntry,
    runHandler,
    withRequest,
  )
import Shomei.Domain.Claims (Role (..), Scope (..))
-- 'Shomei.Prelude' re-exports lens, whose 'Context' collides with servant's.
import Shomei.Prelude hiding (Context)
import Shomei.Servant.Auth (AuthUser (..))

-- | Enforcing combinator: the route demands the named role. (The type parameter is named @r@,
-- not @role@: under GHC2024 @RoleAnnotations@ is on, so @role@ is a context-sensitive keyword
-- and cannot be a type-variable binder.)
type RequireRole :: Symbol -> Type
data RequireRole r

-- | Enforcing combinator: the route demands the named scope.
type RequireScope :: Symbol -> Type
data RequireScope s

-- | Guard: fail with @403@ unless the principal carries the role. Use this only for a condition
-- the type-level combinator cannot express; a plain "this route needs role X" belongs in the
-- route type, where it cannot be forgotten.
requireRole :: Role -> AuthUser -> Handler ()
requireRole role u
  | role `Set.member` u.authRoles = pure ()
  | otherwise = throwError (forbidden "missing_role" "missing required role")

-- | Guard: fail with @403@ unless the principal carries the scope. See 'requireRole'.
requireScope :: Scope -> AuthUser -> Handler ()
requireScope scope u
  | scope `Set.member` u.authScopes = pure ()
  | otherwise = throwError (forbidden "missing_scope" "missing required scope")

-- | A @403@ carrying the same @{"error":…,"message":…}@ JSON body shape that
-- 'Shomei.Servant.Error.authErrorToServerError' produces, so a client sees one error format
-- across the API. (The universal problem-details envelope of MasterPlan 7 EP-3 will sweep this
-- along with every other error site; that plan owns the change.)
forbidden :: Text -> Text -> ServerError
forbidden code msg =
  err403
    { errBody =
        Aeson.encode
          (Aeson.object ["error" Aeson..= code, "message" Aeson..= msg]),
      errHeaders = [("Content-Type", "application/json")]
    }

-- | Authenticate the request with the context-registered 'AuthHandler' — the same one
-- 'Shomei.Servant.Auth.Authenticated' uses — and hand the 'AuthUser' to @check@. A failure from
-- the auth handler itself (missing token, invalid token, CSRF rejection) propagates unchanged,
-- so an unauthenticated request still gets its @401@ rather than a @403@.
authorizedCheck ::
  (HasContextEntry ctx (AuthHandler Request AuthUser)) =>
  Context ctx ->
  (AuthUser -> Either ServerError AuthUser) ->
  Request ->
  DelayedIO AuthUser
authorizedCheck ctx check req = do
  outcome <- liftIO (runHandler (unAuthHandler (getContextEntry ctx) req))
  user <- either delayedFailFatal pure outcome
  either delayedFailFatal pure (check user)

instance
  ( HasServer api ctx,
    HasContextEntry ctx (AuthHandler Request AuthUser),
    KnownSymbol r
  ) =>
  HasServer (RequireRole r :> api) ctx
  where
  type ServerT (RequireRole r :> api) m = AuthUser -> ServerT api m

  hoistServerWithContext _ pc nt s =
    hoistServerWithContext (Proxy :: Proxy api) pc nt . s

  route _ ctx subserver =
    route (Proxy :: Proxy api) ctx (subserver `addAuthCheck` withRequest (authorizedCheck ctx check))
    where
      needed = Role (Text.pack (symbolVal (Proxy :: Proxy r)))
      check user
        | needed `Set.member` user.authRoles = Right user
        | otherwise = Left (forbidden "missing_role" "missing required role")

instance
  ( HasServer api ctx,
    HasContextEntry ctx (AuthHandler Request AuthUser),
    KnownSymbol s
  ) =>
  HasServer (RequireScope s :> api) ctx
  where
  type ServerT (RequireScope s :> api) m = AuthUser -> ServerT api m

  hoistServerWithContext _ pc nt srv =
    hoistServerWithContext (Proxy :: Proxy api) pc nt . srv

  route _ ctx subserver =
    route (Proxy :: Proxy api) ctx (subserver `addAuthCheck` withRequest (authorizedCheck ctx check))
    where
      needed = Scope (Text.pack (symbolVal (Proxy :: Proxy s)))
      check user
        | needed `Set.member` user.authScopes = Right user
        | otherwise = Left (forbidden "missing_scope" "missing required scope")
