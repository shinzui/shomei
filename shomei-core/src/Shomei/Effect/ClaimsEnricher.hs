{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE TypeFamilies #-}

-- | The host claims-enrichment hook: called at every user-session token mint with the subject
-- and the roles read from the 'Shomei.Effect.RoleStore.RoleStore', returning a 'ClaimsDelta'
-- the core merges into the standard claims.
--
-- This is the same shape as the 'Shomei.Effect.Notifier' port: Shōmei decides /when/, the
-- embedding host decides /what/. A host supplies its own interpreter where it assembles
-- @Shomei.Servant.Seam.Env.runPorts@; the standalone server uses 'runClaimsEnricherNull'.
--
-- The delta's extra-claims object is filtered through 'Shomei.Domain.Claims.mkExtraClaims'
-- before it reaches the token, so a host — or a compromised host code path — can never
-- override a reserved claim (@iss@, @sub@, @aud@, @iat@, @exp@, @sid@, @scopes@, @roles@,
-- @act@). Returning a /delta/ rather than letting the hook rewrite the whole
-- 'Shomei.Domain.Claims.AuthClaims' keeps the standard claims tamper-proof by construction.
--
-- __Do not mirror live authorization decisions into JWT claims through this hook.__ Claims are
-- minted once and are then static for the token's lifetime; a decision copied from a live
-- authorization system (e.g. a check against the en ReBAC engine — see
-- @docs\/plans\/47-en-integration-examples-and-guidance-for-the-recommended-authorization-layer.md@)
-- is stale the moment the underlying relationship changes, silently granting revoked access
-- until the token expires. This hook is for coarse, slow-moving hints — tenant ids, plan tiers,
-- extra scopes — not for per-resource permissions. Check fine-grained permissions live, in the
-- handler, against the authorization system.
module Shomei.Effect.ClaimsEnricher
  ( ClaimsEnricher (..),
    ClaimsDelta (..),
    emptyClaimsDelta,
    enrichClaims,
    runClaimsEnricherNull,
    runClaimsEnricherPure,
  )
where

import Data.Aeson (Object)
import Data.Set (Set)
import Data.Set qualified as Set
import Effectful (Dispatch (Dynamic), DispatchOf, Eff, Effect, (:>))
import Effectful.Dispatch.Dynamic (interpret_, send)
import Shomei.Domain.Claims (Role, Scope, noExtraClaims)
import Shomei.Id (UserId)
import Shomei.Prelude

-- | What a host adds to a freshly minted token's claims. The roles here are merged with (not
-- substituted for) the roles the 'Shomei.Effect.RoleStore.RoleStore' reports.
data ClaimsDelta = ClaimsDelta
  { extraRoles :: !(Set Role),
    extraScopes :: !(Set Scope),
    -- | reserved keys are dropped when this is merged; see 'Shomei.Domain.Claims.mkExtraClaims'
    extraClaims :: !Object
  }
  deriving stock (Generic, Eq, Show)

emptyClaimsDelta :: ClaimsDelta
emptyClaimsDelta =
  ClaimsDelta
    { extraRoles = Set.empty,
      extraScopes = Set.empty,
      extraClaims = noExtraClaims
    }

data ClaimsEnricher :: Effect where
  -- | @EnrichClaims subject rolesFromStore@
  EnrichClaims :: UserId -> Set Role -> ClaimsEnricher m ClaimsDelta

type instance DispatchOf ClaimsEnricher = Dynamic

enrichClaims :: (ClaimsEnricher :> es) => UserId -> Set Role -> Eff es ClaimsDelta
enrichClaims uid roles = send (EnrichClaims uid roles)

-- | The default: no enrichment. The standalone server uses this.
runClaimsEnricherNull :: Eff (ClaimsEnricher : es) a -> Eff es a
runClaimsEnricherNull = runClaimsEnricherPure \_ _ -> emptyClaimsDelta

-- | A pure hook for embedding hosts and tests: supply a function of the subject and its stored
-- roles. A host needing effects of its own writes its own @interpret_@ instead.
runClaimsEnricherPure ::
  (UserId -> Set Role -> ClaimsDelta) ->
  Eff (ClaimsEnricher : es) a ->
  Eff es a
runClaimsEnricherPure f = interpret_ \case
  EnrichClaims uid roles -> pure (f uid roles)
