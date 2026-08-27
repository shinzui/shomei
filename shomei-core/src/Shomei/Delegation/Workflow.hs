-- | The impersonation token-exchange workflow.
--
-- 'startImpersonation' mints a short-lived __delegated session__ for a target customer
-- on behalf of an authorized operator: a brand-new session row whose @actor@ is the
-- operator, a signed access token carrying both identities (@sub@ = customer, @act@ =
-- operator), and __no refresh token__ so the delegated session cannot be silently
-- renewed and dies at its TTL. 'stopImpersonation' revokes that session.
--
-- Unlike 'Shomei.Session.Workflow.issueSession', this workflow deliberately does NOT
-- create a refresh token and does NOT publish 'LoginSucceeded'/'SessionStarted'; it
-- publishes 'ImpersonationStarted'/'ImpersonationStopped' instead. Who-may-impersonate-whom
-- policy lives in the embedding service, not here (see the plan's Decision Log).
module Shomei.Delegation.Workflow
  ( StartImpersonation (..),
    startImpersonation,
    stopImpersonation,
    DelegatedMint (..),
    mintDelegatedToken,
  )
where

import Data.Set (Set)
import Data.Set qualified as Set
import Data.Time (NominalDiffTime, addUTCTime)
import Effectful (Eff, (:>))
import Effectful.Error.Static (runErrorNoCallStack, throwError)
import Shomei.Account.User.Domain (User (..), UserStatus (UserActive))
import Shomei.Account.User.Store (UserStore, findUserById)
import Shomei.Audit.Event.Domain qualified as Event
import Shomei.Audit.Publisher.Store (AuthEventPublisher, publishAuthEvent)
import Shomei.Authorization.Claims.Domain (AuthClaims (..), Scope, noExtraClaims)
import Shomei.Config (ImpersonationConfig (..), ShomeiConfig (..))
import Shomei.Error (AuthError (..))
import Shomei.Id (UserId)
import Shomei.Prelude
import Shomei.Session.Domain (NewSession (..), Session (..), SessionKind (DelegatedSession))
import Shomei.Session.Store (SessionStore, createSession, revokeSession)
import Shomei.Session.Token.Domain (AccessToken)
import Shomei.Session.Workflow (requireLiveSession)
import Shomei.SigningKey.Signer (TokenSigner, signAccessToken)
import Shomei.Time.Store (Clock, now)

-- | Command to start impersonating a target on behalf of the verified caller.
data StartImpersonation = StartImpersonation
  { -- | the caller's verified token contents (carries scopes + issuedAt + subject)
    actorClaims :: !AuthClaims,
    targetUserId :: !UserId,
    reason :: !Text,
    ticketId :: !(Maybe Text),
    clientIp :: !(Maybe Text)
  }
  deriving stock (Generic, Show)

-- | Exchange the caller's token for a short-lived delegated session + access token
-- for 'targetUserId'. Enforces scope, freshness, live-session, active-operator, self, and
-- target-active checks; mints
-- a refresh-less session; and audits the start. Returns the new 'Session' and signed
-- 'AccessToken'.
startImpersonation ::
  ( UserStore :> es,
    SessionStore :> es,
    TokenSigner :> es,
    AuthEventPublisher :> es,
    Clock :> es
  ) =>
  ShomeiConfig ->
  StartImpersonation ->
  Eff es (Either AuthError (Session, AccessToken))
startImpersonation cfg cmd = runErrorNoCallStack do
  let imp = cfg.impersonationConfig
      caller = cmd.actorClaims
  ts <- now
  -- Scope check: the caller must hold the configured impersonation scope.
  unless (imp.impersonateScope `Set.member` caller.scopes) (throwError ImpersonationForbidden)
  -- Freshness check: the caller's own token must be recently issued.
  when (ts > addUTCTime imp.actorFreshnessWindow caller.issuedAt) (throwError ImpersonationForbidden)
  -- The operator's credential must still be backed by a live session, regardless of the host's
  -- ordinary route-authentication mode.
  _ <- either (const (throwError ImpersonationForbidden)) pure =<< requireLiveSession ts caller.sessionId
  -- A suspended or otherwise inactive operator cannot mint fresh authority from an old token.
  operator <- maybe (throwError ImpersonationForbidden) pure =<< findUserById caller.subject
  unless (operator.status == UserActive) (throwError ImpersonationForbidden)
  -- Self check: an operator may not impersonate themselves.
  when (cmd.targetUserId == caller.subject) (throwError ImpersonationTargetInvalid)
  -- Target check: the target must exist and be active.
  target <- maybe (throwError ImpersonationTargetInvalid) pure =<< findUserById cmd.targetUserId
  unless (target.status == UserActive) (throwError ImpersonationTargetInvalid)
  -- Mint a dedicated, refresh-less, short-lived delegated session through the shared core. Empty
  -- scopes: an impersonation token carries the operator's authority to /be/ the customer, not a
  -- narrowed scope set (that is on-behalf-of's job).
  (session, access) <-
    mintDelegatedToken
      cfg
      ts
      DelegatedMint
        { subjectUserId = cmd.targetUserId,
          actorUserId = caller.subject,
          scopes = Set.empty,
          ttl = imp.impersonationSessionTTL
        }
  publishAuthEvent
    ( Event.ImpersonationStarted
        Event.ImpersonationStartedData
          { actorUserId = caller.subject,
            subjectUserId = cmd.targetUserId,
            sessionId = session.sessionId,
            reason = cmd.reason,
            ticketId = cmd.ticketId,
            clientIp = cmd.clientIp,
            occurredAt = ts
          }
    )
  pure (session, access)

-- | The inputs to the shared delegated-token core: who the token represents, who is acting, the
-- scopes it carries, and how long it lives. Everything policy — the scope\/freshness\/target
-- guards, the audit event — lives in the /caller/ ('startImpersonation' for impersonation,
-- 'Shomei.OAuth.TokenExchange.Workflow.exchangeToken' for on-behalf-of); this record is only the mint.
data DelegatedMint = DelegatedMint
  { -- | the token's @sub@
    subjectUserId :: !UserId,
    -- | the token's @act@
    actorUserId :: !UserId,
    -- | empty for impersonation; the narrowed set for service on-behalf-of
    scopes :: !(Set Scope),
    ttl :: !NominalDiffTime
  }
  deriving stock (Generic, Show)

-- | Mint a dedicated, __refresh-less__, short-lived delegated session and its signed access token:
-- a fresh session row whose @actor@ is 'actorUserId', and a token carrying both identities (@sub@ =
-- 'subjectUserId', @act@ = 'actorUserId') plus 'scopes'. No refresh token, no @LoginSucceeded@\/
-- @SessionStarted@ events — the delegated session cannot be silently renewed and dies at its TTL.
--
-- This is the single mint both delegation flows share, so the standards-based token-exchange grant
-- and the bespoke @\/auth\/impersonate@ endpoint cannot drift in session shape or claim contents.
-- The audit event is the caller's responsibility, because impersonation and on-behalf-of publish
-- different events.
mintDelegatedToken ::
  ( SessionStore :> es,
    TokenSigner :> es
  ) =>
  ShomeiConfig ->
  UTCTime ->
  DelegatedMint ->
  Eff es (Session, AccessToken)
mintDelegatedToken cfg ts mint = do
  let expires = addUTCTime mint.ttl ts
  session <-
    createSession
      NewSession
        { userId = mint.subjectUserId,
          createdAt = ts,
          expiresAt = expires,
          actor = Just mint.actorUserId,
          oauthClientId = Nothing,
          kind = DelegatedSession,
          grantedScopes = Set.empty
        }
  let claims =
        AuthClaims
          { subject = mint.subjectUserId,
            sessionId = session.sessionId,
            issuer = cfg.issuer,
            audience = cfg.audience,
            issuedAt = ts,
            expiresAt = expires,
            scopes = mint.scopes,
            roles = Set.empty,
            -- A delegated token carries negotiated scopes, not role-derived permissions (EP-9):
            -- it does not go through claims enrichment, so its permissions set is always empty.
            permissions = Set.empty,
            actor = Just mint.actorUserId,
            extraClaims = noExtraClaims
          }
  access <- signAccessToken claims
  pure (session, access)

-- | Stop impersonating: revoke the delegated session named by the presented token's
-- claims and audit the stop. The claims must carry an @act@ actor (i.e. be a delegated
-- token); an ordinary token is rejected with 'ImpersonationTargetInvalid'. Revoking the
-- session is sufficient to end it because the delegated session has no refresh token.
stopImpersonation ::
  ( SessionStore :> es,
    AuthEventPublisher :> es,
    Clock :> es
  ) =>
  AuthClaims ->
  Eff es (Either AuthError ())
stopImpersonation claims = runErrorNoCallStack do
  actorId <- maybe (throwError ImpersonationTargetInvalid) pure claims.actor
  ts <- now
  revokeSession claims.sessionId ts
  publishAuthEvent
    ( Event.ImpersonationStopped
        Event.ImpersonationStoppedData
          { actorUserId = actorId,
            subjectUserId = claims.subject,
            sessionId = claims.sessionId,
            occurredAt = ts
          }
    )
