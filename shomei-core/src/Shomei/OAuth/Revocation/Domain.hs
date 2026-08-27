-- | Ownership policy for RFC 7009 token revocation.
module Shomei.OAuth.Revocation.Domain
  ( RevocationCaller (..),
    mayRevokeSession,
  )
where

import Data.Set qualified as Set
import Shomei.Authorization.Scope.Domain (adminScope)
import Shomei.Prelude
import Shomei.ServiceAccount.Domain (ServiceAccount)
import Shomei.ServiceAccount.Domain qualified as ServiceAccount
import Shomei.Session.Domain (Session)
import Shomei.Session.Domain qualified as Session

-- | The authenticated principal presenting a token to the revocation endpoint.
data RevocationCaller
  = RevokingOAuthClient !Text
  | RevokingServiceAccount !ServiceAccount
  deriving stock (Generic, Eq, Show)

-- | RFC 7009 §2.1: may this caller revoke this session?
--
-- OAuth clients own only sessions minted under their @client_id@. A service account owns machine
-- and delegated sessions in which its backing user is the subject or actor. The documented
-- @shomei:admin@ principal is the explicit global escape hatch.
mayRevokeSession :: RevocationCaller -> Session -> Bool
mayRevokeSession (RevokingOAuthClient callerClientId) Session.Session {oauthClientId} =
  oauthClientId == Just callerClientId
mayRevokeSession
  (RevokingServiceAccount ServiceAccount.ServiceAccount {userId = callerUserId, allowedScopes})
  Session.Session {userId = subjectUserId, actor} =
    adminScope `Set.member` allowedScopes
      || callerUserId == subjectUserId
      || actor == Just callerUserId
