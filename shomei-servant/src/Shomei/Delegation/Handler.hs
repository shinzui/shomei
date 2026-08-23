-- | Shared HTTP policy for credential-changing operations performed with a delegated token.
module Shomei.Delegation.Handler (denyUnderDelegation) where

import Servant (Handler, throwError)
import Shomei.Audit.Event.Domain qualified as Event
import Shomei.Audit.Publisher.Store (publishAuthEvent)
import Shomei.Authorization.Claims.Domain (AuthClaims (..))
import Shomei.Error (AuthError (ImpersonationActionBlocked))
import Shomei.Prelude
import Shomei.Servant.Auth (AuthUser (..))
import Shomei.Servant.Error (authErrorToServerError)
import Shomei.Servant.Seam (Env, runPort)
import Shomei.Time.Store (now)

-- | Reject credential and administrative mutations when the token has an RFC 8693 actor.
denyUnderDelegation :: Env -> Text -> AuthUser -> Handler ()
denyUnderDelegation env action user =
  case user.authClaims.actor of
    Nothing -> pure ()
    Just actorId -> do
      timestamp <- runPort env now
      runPort env $
        publishAuthEvent $
          Event.ImpersonationActionBlocked
            Event.ImpersonationActionBlockedData
              { actorUserId = actorId,
                subjectUserId = user.authUserId,
                sessionId = user.authSessionId,
                action = action,
                occurredAt = timestamp
              }
      throwError (authErrorToServerError ImpersonationActionBlocked)
