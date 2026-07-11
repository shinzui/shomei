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
-- (@RequireRole \"editor\"@ cannot mean "editor /of this project/"). Claim changes remain stale
-- until the token expires, but a deployment using @VerifyTokenAndSession@ can reject an expired or
-- revoked backing session immediately. See @docs\/user\/security.md@ for where that boundary lies.
module Shomei.Servant.Authz
  ( RequireRole,
    RequireScope,
    RequirePermission,
    requireRole,
    requireScope,
    requireAdmin,
    adminRole,
    adminScope,
  )
where

import Data.Kind (Type)
import Data.Set qualified as Set
import Data.Text qualified as Text
import GHC.TypeLits (KnownSymbol, Symbol, symbolVal)
import Network.Wai (Request)
import Servant
  ( Context,
    Handler,
    ServerError,
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
import Shomei.Domain.Claims (Permission (..), Role (..), Scope (..))
-- 'Shomei.Prelude' re-exports lens, whose 'Context' collides with servant's.
import Shomei.Prelude hiding (Context)
import Shomei.Servant.Auth (AuthUser (..))
import Shomei.Servant.Error (pcMissingPermission, pcMissingRole, pcMissingScope, toProblemError)

-- | Enforcing combinator: the route demands the named role. (The type parameter is named @r@,
-- not @role@: under GHC2024 @RoleAnnotations@ is on, so @role@ is a context-sensitive keyword
-- and cannot be a type-variable binder.)
type RequireRole :: Symbol -> Type
data RequireRole r

-- | Enforcing combinator: the route demands the named scope.
type RequireScope :: Symbol -> Type
data RequireScope s

-- | Enforcing combinator: the route demands the named __permission__ (EP-9) — i.e. @p@ must be a
-- member of the token's @permissions@ claim, else @403 missing_permission@. The handler still
-- receives the 'AuthUser', exactly as under 'RequireRole'.
--
-- This checks a __static claim__ minted at login\/refresh from the role → permission catalog:
-- rewiring which roles imply @p@, or a grant expiring, applies at the /next/ mint, not to an
-- outstanding token (see @docs\/user\/security.md@; @revokeAllUserSessions@ is the immediate
-- lever). It is __not__ a live authorization check. For relationship-based, instantly-revocable
-- decisions use the __en__ toolkit's term-level @En.Servant.Authorize.requirePermission@ guard (a
-- separate project Shōmei does not depend on); it shares this name because it expresses the same
-- /intent/ at a different freshness tier. See @docs\/user\/authorization.md@ for the boundary.
type RequirePermission :: Symbol -> Type
data RequirePermission p

-- | Guard: fail with @403@ unless the principal carries the role. Use this only for a condition
-- the type-level combinator cannot express; a plain "this route needs role X" belongs in the
-- route type, where it cannot be forgotten.
requireRole :: Role -> AuthUser -> Handler ()
requireRole role u
  | role `Set.member` u.authRoles = pure ()
  | otherwise = throwError missingRole

-- | Guard: fail with @403@ unless the principal carries the scope. See 'requireRole'.
requireScope :: Scope -> AuthUser -> Handler ()
requireScope scope u
  | scope `Set.member` u.authScopes = pure ()
  | otherwise = throwError missingScope

-- | The two 403 problem documents these combinators and guards raise. Shared so the type-level
-- and handler-level paths cannot answer differently.
missingRole, missingScope, missingPermission :: ServerError
missingRole = toProblemError pcMissingRole Nothing
missingScope = toProblemError pcMissingScope Nothing
missingPermission = toProblemError pcMissingPermission Nothing

-- | The @admin@ role, granted through the 'Shomei.Effect.RoleStore' (a human administrator).
adminRole :: Role
adminRole = Role "admin"

-- | The @shomei:admin@ scope, mintable onto a service token (a support console, a back-office
-- job). Namespaced like the existing @impersonate:user@ scope.
adminScope :: Scope
adminScope = Scope "shomei:admin"

-- | The admin gate (EP-2): the principal must carry the @admin@ role __or__ the @shomei:admin@
-- scope.
--
-- This is a guard function rather than a route-type combinator because the condition is a
-- /disjunction/, and a single type-level symbol cannot express one. Both halves are needed: a
-- human administrator carries a granted role, while a database-less service administers with a
-- service token, and @\/v1\/auth\/service-token@ mints scopes, not roles.
--
-- The failure is the same @403 missing_role@ document 'requireRole' raises. It deliberately does
-- not say "…or the @shomei:admin@ scope": telling an unauthorized caller exactly which of two
-- credentials would have worked is a hint they have no business receiving.
requireAdmin :: AuthUser -> Handler ()
requireAdmin u
  | adminRole `Set.member` u.authRoles = pure ()
  | adminScope `Set.member` u.authScopes = pure ()
  | otherwise = throwError missingRole

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
        | otherwise = Left missingRole

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
        | otherwise = Left missingScope

instance
  ( HasServer api ctx,
    HasContextEntry ctx (AuthHandler Request AuthUser),
    KnownSymbol p
  ) =>
  HasServer (RequirePermission p :> api) ctx
  where
  type ServerT (RequirePermission p :> api) m = AuthUser -> ServerT api m

  hoistServerWithContext _ pc nt srv =
    hoistServerWithContext (Proxy :: Proxy api) pc nt . srv

  route _ ctx subserver =
    route (Proxy :: Proxy api) ctx (subserver `addAuthCheck` withRequest (authorizedCheck ctx check))
    where
      needed = Permission (Text.pack (symbolVal (Proxy :: Proxy p)))
      check user
        | needed `Set.member` user.authPermissions = Right user
        | otherwise = Left missingPermission
