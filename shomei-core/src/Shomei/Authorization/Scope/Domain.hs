-- | Scope values that Shōmei itself interprets as privilege gates.
module Shomei.Authorization.Scope.Domain
  ( adminScope,
    tokenExchangeSubjectScope,
    privilegeScopes,
    privilegeScopesIn,
  )
where

import Data.Set (Set)
import Data.Set qualified as Set
import Shomei.Authorization.Claims.Domain (Scope (..))
import Shomei.Config (ImpersonationConfig (..), ShomeiConfig (..))

-- | The scope carried by a service token that may administer Shōmei.
adminScope :: Scope
adminScope = Scope "shomei:admin"

-- | The gate a service account must hold to exchange a user's token on behalf of that user.
tokenExchangeSubjectScope :: Scope
tokenExchangeSubjectScope = Scope "token-exchange:subject"

-- | Scopes that confer authority to the bearer rather than naming an ordinary capability.
-- An OAuth client's allowed scopes are copied onto each authorizing user's token, so these scopes
-- may never be registered on a client. Service accounts remain their intended holders.
privilegeScopes :: ShomeiConfig -> Set Scope
privilegeScopes cfg =
  Set.fromList
    [ cfg.impersonationConfig.impersonateScope,
      adminScope,
      tokenExchangeSubjectScope
    ]

privilegeScopesIn :: ShomeiConfig -> Set Scope -> Set Scope
privilegeScopesIn cfg = Set.intersection (privilegeScopes cfg)
