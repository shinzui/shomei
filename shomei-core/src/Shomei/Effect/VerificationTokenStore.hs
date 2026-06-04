{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE TypeFamilies #-}

-- | Store effect for email-verification tokens.
module Shomei.Effect.VerificationTokenStore (
    VerificationTokenStore (..),
    createVerificationToken,
    findVerificationTokenByHash,
    markVerificationTokenConsumed,
    revokeUserVerificationTokens,
) where

import Shomei.Prelude

import Effectful (Dispatch (Dynamic), DispatchOf, Eff, Effect, (:>))
import Effectful.Dispatch.Dynamic (send)

import Shomei.Domain.OneTimeToken (OneTimeTokenHash)
import Shomei.Domain.VerificationToken (NewVerificationToken, PersistedVerificationToken)
import Shomei.Id (UserId, VerificationTokenId)

data VerificationTokenStore :: Effect where
    CreateVerificationToken :: NewVerificationToken -> VerificationTokenStore m PersistedVerificationToken
    FindVerificationTokenByHash :: OneTimeTokenHash -> VerificationTokenStore m (Maybe PersistedVerificationToken)
    MarkVerificationTokenConsumed :: VerificationTokenId -> UTCTime -> VerificationTokenStore m ()
    RevokeUserVerificationTokens :: UserId -> UTCTime -> VerificationTokenStore m ()

type instance DispatchOf VerificationTokenStore = Dynamic

createVerificationToken :: (VerificationTokenStore :> es) => NewVerificationToken -> Eff es PersistedVerificationToken
createVerificationToken = send . CreateVerificationToken

findVerificationTokenByHash :: (VerificationTokenStore :> es) => OneTimeTokenHash -> Eff es (Maybe PersistedVerificationToken)
findVerificationTokenByHash = send . FindVerificationTokenByHash

markVerificationTokenConsumed :: (VerificationTokenStore :> es) => VerificationTokenId -> UTCTime -> Eff es ()
markVerificationTokenConsumed i t = send (MarkVerificationTokenConsumed i t)

revokeUserVerificationTokens :: (VerificationTokenStore :> es) => UserId -> UTCTime -> Eff es ()
revokeUserVerificationTokens i t = send (RevokeUserVerificationTokens i t)
