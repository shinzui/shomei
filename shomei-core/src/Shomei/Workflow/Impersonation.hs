-- | The impersonation token-exchange workflow.
--
-- 'startImpersonation' mints a short-lived __delegated session__ for a target customer
-- on behalf of an authorized operator: a brand-new session row whose @actor@ is the
-- operator, a signed access token carrying both identities (@sub@ = customer, @act@ =
-- operator), and __no refresh token__ so the delegated session cannot be silently
-- renewed and dies at its TTL. 'stopImpersonation' revokes that session.
--
-- Unlike 'Shomei.Workflow.Session.issueSession', this workflow deliberately does NOT
-- create a refresh token and does NOT publish 'LoginSucceeded'/'SessionStarted'; it
-- publishes 'ImpersonationStarted'/'ImpersonationStopped' instead. Who-may-impersonate-whom
-- policy lives in the embedding service, not here (see the plan's Decision Log).
module Shomei.Workflow.Impersonation
  ( StartImpersonation (..),
    startImpersonation,
    stopImpersonation,
  )
where

import Data.Set qualified as Set
import Data.Time (addUTCTime)
import Effectful (Eff, (:>))
import Effectful.Error.Static (runErrorNoCallStack, throwError)
import Shomei.Config (ImpersonationConfig (..), ShomeiConfig (..))
import Shomei.Domain.Claims (AuthClaims (..), noExtraClaims)
import Shomei.Domain.Event qualified as Event
import Shomei.Domain.Session (NewSession (..), Session (..))
import Shomei.Domain.Token (AccessToken)
import Shomei.Domain.User (User (..), UserStatus (UserActive))
import Shomei.Effect.AuthEventPublisher (AuthEventPublisher, publishAuthEvent)
import Shomei.Effect.Clock (Clock, now)
import Shomei.Effect.SessionStore (SessionStore, createSession, revokeSession)
import Shomei.Effect.TokenSigner (TokenSigner, signAccessToken)
import Shomei.Effect.UserStore (UserStore, findUserById)
import Shomei.Error (AuthError (..))
import Shomei.Id (UserId)
import Shomei.Prelude

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
-- for 'targetUserId'. Enforces scope, freshness, self, and target-active checks; mints
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
  -- Self check: an operator may not impersonate themselves.
  when (cmd.targetUserId == caller.subject) (throwError ImpersonationTargetInvalid)
  -- Target check: the target must exist and be active.
  target <- maybe (throwError ImpersonationTargetInvalid) pure =<< findUserById cmd.targetUserId
  unless (target.status == UserActive) (throwError ImpersonationTargetInvalid)
  -- Mint a dedicated, refresh-less, short-lived delegated session.
  let expires = addUTCTime imp.impersonationSessionTTL ts
  session <-
    createSession
      NewSession
        { userId = cmd.targetUserId,
          createdAt = ts,
          expiresAt = expires,
          actor = Just caller.subject,
          oauthClientId = Nothing
        }
  let claims =
        AuthClaims
          { subject = cmd.targetUserId,
            sessionId = session.sessionId,
            issuer = cfg.issuer,
            audience = cfg.audience,
            issuedAt = ts,
            expiresAt = expires,
            scopes = Set.empty,
            roles = Set.empty,
            actor = Just caller.subject,
            extraClaims = noExtraClaims
          }
  access <- signAccessToken claims
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
