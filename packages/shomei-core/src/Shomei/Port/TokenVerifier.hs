{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE TypeFamilies #-}

{- | The token-verifier port: validating a signed 'AccessToken' back into 'AuthClaims'
(real JWT/JWKS verification in EP-4).
-}
module Shomei.Port.TokenVerifier (
    TokenVerifier (..),
    verifyAccessToken,
) where

import Effectful (Dispatch (..), DispatchOf, Eff, Effect, (:>))
import Effectful.Dispatch.Dynamic (send)

import Shomei.Domain.Claims (AuthClaims)
import Shomei.Domain.Token (AccessToken)
import Shomei.Error (TokenError)

data TokenVerifier :: Effect where
    VerifyAccessToken :: AccessToken -> TokenVerifier m (Either TokenError AuthClaims)

type instance DispatchOf TokenVerifier = Dynamic

verifyAccessToken :: (TokenVerifier :> es) => AccessToken -> Eff es (Either TokenError AuthClaims)
verifyAccessToken = send . VerifyAccessToken
