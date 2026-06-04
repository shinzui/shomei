{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE TypeFamilies #-}

{- | The refresh-token-store port: persisting and rotating refresh tokens, including the
family-revocation operations used by reuse detection.
-}
module Shomei.Effect.RefreshTokenStore (
    RefreshTokenStore (..),
    createRefreshToken,
    findRefreshTokenByHash,
    markRefreshTokenUsed,
    revokeRefreshTokenFamily,
    revokeSessionRefreshTokens,
) where

import Shomei.Prelude

import Effectful (Dispatch (..), DispatchOf, Eff, Effect, (:>))
import Effectful.Dispatch.Dynamic (send)

import Shomei.Domain.RefreshToken (NewRefreshToken, PersistedRefreshToken, RefreshTokenHash)
import Shomei.Id (RefreshTokenId, SessionId)

data RefreshTokenStore :: Effect where
    CreateRefreshToken :: NewRefreshToken -> RefreshTokenStore m PersistedRefreshToken
    FindRefreshTokenByHash :: RefreshTokenHash -> RefreshTokenStore m (Maybe PersistedRefreshToken)
    MarkRefreshTokenUsed :: RefreshTokenId -> UTCTime -> RefreshTokenStore m ()
    RevokeRefreshTokenFamily :: RefreshTokenId -> UTCTime -> RefreshTokenStore m ()
    RevokeSessionRefreshTokens :: SessionId -> UTCTime -> RefreshTokenStore m ()

type instance DispatchOf RefreshTokenStore = Dynamic

createRefreshToken :: (RefreshTokenStore :> es) => NewRefreshToken -> Eff es PersistedRefreshToken
createRefreshToken = send . CreateRefreshToken

findRefreshTokenByHash :: (RefreshTokenStore :> es) => RefreshTokenHash -> Eff es (Maybe PersistedRefreshToken)
findRefreshTokenByHash = send . FindRefreshTokenByHash

markRefreshTokenUsed :: (RefreshTokenStore :> es) => RefreshTokenId -> UTCTime -> Eff es ()
markRefreshTokenUsed i t = send (MarkRefreshTokenUsed i t)

revokeRefreshTokenFamily :: (RefreshTokenStore :> es) => RefreshTokenId -> UTCTime -> Eff es ()
revokeRefreshTokenFamily i t = send (RevokeRefreshTokenFamily i t)

revokeSessionRefreshTokens :: (RefreshTokenStore :> es) => SessionId -> UTCTime -> Eff es ()
revokeSessionRefreshTokens s t = send (RevokeSessionRefreshTokens s t)
