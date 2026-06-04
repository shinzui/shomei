{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE TypeFamilies #-}

{- | The token-signer port: turning 'AuthClaims' into a signed 'AccessToken' (a real JWT
in EP-4).
-}
module Shomei.Effect.TokenSigner (
    TokenSigner (..),
    signAccessToken,
) where

import Effectful (Dispatch (..), DispatchOf, Eff, Effect, (:>))
import Effectful.Dispatch.Dynamic (send)

import Shomei.Domain.Claims (AuthClaims)
import Shomei.Domain.Token (AccessToken)

data TokenSigner :: Effect where
    SignAccessToken :: AuthClaims -> TokenSigner m AccessToken

type instance DispatchOf TokenSigner = Dynamic

signAccessToken :: (TokenSigner :> es) => AuthClaims -> Eff es AccessToken
signAccessToken = send . SignAccessToken
