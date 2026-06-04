{- | Access tokens and the token pair returned by the auth workflows.

'AccessToken' is the signed JWT (produced by the 'Shomei.Port.TokenSigner' port,
really signed by EP-4). 'TokenPair' bundles it with the opaque refresh token and the
access-token lifetime.
-}
module Shomei.Domain.Token (
    AccessToken (..),
    TokenPair (..),
) where

import Shomei.Prelude

import Data.Time (NominalDiffTime)
import Shomei.Domain.RefreshToken (RefreshToken)

newtype AccessToken = AccessToken Text
    deriving stock (Generic)
    deriving newtype (Eq, Show, FromJSON, ToJSON)

data TokenPair = TokenPair
    { accessToken :: !AccessToken
    , refreshToken :: !RefreshToken
    , expiresIn :: !NominalDiffTime
    }
    deriving stock (Generic, Eq, Show)
    deriving anyclass (FromJSON, ToJSON)
