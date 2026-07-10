-- | The OAuth2 \/ OIDC client entity (EP-5): a relying party registered by an operator, which
-- drives the authorization-code flow at @GET \/oauth\/authorize@ and exchanges its code at
-- @POST \/oauth\/token@.
--
-- Distinct from 'Shomei.Domain.ServiceAccount.ServiceAccount', EP-4's machine credential. A
-- service account authenticates /as itself/ and has a backing @shomei_users@ row, because its
-- token's @sub@ is that user. An OAuth client authenticates only to prove /which client/ is
-- exchanging a code; the token it receives belongs to whichever user authenticated at authorize.
-- So an OAuth client is never a token subject and has no user row.
--
-- 'secretHash' is a lowercase 64-char SHA-256 hex digest — the same format the service accounts
-- use, so 'Shomei.Workflow.ServiceToken.verifyServiceSecret' verifies both — and is 'Nothing' for
-- exactly the 'PublicClient's.
module Shomei.Domain.OAuthClient
  ( ClientType (..),
    OAuthClientStatus (..),
    OAuthClient (..),
    NewOAuthClient (..),
    isRegisteredRedirectUri,
  )
where

import Data.Set (Set)
import Shomei.Domain.Claims (Scope)
import Shomei.Id (OAuthClientId)
import Shomei.Prelude

-- | A 'ConfidentialClient' can keep a secret (a server-side web app); a 'PublicClient' cannot
-- (a browser SPA, a native or CLI app). PKCE is mandatory for the latter: with no secret, the
-- code challenge is its only binding between the authorize and token requests.
data ClientType = ConfidentialClient | PublicClient
  deriving stock (Generic, Eq, Show)
  deriving anyclass (FromJSON, ToJSON)

-- | A revoked client keeps its row: audit events naming it must still resolve, and its
-- @client_id@ must never be recycled.
data OAuthClientStatus = OAuthClientActive | OAuthClientRevoked
  deriving stock (Generic, Eq, Show)
  deriving anyclass (FromJSON, ToJSON)

data OAuthClient = OAuthClient
  { oauthClientId :: !OAuthClientId,
    -- | the TypeID text rendering of 'oauthClientId'; the OAuth2 @client_id@. Public.
    clientId :: !Text,
    -- | 'Nothing' for exactly a 'PublicClient'
    secretHash :: !(Maybe Text),
    clientType :: !ClientType,
    displayName :: !Text,
    -- | absolute URIs, matched by exact string equality (see 'isRegisteredRedirectUri')
    redirectUris :: ![Text],
    -- | the ceiling on what an authorize request may ask for
    allowedScopes :: !(Set Scope),
    status :: !OAuthClientStatus,
    createdAt :: !UTCTime,
    revokedAt :: !(Maybe UTCTime)
  }
  deriving stock (Generic, Eq, Show)
  deriving anyclass (FromJSON, ToJSON)

data NewOAuthClient = NewOAuthClient
  { oauthClientId :: !OAuthClientId,
    clientId :: !Text,
    secretHash :: !(Maybe Text),
    clientType :: !ClientType,
    displayName :: !Text,
    redirectUris :: ![Text],
    allowedScopes :: !(Set Scope),
    createdAt :: !UTCTime
  }
  deriving stock (Generic, Eq, Show)
  deriving anyclass (FromJSON, ToJSON)

-- | Is this the client's redirect URI?
--
-- Exact string equality, deliberately: no prefix matching, no wildcard, no normalization. A
-- redirect target the operator did not register must never receive a redirect, because
-- @\/oauth\/authorize@ would then be an open redirector — an attacker registers
-- @https:\/\/app.example.com\/cb@, requests @https:\/\/app.example.com\/cb\/..\/..\/@ or
-- @https:\/\/app.example.com.evil.test\/cb@, and harvests authorization codes. Comparing the
-- bytes the operator wrote down is the only rule with no edge cases.
isRegisteredRedirectUri :: OAuthClient -> Text -> Bool
isRegisteredRedirectUri client uri = uri `elem` client.redirectUris
