{-# LANGUAGE EmptyDataDecls #-}
{-# LANGUAGE StandaloneKindSignatures #-}

{- | Role/scope authorization.

The MVP path is the guard functions 'requireRole' / 'requireScope', called at the
top of an authenticated handler (which already has the 'AuthUser' in scope). The
phantom 'RequireRole' / 'RequireScope' combinators are exported so the API type can
/document/ intent (e.g. @RequireRole "admin" :> Authenticated :> ...@) and so a
later plan can add their 'HasServer' instances without changing call sites. A full
type-level guard must thread the 'AuthUser' (which only exists after 'Authenticated'
has run) out of the delegated sub-server; the guard-function form sidesteps that and
is trivially testable (it just throws @403@).
-}
module Shomei.Servant.Authz (
    RequireRole,
    RequireScope,
    requireRole,
    requireScope,
) where

import Data.Kind (Type)
import GHC.TypeLits (Symbol)
import Data.Set qualified as Set

import Servant (Handler, err403, errBody, throwError)

import Shomei.Domain.Claims (Role, Scope)
import Shomei.Servant.Auth (AuthUser (..))

{- | Phantom combinator: document an admin-only route. Reserved for a future
'HasServer' instance; the MVP uses 'requireRole'. (The type parameter is named
@r@, not @role@: under GHC2024 'RoleAnnotations' is on, so @role@ is a
context-sensitive keyword and cannot be a type-variable binder.)
-}
type RequireRole :: Symbol -> Type
data RequireRole r

-- | Phantom combinator for a required scope. Reserved for future 'HasServer'.
type RequireScope :: Symbol -> Type
data RequireScope s

-- | Guard: fail with @403@ unless the principal carries the role.
requireRole :: Role -> AuthUser -> Handler ()
requireRole role u
    | role `Set.member` u.authRoles = pure ()
    | otherwise = throwError err403{errBody = "missing required role"}

-- | Guard: fail with @403@ unless the principal carries the scope.
requireScope :: Scope -> AuthUser -> Handler ()
requireScope scope u
    | scope `Set.member` u.authScopes = pure ()
    | otherwise = throwError err403{errBody = "missing required scope"}
