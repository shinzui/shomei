-- | The OAuth2 authorization code (EP-5): the single-use bearer of an authorize request's
-- decisions, carried through the user's browser to the client and redeemed at the token endpoint.
--
-- The code itself is never stored — only 'codeHash', its SHA-256 hex digest (see
-- 'Shomei.Workflow.ServiceToken.sha256Hex'). A database leak therefore leaks no usable codes,
-- exactly as for refresh tokens.
--
-- Every field below is a binding the exchange re-checks. A code is not a capability to mint /any/
-- token: it is a capability to mint /this/ token, for this user, to this client, at this redirect
-- URI, with proof of the PKCE verifier that produced 'codeChallenge'.
module Shomei.Domain.AuthorizationCode
  ( AuthorizationCode (..),
    NewAuthorizationCode (..),
  )
where

import Data.Set (Set)
import Shomei.Domain.Claims (Scope)
import Shomei.Id (UserId)
import Shomei.Prelude

data AuthorizationCode = AuthorizationCode
  { -- | SHA-256 hex of the opaque code; the primary key
    codeHash :: !Text,
    -- | the only client that may exchange this code
    clientId :: !Text,
    -- | the exchange must present this URI verbatim
    redirectUri :: !Text,
    userId :: !UserId,
    scopes :: !(Set Scope),
    -- | echoed verbatim into the ID token when present (OIDC Core §2)
    nonce :: !(Maybe Text),
    -- | the PKCE S256 challenge (RFC 7636). 'Nothing' only for a confidential client that sent
    --     none; a public client is refused at authorize without one.
    codeChallenge :: !(Maybe Text),
    -- | when the user authenticated — the authorizing access token's @iat@ — for the ID token's
    --     @auth_time@ claim
    authTime :: !UTCTime,
    createdAt :: !UTCTime,
    expiresAt :: !UTCTime,
    -- | stamped by the atomic consume. A code with this set has already been redeemed.
    consumedAt :: !(Maybe UTCTime)
  }
  deriving stock (Generic, Eq, Show)
  deriving anyclass (FromJSON, ToJSON)

data NewAuthorizationCode = NewAuthorizationCode
  { codeHash :: !Text,
    clientId :: !Text,
    redirectUri :: !Text,
    userId :: !UserId,
    scopes :: !(Set Scope),
    nonce :: !(Maybe Text),
    codeChallenge :: !(Maybe Text),
    authTime :: !UTCTime,
    createdAt :: !UTCTime,
    expiresAt :: !UTCTime
  }
  deriving stock (Generic, Eq, Show)
  deriving anyclass (FromJSON, ToJSON)
