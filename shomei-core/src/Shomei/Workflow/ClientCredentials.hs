-- | The OAuth2 @client_credentials@ grant (RFC 6749 §4.4) over database-backed service accounts.
--
-- A machine client authenticates as itself with a @client_id@ and a secret, and receives an
-- access token for its own identity — no user interaction, and deliberately no refresh token:
-- the credential dies at its TTL and the client simply asks again.
--
-- This is the runtime-managed sibling of 'Shomei.Workflow.ServiceToken.issueServiceToken',
-- which authenticates accounts declared in static configuration. Both mint the same shape of
-- token through the same signing path, share one secret-verification function
-- ('Shomei.Workflow.ServiceToken.verifyServiceSecret'), age on the same
-- @serviceTokenConfig.ttl@, and publish the same 'Shomei.Domain.Event.ServiceTokenIssued' audit
-- event, so a consumer of the audit trail sees one event type for "a machine token was minted"
-- regardless of which path minted it.
--
-- One deliberate asymmetry: this workflow does NOT consult @serviceTokenConfig.enabled@. That
-- flag gates the deprecated @POST \/v1\/auth\/service-token@ endpoint and its config-defined
-- accounts. A database-backed account is "enabled" by existing, and revoked by being revoked.
module Shomei.Workflow.ClientCredentials
  ( ClientCredentialsGrant (..),
    GrantedToken (..),
    grantClientCredentials,
  )
where

import Data.Generics.Labels ()
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Time (NominalDiffTime, addUTCTime)
import Effectful (Eff, (:>))
import Effectful.Error.Static (runErrorNoCallStack, throwError)
import Shomei.Config (ServiceAccountId (..), ServiceTokenConfig (..), ShomeiConfig (..))
import Shomei.Domain.Claims (Scope)
import Shomei.Domain.Event qualified as Event
-- Imported WITHOUT (..): 'ServiceAccount' shares the field names @userId@ and @status@ with
-- 'Shomei.Domain.User.User', and bringing both record's fields into scope defeats
-- @OverloadedRecordDot@'s 'HasField' resolution (a MasterPlan-3 discovery). Every field below is
-- read through a generic-lens label instead, exactly as 'Shomei.Workflow.ServiceToken' does.
import Shomei.Domain.ServiceAccount (ServiceAccount, ServiceAccountStatus (..))
import Shomei.Domain.Session (NewSession (..))
import Shomei.Domain.Token (AccessToken)
import Shomei.Domain.User (UserStatus (UserActive))
import Shomei.Effect.AuthEventPublisher (AuthEventPublisher, publishAuthEvent)
import Shomei.Effect.Clock (Clock, now)
import Shomei.Effect.ServiceAccountStore (ServiceAccountStore, findServiceAccountByClientId)
import Shomei.Effect.SessionStore (SessionStore, createSession)
import Shomei.Effect.TokenSigner (TokenSigner, signAccessToken)
import Shomei.Effect.UserStore (UserStore, findUserById)
import Shomei.Error (AuthError (..))
import Shomei.Id (SessionId)
import Shomei.Prelude
import Shomei.Workflow.ServiceToken (verifyServiceSecret)
import Shomei.Workflow.Session (buildClaims)

data ClientCredentialsGrant = ClientCredentialsGrant
  { clientId :: !Text,
    clientSecret :: !Text,
    -- | 'Nothing' means the @scope@ parameter was absent from the request, which RFC 6749 §3.3
    --     lets the server answer with a default. @Just@ an empty set means the caller sent
    --     @scope=@, which is a malformed request, not a request for nothing.
    requestedScopes :: !(Maybe (Set Scope))
  }
  deriving stock (Generic, Eq, Show)

data GrantedToken = GrantedToken
  { accessToken :: !AccessToken,
    expiresIn :: !NominalDiffTime,
    -- | echoed back to the client, so it never has to guess what it was actually given
    grantedScopes :: !(Set Scope),
    sessionId :: !SessionId
  }
  deriving stock (Generic, Eq, Show)

-- | Authenticate a database-backed service account and mint its access token.
--
-- Every authentication failure — unknown @client_id@, wrong secret, revoked account, missing or
-- inactive backing user — returns the single 'OAuthClientInvalid'. A caller must not be able to
-- tell a revoked credential from a mistyped one, nor learn that a @client_id@ exists.
grantClientCredentials ::
  ( ServiceAccountStore :> es,
    UserStore :> es,
    SessionStore :> es,
    TokenSigner :> es,
    AuthEventPublisher :> es,
    Clock :> es
  ) =>
  ShomeiConfig ->
  ClientCredentialsGrant ->
  Eff es (Either AuthError GrantedToken)
grantClientCredentials cfg cmd = runErrorNoCallStack do
  account <- maybe (throwError OAuthClientInvalid) pure =<< findServiceAccountByClientId (cmd ^. #clientId)
  -- Verify the secret before checking status, so a revoked account and an active one with a
  -- wrong secret cost the same work.
  unless (verifyServiceSecret (account ^. #secretHash) (cmd ^. #clientSecret)) (throwError OAuthClientInvalid)
  unless ((account ^. #status) == ServiceAccountActive) (throwError OAuthClientInvalid)
  granted <- resolveScopes account
  serviceUser <- do
    user <- maybe (throwError OAuthClientInvalid) pure =<< findUserById (account ^. #userId)
    unless ((user ^. #status) == UserActive) (throwError OAuthClientInvalid)
    pure user
  ts <- now
  let ttl = cfg ^. #serviceTokenConfig . #ttl
      expires = addUTCTime ttl ts
  -- A refresh-less session: no NewRefreshToken is ever created for it, so the credential cannot
  -- outlive its TTL. Machine clients re-authenticate instead of refreshing.
  session <-
    createSession
      NewSession
        { userId = serviceUser ^. #userId,
          createdAt = ts,
          expiresAt = expires,
          actor = Nothing
        }
  let claims =
        (buildClaims cfg (serviceUser ^. #userId) (session ^. #sessionId) ts)
          & #expiresAt
          .~ expires
          & #scopes
          .~ granted
  access <- signAccessToken claims
  publishAuthEvent
    ( Event.ServiceTokenIssued
        Event.ServiceTokenIssuedData
          { userId = serviceUser ^. #userId,
            sessionId = session ^. #sessionId,
            -- The wire shape is unchanged: 'ServiceAccountId' is a newtype over 'Text', and the
            -- database-backed account's public name is its client id.
            accountId = ServiceAccountId (account ^. #clientId),
            scopes = granted,
            actorId = Nothing,
            occurredAt = ts
          }
    )
  pure
    GrantedToken
      { accessToken = access,
        expiresIn = ttl,
        grantedScopes = granted,
        sessionId = session ^. #sessionId
      }
  where
    -- RFC 6749 §3.3: an absent `scope` may take a server-defined default. "Everything this
    -- account is allowed" is the least surprising default for a machine credential. A present
    -- `scope` must name a non-empty subset of the allow-list.
    resolveScopes account = case cmd ^. #requestedScopes of
      Nothing -> pure (account ^. #allowedScopes)
      Just requested -> do
        when (Set.null requested) (throwError OAuthScopeInvalid)
        unless (requested `Set.isSubsetOf` (account ^. #allowedScopes)) (throwError OAuthScopeInvalid)
        pure requested
