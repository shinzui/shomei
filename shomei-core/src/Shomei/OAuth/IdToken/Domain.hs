-- | The OIDC ID token's claims (OIDC Core §2), signed by 'Shomei.SigningKey.Signer.signIdToken'.
--
-- An ID token is __not__ an access token. It is a statement /to the client/ that a particular user
-- authenticated at a particular time, and its @aud@ is the @client_id@ — not the API audience.
-- Presenting one as a bearer credential must never work, which is why it carries no @sid@, no
-- scopes, no roles, and no permissions, and why 'Shomei.SigningKey.Verifier' will refuse it (its
-- @aud@ does not match the configured audience).
module Shomei.OAuth.IdToken.Domain
  ( IdTokenClaims (..),
    IdToken (..),
  )
where

import Shomei.Authorization.Claims.Domain (Issuer)
import Shomei.Id (UserId)
import Shomei.Prelude

-- | A signed OIDC ID token (a compact JWS), beside 'Shomei.Session.Token.Domain.AccessToken'.
newtype IdToken = IdToken Text
  deriving stock (Generic)
  deriving newtype (Eq, Show, FromJSON, ToJSON)

data IdTokenClaims = IdTokenClaims
  { issuer :: !Issuer,
    subject :: !UserId,
    -- | the @client_id@ the code was issued to; the ID token is addressed to it alone
    audience :: !Text,
    issuedAt :: !UTCTime,
    expiresAt :: !UTCTime,
    -- | echoed verbatim from the authorize request when one was sent. The client compares it to
    --     the value it generated, which is what stops an attacker replaying someone else's ID
    --     token into the client's session.
    nonce :: !(Maybe Text),
    -- | when the user actually authenticated (the authorizing access token's @iat@), as a JSON
    --     number of Unix seconds on the wire
    authTime :: !UTCTime
  }
  deriving stock (Generic, Eq, Show)
