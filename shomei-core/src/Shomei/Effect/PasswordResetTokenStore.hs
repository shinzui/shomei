{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE TypeFamilies #-}

-- | Store effect for password-reset tokens.
module Shomei.Effect.PasswordResetTokenStore
  ( PasswordResetTokenStore (..),
    createPasswordResetToken,
    findPasswordResetTokenByHash,
    markPasswordResetTokenConsumed,
    revokeUserPasswordResetTokens,
  )
where

import Effectful (Dispatch (Dynamic), DispatchOf, Eff, Effect, (:>))
import Effectful.Dispatch.Dynamic (send)
import Shomei.Domain.OneTimeToken (OneTimeTokenHash)
import Shomei.Domain.PasswordResetToken (NewPasswordResetToken, PersistedPasswordResetToken)
import Shomei.Id (PasswordResetTokenId, UserId)
import Shomei.Prelude

data PasswordResetTokenStore :: Effect where
  CreatePasswordResetToken :: NewPasswordResetToken -> PasswordResetTokenStore m PersistedPasswordResetToken
  FindPasswordResetTokenByHash :: OneTimeTokenHash -> PasswordResetTokenStore m (Maybe PersistedPasswordResetToken)
  -- | Transition a token @active → consumed@ as one atomic compare-and-swap. 'True' means
  -- this call performed the transition; 'False' means it was already spent or revoked.
  MarkPasswordResetTokenConsumed :: PasswordResetTokenId -> UTCTime -> PasswordResetTokenStore m Bool
  RevokeUserPasswordResetTokens :: UserId -> UTCTime -> PasswordResetTokenStore m ()

type instance DispatchOf PasswordResetTokenStore = Dynamic

createPasswordResetToken :: (PasswordResetTokenStore :> es) => NewPasswordResetToken -> Eff es PersistedPasswordResetToken
createPasswordResetToken = send . CreatePasswordResetToken

findPasswordResetTokenByHash :: (PasswordResetTokenStore :> es) => OneTimeTokenHash -> Eff es (Maybe PersistedPasswordResetToken)
findPasswordResetTokenByHash = send . FindPasswordResetTokenByHash

markPasswordResetTokenConsumed :: (PasswordResetTokenStore :> es) => PasswordResetTokenId -> UTCTime -> Eff es Bool
markPasswordResetTokenConsumed i t = send (MarkPasswordResetTokenConsumed i t)

revokeUserPasswordResetTokens :: (PasswordResetTokenStore :> es) => UserId -> UTCTime -> Eff es ()
revokeUserPasswordResetTokens i t = send (RevokeUserPasswordResetTokens i t)
