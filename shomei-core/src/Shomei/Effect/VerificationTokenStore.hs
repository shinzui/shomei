{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE TypeFamilies #-}

-- | Store effect for email-verification tokens.
module Shomei.Effect.VerificationTokenStore
  ( VerificationTokenStore (..),
    createVerificationToken,
    findVerificationTokenByHash,
    markVerificationTokenConsumed,
    revokeUserVerificationTokens,
  )
where

import Effectful (Dispatch (Dynamic), DispatchOf, Eff, Effect, (:>))
import Effectful.Dispatch.Dynamic (send)
import Shomei.Domain.OneTimeToken (OneTimeTokenHash)
import Shomei.Domain.VerificationToken (NewVerificationToken, PersistedVerificationToken)
import Shomei.Id (UserId, VerificationTokenId)
import Shomei.Prelude

data VerificationTokenStore :: Effect where
  CreateVerificationToken :: NewVerificationToken -> VerificationTokenStore m PersistedVerificationToken
  FindVerificationTokenByHash :: OneTimeTokenHash -> VerificationTokenStore m (Maybe PersistedVerificationToken)
  -- | Transition a token @active → consumed@ as one atomic compare-and-swap. 'True' means
  -- this call performed the transition; 'False' means it was already spent or revoked.
  MarkVerificationTokenConsumed :: VerificationTokenId -> UTCTime -> VerificationTokenStore m Bool
  RevokeUserVerificationTokens :: UserId -> UTCTime -> VerificationTokenStore m ()

type instance DispatchOf VerificationTokenStore = Dynamic

createVerificationToken :: (VerificationTokenStore :> es) => NewVerificationToken -> Eff es PersistedVerificationToken
createVerificationToken = send . CreateVerificationToken

findVerificationTokenByHash :: (VerificationTokenStore :> es) => OneTimeTokenHash -> Eff es (Maybe PersistedVerificationToken)
findVerificationTokenByHash = send . FindVerificationTokenByHash

markVerificationTokenConsumed :: (VerificationTokenStore :> es) => VerificationTokenId -> UTCTime -> Eff es Bool
markVerificationTokenConsumed i t = send (MarkVerificationTokenConsumed i t)

revokeUserVerificationTokens :: (VerificationTokenStore :> es) => UserId -> UTCTime -> Eff es ()
revokeUserVerificationTokens i t = send (RevokeUserVerificationTokens i t)
