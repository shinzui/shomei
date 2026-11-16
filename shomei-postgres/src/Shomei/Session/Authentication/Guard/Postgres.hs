-- | Acquire the owning user first; all recovery-sensitive writers share this lock order.
module Shomei.Session.Authentication.Guard.Postgres (checkAuthentication, lockAuthenticationUser, lockUserStmt) where

import Contravariant.Extras (contrazip3)
import Data.Functor.Contravariant (contramap)
import Data.Int (Int64)
import Data.UUID (UUID)
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Statement (Statement, preparable)
import Shomei.Error (AuthError (..))
import Shomei.Id (UserId, passkeyIdToUUID, sessionIdToUUID, userIdToUUID)
import Shomei.Persistence.Transaction.Postgres qualified as Tx
import Shomei.Prelude
import Shomei.Session.Authentication.Guard (AuthenticationGuard (..))

lockUserStmt :: Statement UUID (Maybe (Text, Int64))
lockUserStmt =
  preparable
    "SELECT status, authentication_generation FROM shomei.shomei_users WHERE user_id = $1 FOR UPDATE"
    (E.param (E.nonNullable E.uuid))
    (D.rowMaybe ((,) <$> D.column (D.nonNullable D.text) <*> D.column (D.nonNullable D.int8)))

lockAuthenticationUser :: UserId -> Tx.Transaction (Maybe (Text, Int64))
lockAuthenticationUser uid = Tx.statement (userIdToUUID uid) lockUserStmt

checkAuthentication :: UserId -> AuthenticationGuard -> UTCTime -> Tx.Transaction (Either AuthError ())
checkAuthentication uid proofState ts = do
  user <- lockAuthenticationUser uid
  case user of
    Just ("active", generation) | generation == proofState.generation -> do
      sessionOk <- case proofState.initiatingSession of
        Nothing -> pure True
        Just sid -> Tx.statement (sessionIdToUUID sid, userIdToUUID uid, ts) liveSessionStmt
      credentialOk <- case proofState.assertedPasskey of
        Nothing -> pure True
        Just pid -> Tx.statement (passkeyIdToUUID pid, userIdToUUID uid) credentialStmt
      pure (if sessionOk && credentialOk then Right () else Left StaleAuthentication)
    _ -> pure (Left StaleAuthentication)

liveSessionStmt :: Statement (UUID, UUID, UTCTime) Bool
liveSessionStmt =
  preparable
    "SELECT session_id FROM shomei.shomei_sessions WHERE session_id = $1 AND user_id = $2 AND status = 'active' AND expires_at > $3 FOR SHARE"
    (contrazip3 (E.param (E.nonNullable E.uuid)) (E.param (E.nonNullable E.uuid)) (E.param (E.nonNullable E.timestamptz)))
    (isJust <$> D.rowMaybe (D.column (D.nonNullable D.uuid)))

credentialStmt :: Statement (UUID, UUID) Bool
credentialStmt =
  preparable
    "SELECT passkey_id FROM shomei.shomei_webauthn_credentials WHERE passkey_id = $1 AND user_id = $2 FOR SHARE"
    (contramap fst (E.param (E.nonNullable E.uuid)) <> contramap snd (E.param (E.nonNullable E.uuid)))
    (isJust <$> D.rowMaybe (D.column (D.nonNullable D.uuid)))
