{-# LANGUAGE EmptyDataDecls #-}
{-# LANGUAGE StandaloneKindSignatures #-}

-- | Type-level markers for failures selected before an operation handler runs.
--
-- These combinators are runtime pass-throughs. Their response-list parameter or policy name is
-- consumed by OpenAPI derivation and conformance tests, while authentication, JSON/query/capture
-- decoding, CSRF enforcement, and rate limiting remain owned by their existing Servant or WAI
-- boundaries.
module Shomei.Servant.PreHandler
  ( PreHandlerResponses,
    CsrfProtected,
    RateLimited,
  )
where

import Data.Kind (Type)
import Servant (type (:>))
import Servant.Server.Internal (HasServer (..))
import Shomei.Prelude

type PreHandlerResponses :: [Type] -> Type
data PreHandlerResponses responses

type CsrfProtected :: Type
data CsrfProtected

type RateLimited :: Type
data RateLimited

instance (HasServer api ctx) => HasServer (PreHandlerResponses responses :> api) ctx where
  type ServerT (PreHandlerResponses responses :> api) m = ServerT api m
  route _ = route (Proxy :: Proxy api)
  hoistServerWithContext _ = hoistServerWithContext (Proxy :: Proxy api)

instance (HasServer api ctx) => HasServer (CsrfProtected :> api) ctx where
  type ServerT (CsrfProtected :> api) m = ServerT api m
  route _ = route (Proxy :: Proxy api)
  hoistServerWithContext _ = hoistServerWithContext (Proxy :: Proxy api)

instance (HasServer api ctx) => HasServer (RateLimited :> api) ctx where
  type ServerT (RateLimited :> api) m = ServerT api m
  route _ = route (Proxy :: Proxy api)
  hoistServerWithContext _ = hoistServerWithContext (Proxy :: Proxy api)
