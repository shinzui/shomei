{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE TypeFamilies #-}

-- | The authorization-code port (EP-5): the @shomei_oauth_authorization_codes@ table between
-- @GET \/oauth\/authorize@ and the @authorization_code@ grant at @POST \/oauth\/token@.
--
-- A dedicated table rather than a reuse of the one-time-token stores or 'PendingCeremonyStore':
-- a code binds a client, a redirect URI, a PKCE challenge, a user, a scope set, a nonce, and an
-- auth time, none of which those single-purpose tables carry, and consumption must return all of
-- it atomically. The consume-once /discipline/ is copied from
-- 'Shomei.Passkey.Ceremony.Store.TakePendingCeremony'.
module Shomei.OAuth.AuthorizationCode.Store
  ( OAuthCodeStore (..),
    putAuthorizationCode,
    consumeAuthorizationCode,
    bindAuthorizationCodeSession,
    findConsumedAuthorizationCode,
    deleteExpiredAuthorizationCodes,
  )
where

import Effectful (Dispatch (..), DispatchOf, Eff, Effect, (:>))
import Effectful.Dispatch.Dynamic (send)
import Shomei.Id (SessionId)
import Shomei.OAuth.AuthorizationCode.Domain (AuthorizationCode, NewAuthorizationCode)
import Shomei.Prelude

data OAuthCodeStore :: Effect where
  PutAuthorizationCode :: NewAuthorizationCode -> OAuthCodeStore m ()
  -- | Redeem a code by its SHA-256 hex digest, atomically and at most once.
  --
  -- Returns the row only if it was unconsumed /and/ unexpired at the given time, and stamps
  -- @consumed_at@ in the same statement — so of two racing exchanges of one code, exactly one
  -- gets a 'Just'. A miss (unknown, already consumed, or expired) is 'Nothing', and the caller
  -- must answer @invalid_grant@ for all three without distinguishing them.
  ConsumeAuthorizationCode :: Text -> UTCTime -> OAuthCodeStore m (Maybe AuthorizationCode)
  -- | Attach the session minted by a successful exchange to its already-consumed code row.
  BindAuthorizationCodeSession :: Text -> SessionId -> OAuthCodeStore m ()
  -- | Find a still-live consumed row. Keeping this distinct from consume preserves the atomic
  --     one-winner operation while letting a replay find the first exchange's result.
  FindConsumedAuthorizationCode :: Text -> UTCTime -> OAuthCodeStore m (Maybe AuthorizationCode)
  -- | Delete codes that expired before the given time. Consumed rows are kept until they expire
  -- too, so a replay within the code's lifetime still finds a consumed row rather than nothing.
  DeleteExpiredAuthorizationCodes :: UTCTime -> OAuthCodeStore m ()

type instance DispatchOf OAuthCodeStore = Dynamic

putAuthorizationCode :: (OAuthCodeStore :> es) => NewAuthorizationCode -> Eff es ()
putAuthorizationCode = send . PutAuthorizationCode

consumeAuthorizationCode :: (OAuthCodeStore :> es) => Text -> UTCTime -> Eff es (Maybe AuthorizationCode)
consumeAuthorizationCode h t = send (ConsumeAuthorizationCode h t)

bindAuthorizationCodeSession :: (OAuthCodeStore :> es) => Text -> SessionId -> Eff es ()
bindAuthorizationCodeSession h sid = send (BindAuthorizationCodeSession h sid)

findConsumedAuthorizationCode :: (OAuthCodeStore :> es) => Text -> UTCTime -> Eff es (Maybe AuthorizationCode)
findConsumedAuthorizationCode h t = send (FindConsumedAuthorizationCode h t)

deleteExpiredAuthorizationCodes :: (OAuthCodeStore :> es) => UTCTime -> Eff es ()
deleteExpiredAuthorizationCodes = send . DeleteExpiredAuthorizationCodes
