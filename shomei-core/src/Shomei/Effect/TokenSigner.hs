{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE TypeFamilies #-}

-- | The token-signer port: turning 'AuthClaims' into a signed 'AccessToken', and
-- 'IdTokenClaims' into a signed 'IdToken' (both real JWTs in @shomei-jwt@).
--
-- ID-token signing is an operation here rather than a direct @jose@ call from the HTTP layer,
-- because every workflow-visible signing capability in this repo crosses this port: that is what
-- keeps the in-memory test fake able to stand in for the real signer, and what means an OIDC ID
-- token is signed with the same active key and @kid@ as an access token, with zero new JWKS or
-- key-rotation work.
module Shomei.Effect.TokenSigner
  ( TokenSigner (..),
    signAccessToken,
    signIdToken,
  )
where

import Effectful (Dispatch (..), DispatchOf, Eff, Effect, (:>))
import Effectful.Dispatch.Dynamic (send)
import Shomei.Domain.Claims (AuthClaims)
import Shomei.Domain.IdTokenClaims (IdToken, IdTokenClaims)
import Shomei.Domain.Token (AccessToken)

data TokenSigner :: Effect where
  SignAccessToken :: AuthClaims -> TokenSigner m AccessToken
  -- | EP-5. Signed with the same active key and @kid@ as an access token, so the ID token
  -- verifies against the same published JWKS document.
  SignIdToken :: IdTokenClaims -> TokenSigner m IdToken

type instance DispatchOf TokenSigner = Dynamic

signAccessToken :: (TokenSigner :> es) => AuthClaims -> Eff es AccessToken
signAccessToken = send . SignAccessToken

signIdToken :: (TokenSigner :> es) => IdTokenClaims -> Eff es IdToken
signIdToken = send . SignIdToken
