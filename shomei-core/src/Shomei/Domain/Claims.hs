{- | The claims embedded in an access token, plus the small newtypes that make the claim
fields type-safe.
-}
module Shomei.Domain.Claims (
    Issuer (..),
    Audience (..),
    Scope (..),
    Role (..),
    AuthClaims (..),
    reservedClaimKeys,
    mkExtraClaims,
    noExtraClaims,
) where

import Shomei.Prelude

import Data.Aeson (Object)
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Set (Set)
import Shomei.Id (SessionId, UserId)

newtype Issuer = Issuer Text
    deriving stock (Generic)
    deriving newtype (Eq, Ord, Show, FromJSON, ToJSON)

newtype Audience = Audience Text
    deriving stock (Generic)
    deriving newtype (Eq, Ord, Show, FromJSON, ToJSON)

newtype Scope = Scope Text
    deriving stock (Generic)
    deriving newtype (Eq, Ord, Show, FromJSON, ToJSON)

newtype Role = Role Text
    deriving stock (Generic)
    deriving newtype (Eq, Ord, Show, FromJSON, ToJSON)

data AuthClaims = AuthClaims
    { subject :: !UserId
    , sessionId :: !SessionId
    , issuer :: !Issuer
    , audience :: !Audience
    , issuedAt :: !UTCTime
    , expiresAt :: !UTCTime
    , scopes :: !(Set Scope)
    , roles :: !(Set Role)
    , actor :: !(Maybe UserId)
    -- ^ when this token is a delegated (impersonation) token, the real operator
    -- acting on behalf of 'subject'; serialised as the @act@ JWT claim. 'Nothing'
    -- for every ordinary login token.
    , extraClaims :: !Object
    -- ^ additional top-level JWT claims a consuming service attaches (e.g. TAN's
    -- @userId@, @userInfo@, @impersonated@, @clientAccountId@, or a service token's
    -- @type@/@serviceInfo@). Empty ('noExtraClaims') for ordinary tokens, which then
    -- serialise byte-identically to before this field existed. Keys that collide with
    -- a standard claim are overridden by the standard claim at sign time.
    }
    deriving stock (Generic, Eq, Show)
    deriving anyclass (FromJSON, ToJSON)

{- | The standard claim keys Shōmei owns; custom claims using these are dropped by
'mkExtraClaims' so a service (or attacker-influenced input) can never forge a
standard claim through the extension bag.
-}
reservedClaimKeys :: [Text]
reservedClaimKeys = ["iss", "sub", "aud", "iat", "exp", "sid", "scopes", "roles", "act"]

-- | Build an extra-claims object, dropping any reserved key (see 'reservedClaimKeys').
mkExtraClaims :: Object -> Object
mkExtraClaims = KeyMap.filterWithKey (\k _ -> Key.toText k `notElem` reservedClaimKeys)

-- | The empty extra-claims object — the default for ordinary tokens.
noExtraClaims :: Object
noExtraClaims = KeyMap.empty
