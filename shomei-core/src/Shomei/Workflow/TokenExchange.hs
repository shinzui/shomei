-- | RFC 8693 (OAuth 2.0 Token Exchange) as a third grant on @POST \/oauth\/token@ (EP-6).
--
-- Token exchange generalizes the two delegated-token stories Shōmei already tells into one
-- standard grant. Both modes issue a __delegation-shaped__ token — @sub@ names the represented
-- party, @act@ names who is wielding it — through the single shared mint
-- 'Shomei.Workflow.Impersonation.mintDelegatedToken', so the standards path and the bespoke
-- @\/auth\/impersonate@ endpoint cannot drift.
--
--   * __Impersonation mode__ — an operator holding the @impersonate:user@ scope exchanges a bare
--     user id (@subject_token_type = urn:shomei:params:oauth:token-type:user-id@) plus their own
--     access token as the @actor_token@, for a token that /is/ that user. This reuses
--     'Shomei.Workflow.Impersonation.startImpersonation' verbatim, so the scope gate, freshness
--     gate, self\/active-target checks, refresh-less session, and @impersonation_started@ audit
--     event are literally the same code as the bespoke endpoint.
--
--   * __Service on-behalf-of mode__ — a service account (EP-4) authenticates as the OAuth client of
--     the request and presents a user's access token as the @subject_token@. It receives a
--     narrowed, short-lived token carrying the user's @sub@ and the service's identity in @act@, so
--     user identity propagates across service hops. Gated behind the dedicated
--     @token-exchange:subject@ scope on the account, which is never itself copied into an issued
--     token (that would let exchanged tokens perform further exchanges).
--
-- __Errors here are 'AuthError', but never reach the problem envelope.__ The @POST \/oauth\/token@
-- dispatcher renders them in the RFC 6749 §5.2 shape (see "Shomei.Servant.OAuth"): 'OAuthGrantInvalid'
-- → @invalid_grant@, 'OAuthScopeInvalid' → @invalid_scope@, 'OAuthRequestMalformed' →
-- @invalid_request@, 'OAuthClientInvalid' → @invalid_client@, and the impersonation guards
-- ('ImpersonationForbidden'\/'ImpersonationTargetInvalid') collapse to @invalid_grant@ so a stock
-- caller learns nothing of Shōmei's impersonation policy internals.
--
-- __Chained exchanges are refused outright.__ A token already carrying @act@ (any delegated token,
-- from either mode) is rejected as a subject or actor token, so delegation chains cannot form. This
-- is simpler to reason about than nesting prior @act@ claims, and is revisitable later.
module Shomei.Workflow.TokenExchange
  ( ExchangeRequest (..),
    ExchangedToken (..),
    exchangeToken,
    userIdTokenType,
    accessTokenType,
    tokenExchangeSubjectScope,
  )
where

import Data.Generics.Labels ()
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Time (NominalDiffTime)
import Effectful (Eff, (:>))
import Effectful.Error.Static (Error, runErrorNoCallStack, throwError)
import Shomei.Config (ImpersonationConfig (..), ServiceTokenConfig (..), ShomeiConfig (..))
import Shomei.Domain.Claims (AuthClaims (..), Scope (..))
import Shomei.Domain.Event qualified as Event
import Shomei.Domain.ServiceAccount (ServiceAccount, ServiceAccountStatus (ServiceAccountActive))
import Shomei.Domain.Token (AccessToken (..))
import Shomei.Domain.User (User, UserStatus (UserActive))
import Shomei.Effect.AuthEventPublisher (AuthEventPublisher, publishAuthEvent)
import Shomei.Effect.Clock (Clock, now)
import Shomei.Effect.SessionStore (SessionStore)
import Shomei.Effect.TokenSigner (TokenSigner)
import Shomei.Effect.TokenVerifier (TokenVerifier, verifyAccessToken)
import Shomei.Effect.UserStore (UserStore, findUserById)
import Shomei.Error (AuthError (..))
import Shomei.Id (SessionId, UserId, parseId)
import Shomei.Prelude
import Shomei.Workflow.Impersonation
  ( DelegatedMint (..),
    StartImpersonation (..),
    mintDelegatedToken,
    startImpersonation,
  )

-- | The Shōmei-defined token type URN for "a bare user id" — the impersonation-mode
-- @subject_token@. A support operator holds no token of the customer's; the customer's identity is
-- known only by id, so a provider URN for the id itself is the RFC-sanctioned escape hatch.
userIdTokenType :: Text
userIdTokenType = "urn:shomei:params:oauth:token-type:user-id"

-- | The standard RFC 8693 access-token type URN.
accessTokenType :: Text
accessTokenType = "urn:ietf:params:oauth:token-type:access_token"

-- | The gate scope a service account must hold in its @allowed_scopes@ to use on-behalf-of mode. It
-- is a gate, never carried: it is stripped from every issued token so an exchanged token cannot
-- itself perform an exchange.
tokenExchangeSubjectScope :: Scope
tokenExchangeSubjectScope = Scope "token-exchange:subject"

-- | A parsed RFC 8693 token-exchange request. The dispatcher in "Shomei.Servant.Handlers" reads the
-- form parameters and performs client authentication (setting 'authenticatedService'); this
-- workflow performs all of the policy.
data ExchangeRequest = ExchangeRequest
  { subjectToken :: !Text,
    subjectTokenType :: !Text,
    actorToken :: !(Maybe Text),
    actorTokenType :: !(Maybe Text),
    requestedScopes :: !(Maybe (Set Scope)),
    requestedTokenType :: !(Maybe Text),
    reason :: !(Maybe Text),
    ticketId :: !(Maybe Text),
    clientIp :: !(Maybe Text),
    -- | 'Nothing' = the caller did not client-authenticate (impersonation mode authenticates through
    --     the actor token instead); 'Just' = EP-4 client authentication already succeeded, so this is
    --     an on-behalf-of request from that service account.
    authenticatedService :: !(Maybe ServiceAccount)
  }
  deriving stock (Generic, Show)

-- | The result of a successful exchange: the signed access token, its lifetime, the scopes it
-- carries (empty for impersonation), and the delegated session's id.
data ExchangedToken = ExchangedToken
  { accessToken :: !AccessToken,
    expiresIn :: !NominalDiffTime,
    grantedScopes :: !(Set Scope),
    sessionId :: !SessionId
  }
  deriving stock (Generic, Show)

-- | Run a token-exchange request in whichever mode its parameters select.
exchangeToken ::
  ( UserStore :> es,
    SessionStore :> es,
    TokenSigner :> es,
    TokenVerifier :> es,
    AuthEventPublisher :> es,
    Clock :> es
  ) =>
  ShomeiConfig ->
  ExchangeRequest ->
  Eff es (Either AuthError ExchangedToken)
exchangeToken cfg req = runErrorNoCallStack do
  -- We only ever issue access tokens: any other requested_token_type is malformed for this grant.
  case req.requestedTokenType of
    Nothing -> pure ()
    Just t | t == accessTokenType -> pure ()
    Just _ -> throwError OAuthRequestMalformed
  case (req.subjectTokenType == userIdTokenType, req.subjectTokenType == accessTokenType, req.authenticatedService) of
    -- Impersonation: a user-id subject and no client authentication.
    (True, _, Nothing) -> impersonationMode cfg req
    -- On-behalf-of: an access-token subject presented by an authenticated service account.
    (_, True, Just svc) -> onBehalfOfMode cfg req svc
    -- Every other combination — a client-authenticated user-id subject, an unauthenticated
    -- access-token subject, an unknown subject type — is a request that names neither mode.
    _ -> throwError OAuthRequestMalformed

-- | Impersonation mode. Delegates to 'startImpersonation' so the guards, session shape, and audit
-- event are exactly the bespoke endpoint's.
impersonationMode ::
  ( UserStore :> es,
    SessionStore :> es,
    TokenSigner :> es,
    TokenVerifier :> es,
    AuthEventPublisher :> es,
    Clock :> es,
    Error AuthError :> es
  ) =>
  ShomeiConfig ->
  ExchangeRequest ->
  Eff es ExchangedToken
impersonationMode cfg req = do
  -- The operator's credential travels as the actor token; it is required, and must be an access
  -- token. Its absence or a wrong actor_token_type is a malformed request, not a bad grant.
  rawActor <- maybe (throwError OAuthRequestMalformed) pure req.actorToken
  case req.actorTokenType of
    Just t | t == accessTokenType -> pure ()
    _ -> throwError OAuthRequestMalformed
  actorClaims <- verifyToken rawActor
  -- No chained exchanges: a delegated token may not itself act as the operator.
  when (isJust actorClaims.actor) (throwError OAuthGrantInvalid)
  targetUserId <- parseSubjectUserId req.subjectToken
  (session, access) <-
    either throwError pure
      =<< startImpersonation
        cfg
        StartImpersonation
          { actorClaims,
            targetUserId,
            reason = fromMaybe "token_exchange" req.reason,
            ticketId = req.ticketId,
            clientIp = req.clientIp
          }
  pure
    ExchangedToken
      { accessToken = access,
        expiresIn = cfg.impersonationConfig.impersonationSessionTTL,
        grantedScopes = Set.empty,
        sessionId = session ^. #sessionId
      }

-- | Service on-behalf-of mode. The authenticated service acts /for/ the subject token's user.
onBehalfOfMode ::
  ( UserStore :> es,
    SessionStore :> es,
    TokenSigner :> es,
    TokenVerifier :> es,
    AuthEventPublisher :> es,
    Clock :> es,
    Error AuthError :> es
  ) =>
  ShomeiConfig ->
  ExchangeRequest ->
  ServiceAccount ->
  Eff es ExchangedToken
onBehalfOfMode cfg req svc = do
  -- The account must be active and must hold the gate scope. A revoked account, or one without the
  -- gate, learns only that it may not do this — never anything about the subject token.
  unless (svc ^. #status == ServiceAccountActive) (throwError OAuthClientInvalid)
  let allowed = svc ^. #allowedScopes
  unless (tokenExchangeSubjectScope `Set.member` allowed) (throwError OAuthScopeInvalid)
  subjectClaims <- verifyToken req.subjectToken
  -- No chained exchanges: a delegated token cannot be re-exchanged.
  when (isJust subjectClaims.actor) (throwError OAuthGrantInvalid)
  requireActiveUser subjectClaims.subject
  -- The service's backing user must be active too, or it cannot mint on anyone's behalf.
  requireActiveUser (svc ^. #userId)
  granted <- narrowScopes req.requestedScopes allowed subjectClaims.scopes
  ts <- now
  (session, access) <-
    mintDelegatedToken
      cfg
      ts
      DelegatedMint
        { subjectUserId = subjectClaims.subject,
          actorUserId = svc ^. #userId,
          scopes = granted,
          ttl = cfg.serviceTokenConfig.ttl
        }
  let sid = session ^. #sessionId
  publishAuthEvent
    ( Event.ServiceOnBehalfIssued
        Event.ServiceOnBehalfIssuedData
          { serviceAccountId = svc ^. #clientId,
            actorUserId = svc ^. #userId,
            subjectUserId = subjectClaims.subject,
            sessionId = sid,
            scopes = granted,
            occurredAt = ts
          }
    )
  pure
    ExchangedToken
      { accessToken = access,
        expiresIn = cfg.serviceTokenConfig.ttl,
        grantedScopes = granted,
        sessionId = sid
      }

-- | Scope narrowing for on-behalf-of (per the plan's Decision Log):
--
--   * requested defaults to the account's allowed scopes minus the gate scope when @scope@ is absent;
--   * the granted set is @requested ∩ (allowed \\ gate)@ — the service can never confer a scope it
--     does not hold, and the gate scope is never carried;
--   * when the subject token carries a __non-empty__ scope set, the granted set must be within it
--     (@granted ⊆ subject.scopes@), else 'OAuthScopeInvalid'. An empty subject scope set — today's
--     interactive user tokens — imposes no bound (an unscoped session is not "no authority");
--   * an empty granted set is 'OAuthScopeInvalid'.
narrowScopes ::
  (Error AuthError :> es) =>
  Maybe (Set Scope) ->
  Set Scope ->
  Set Scope ->
  Eff es (Set Scope)
narrowScopes mRequested allowed subjectScopes = do
  let ceiling_ = Set.delete tokenExchangeSubjectScope allowed
      requested = fromMaybe ceiling_ mRequested
      granted = Set.intersection requested ceiling_
  when (Set.null granted) (throwError OAuthScopeInvalid)
  unless (Set.null subjectScopes || granted `Set.isSubsetOf` subjectScopes) (throwError OAuthScopeInvalid)
  pure granted

-- | Verify a presented compact token back into its claims, or fail the whole exchange with
-- @invalid_grant@ — a subject or actor token that will not validate is a bad grant, and every
-- reason it might fail is indistinguishable on the wire.
verifyToken ::
  (TokenVerifier :> es, Error AuthError :> es) =>
  Text ->
  Eff es AuthClaims
verifyToken raw =
  either (const (throwError OAuthGrantInvalid)) pure =<< verifyAccessToken (AccessToken raw)

-- | Parse the impersonation-mode @subject_token@: a bare user id. A garbage id is an invalid grant.
parseSubjectUserId :: (Error AuthError :> es) => Text -> Eff es UserId
parseSubjectUserId raw = either (const (throwError OAuthGrantInvalid)) pure (parseId raw)

-- | Require a user to exist and be active, else 'OAuthGrantInvalid'. Used for both the subject and
-- the service's backing user: neither an absent nor an inactive user can be represented or act.
requireActiveUser :: (UserStore :> es, Error AuthError :> es) => UserId -> Eff es ()
requireActiveUser uid = do
  user <- maybe (throwError OAuthGrantInvalid) pure =<< findUserById uid
  unless ((user :: User) ^. #status == UserActive) (throwError OAuthGrantInvalid)
