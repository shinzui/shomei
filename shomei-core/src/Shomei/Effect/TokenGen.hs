{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE TypeFamilies #-}

-- | The opaque-token-generation port: minting a fresh random refresh token and hashing
-- a refresh token for storage. Production (EP-3/EP-6) uses crypton @getRandomBytes 32@
-- base64url-encoded plus SHA-256; the test interpreter is deterministic.
module Shomei.Effect.TokenGen
  ( TokenGen (..),
    generateOpaqueToken,
    hashRefreshToken,
    generateRandomBytes,
  )
where

import Data.ByteString (ByteString)
import Effectful (Dispatch (..), DispatchOf, Eff, Effect, (:>))
import Effectful.Dispatch.Dynamic (send)
import Shomei.Domain.RefreshToken (RefreshToken, RefreshTokenHash)

data TokenGen :: Effect where
  GenerateOpaqueToken :: TokenGen m RefreshToken
  HashRefreshToken :: RefreshToken -> TokenGen m RefreshTokenHash
  -- | @n@ cryptographically random bytes (EP-7: TOTP secrets and recovery codes). The test
  -- interpreter is deterministic.
  GenerateRandomBytes :: Int -> TokenGen m ByteString

type instance DispatchOf TokenGen = Dynamic

generateOpaqueToken :: (TokenGen :> es) => Eff es RefreshToken
generateOpaqueToken = send GenerateOpaqueToken

hashRefreshToken :: (TokenGen :> es) => RefreshToken -> Eff es RefreshTokenHash
hashRefreshToken = send . HashRefreshToken

generateRandomBytes :: (TokenGen :> es) => Int -> Eff es ByteString
generateRandomBytes = send . GenerateRandomBytes
