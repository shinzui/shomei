{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE PolyKinds #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE UndecidableInstances #-}

-- | Derive the rate-limited HTTP operation set from the same 'RateLimited' markers that annotate
-- the Servant API. The standalone WAI middleware consumes this value, so route declarations are
-- the single source of truth for both OpenAPI's 429 responses and runtime throttling.
module Shomei.Servant.Throttle
  ( PathSegment (..),
    ThrottledRoute (..),
    HasThrottledRoutes (..),
    throttledRoutesOf,
    matchesThrottledRoute,
  )
where

import Data.Text qualified as Text
import GHC.Generics (K1, M1, Rep, (:*:))
import GHC.TypeLits (KnownSymbol, Symbol, symbolVal)
import Network.HTTP.Types (Method)
import Servant.API
import Servant.API.MultiVerb (MultiVerb)
import Shomei.Prelude
import Shomei.Servant.Auth (Authenticated, OAuthAuthenticated)
import Shomei.Servant.Authz (RequireAdmin, RequirePermission, RequireRole, RequireScope)
import Shomei.Servant.PreHandler (CsrfProtected, PreHandlerResponses, RateLimited)

data PathSegment
  = Literal !Text
  | Wildcard
  deriving stock (Eq, Ord, Show)

data ThrottledRoute = ThrottledRoute
  { method :: !Method,
    path :: ![PathSegment]
  }
  deriving stock (Eq, Ord, Show)

class HasThrottledRoutes api where
  -- | Every operation below @api@ paired with whether a 'RateLimited' marker guards it.
  allRoutes :: Proxy api -> [(Bool, ThrottledRoute)]

throttledRoutesOf :: forall api. (HasThrottledRoutes api) => Proxy api -> [ThrottledRoute]
throttledRoutesOf proxy = [route | (True, route) <- allRoutes proxy]

matchesThrottledRoute :: [ThrottledRoute] -> Method -> [Text] -> Bool
matchesThrottledRoute routes requestMethod requestPath =
  any matches routes
  where
    matches route = route.method == requestMethod && pathMatches route.path requestPath
    pathMatches expected actual =
      length expected == length actual
        && and (zipWith segmentMatches expected actual)
    segmentMatches (Literal expected) actual = expected == actual
    segmentMatches Wildcard _ = True

instance (HasThrottledRoutes left, HasThrottledRoutes right) => HasThrottledRoutes (left :<|> right) where
  allRoutes _ = allRoutes (Proxy @left) <> allRoutes (Proxy @right)

instance (KnownSymbol segment, HasThrottledRoutes sub) => HasThrottledRoutes ((segment :: Symbol) :> sub) where
  allRoutes _ = prepend (Literal (Text.pack (symbolVal (Proxy @segment)))) (allRoutes (Proxy @sub))

instance (HasThrottledRoutes sub) => HasThrottledRoutes (Capture' mods name value :> sub) where
  allRoutes _ = prepend Wildcard (allRoutes (Proxy @sub))

instance (HasThrottledRoutes sub) => HasThrottledRoutes (RateLimited :> sub) where
  allRoutes _ = [(True, route) | (_, route) <- allRoutes (Proxy @sub)]

instance (HasThrottledRoutes sub) => HasThrottledRoutes (CsrfProtected :> sub) where allRoutes _ = allRoutes (Proxy @sub)

instance (HasThrottledRoutes sub) => HasThrottledRoutes (PreHandlerResponses responses :> sub) where allRoutes _ = allRoutes (Proxy @sub)

instance (HasThrottledRoutes sub) => HasThrottledRoutes (Authenticated :> sub) where allRoutes _ = allRoutes (Proxy @sub)

instance (HasThrottledRoutes sub) => HasThrottledRoutes (OAuthAuthenticated :> sub) where allRoutes _ = allRoutes (Proxy @sub)

instance (HasThrottledRoutes sub) => HasThrottledRoutes (RequireAdmin :> sub) where allRoutes _ = allRoutes (Proxy @sub)

instance (HasThrottledRoutes sub) => HasThrottledRoutes (RequireRole requiredRole :> sub) where allRoutes _ = allRoutes (Proxy @sub)

instance (HasThrottledRoutes sub) => HasThrottledRoutes (RequireScope scope :> sub) where allRoutes _ = allRoutes (Proxy @sub)

instance (HasThrottledRoutes sub) => HasThrottledRoutes (RequirePermission permission :> sub) where allRoutes _ = allRoutes (Proxy @sub)

instance (HasThrottledRoutes sub) => HasThrottledRoutes (RemoteHost :> sub) where allRoutes _ = allRoutes (Proxy @sub)

instance (HasThrottledRoutes sub) => HasThrottledRoutes (ReqBody' mods contentTypes value :> sub) where allRoutes _ = allRoutes (Proxy @sub)

instance (HasThrottledRoutes sub) => HasThrottledRoutes (Header' mods name value :> sub) where allRoutes _ = allRoutes (Proxy @sub)

instance (HasThrottledRoutes sub) => HasThrottledRoutes (QueryParam' mods name value :> sub) where allRoutes _ = allRoutes (Proxy @sub)

instance (HasThrottledRoutes sub) => HasThrottledRoutes (QueryParams name value :> sub) where allRoutes _ = allRoutes (Proxy @sub)

instance (ReflectMethod method) => HasThrottledRoutes (Verb method status contentTypes value) where
  allRoutes _ = [(False, ThrottledRoute (reflectMethod (Proxy @method)) [])]

instance (ReflectMethod method) => HasThrottledRoutes (MultiVerb method contentTypes responses result) where
  allRoutes _ = [(False, ThrottledRoute (reflectMethod (Proxy @method)) [])]

instance HasThrottledRoutes Raw where
  allRoutes _ = []

class GHasThrottledRoutes representation where
  genericRoutes :: Proxy representation -> [(Bool, ThrottledRoute)]

instance (GHasThrottledRoutes inner) => GHasThrottledRoutes (M1 metadata meta inner) where
  genericRoutes _ = genericRoutes (Proxy @inner)

instance (GHasThrottledRoutes left, GHasThrottledRoutes right) => GHasThrottledRoutes (left :*: right) where
  genericRoutes _ = genericRoutes (Proxy @left) <> genericRoutes (Proxy @right)

instance (HasThrottledRoutes api) => GHasThrottledRoutes (K1 field api) where
  genericRoutes _ = allRoutes (Proxy @api)

instance
  (GHasThrottledRoutes (Rep (routes AsApi))) =>
  HasThrottledRoutes (NamedRoutes routes)
  where
  allRoutes _ = genericRoutes (Proxy @(Rep (routes AsApi)))

prepend :: PathSegment -> [(Bool, ThrottledRoute)] -> [(Bool, ThrottledRoute)]
prepend segment = map (fmap (\route -> route {path = segment : route.path}))
