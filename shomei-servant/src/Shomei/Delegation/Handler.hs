-- | Shared HTTP policy for credential-changing operations performed with a delegated token.
module Shomei.Delegation.Handler (denyUnderDelegation) where

import Shomei.Audit.Event.Domain qualified as Event
import Shomei.Audit.Publisher.Store (publishAuthEvent)
import Shomei.Authorization.Claims.Domain (AuthClaims (..))
import Shomei.Error (AuthError (ImpersonationActionBlocked))
import Shomei.Prelude
import Shomei.Servant.Application (ApplicationHandler, port, rejectAuth)
import Shomei.Servant.Auth (AuthUser (..))
import Shomei.Servant.Seam (Env)
import Shomei.Time.Store (now)

-- | Reject credential and administrative mutations when the token has an RFC 8693 actor.
denyUnderDelegation :: Env -> Text -> AuthUser -> ApplicationHandler ()
denyUnderDelegation env action user =
  case user.authClaims.actor of
    Nothing -> pure ()
    Just actorId -> do
      timestamp <- port env now
      port env $
        publishAuthEvent $
          Event.ImpersonationActionBlocked
            Event.ImpersonationActionBlockedData
              { actorUserId = actorId,
                subjectUserId = user.authUserId,
                sessionId = user.authSessionId,
                action = action,
                occurredAt = timestamp
              }
      rejectAuth ImpersonationActionBlocked
