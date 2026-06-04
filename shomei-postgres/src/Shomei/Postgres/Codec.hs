{- | Pure conversions between Shōmei domain values and their stored text forms, shared by
the PostgreSQL port interpreters. Status enums are stored as @text@; the
'Shomei.Domain.Email.Email' smart constructor is reused to rebuild an 'Email' from a
(trusted, already-normalized) database value.
-}
module Shomei.Postgres.Codec (
    userStatusToText,
    userStatusFromText,
    sessionStatusToText,
    sessionStatusFromText,
    refreshTokenStatusToText,
    refreshTokenStatusFromText,
    signingKeyStatusToText,
    signingKeyStatusFromText,
    emailFromDb,
    tshow,
) where

import Shomei.Prelude

import Data.Text qualified as Text
import Shomei.Domain.Email (Email, mkEmail)
import Shomei.Domain.RefreshToken (RefreshTokenStatus (..))
import Shomei.Domain.Session (SessionStatus (..))
import Shomei.Domain.SigningKey (SigningKeyStatus (..))
import Shomei.Domain.User (UserStatus (..))

tshow :: (Show a) => a -> Text
tshow = Text.pack . show

userStatusToText :: UserStatus -> Text
userStatusToText = \case
    UserActive -> "active"
    UserSuspended -> "suspended"
    UserDeleted -> "deleted"

userStatusFromText :: Text -> Either Text UserStatus
userStatusFromText = \case
    "active" -> Right UserActive
    "suspended" -> Right UserSuspended
    "deleted" -> Right UserDeleted
    t -> Left ("unknown user status: " <> t)

sessionStatusToText :: SessionStatus -> Text
sessionStatusToText = \case
    SessionActive -> "active"
    SessionRevoked -> "revoked"
    SessionExpired -> "expired"

sessionStatusFromText :: Text -> Either Text SessionStatus
sessionStatusFromText = \case
    "active" -> Right SessionActive
    "revoked" -> Right SessionRevoked
    "expired" -> Right SessionExpired
    t -> Left ("unknown session status: " <> t)

refreshTokenStatusToText :: RefreshTokenStatus -> Text
refreshTokenStatusToText = \case
    RefreshTokenActive -> "active"
    RefreshTokenUsed -> "used"
    RefreshTokenRevoked -> "revoked"
    RefreshTokenExpired -> "expired"

refreshTokenStatusFromText :: Text -> Either Text RefreshTokenStatus
refreshTokenStatusFromText = \case
    "active" -> Right RefreshTokenActive
    "used" -> Right RefreshTokenUsed
    "revoked" -> Right RefreshTokenRevoked
    "expired" -> Right RefreshTokenExpired
    t -> Left ("unknown refresh-token status: " <> t)

signingKeyStatusToText :: SigningKeyStatus -> Text
signingKeyStatusToText = \case
    KeyPending -> "pending"
    KeyActive -> "active"
    KeyRetired -> "retired"
    KeyRevoked -> "revoked"

signingKeyStatusFromText :: Text -> Either Text SigningKeyStatus
signingKeyStatusFromText = \case
    "pending" -> Right KeyPending
    "active" -> Right KeyActive
    "retired" -> Right KeyRetired
    "revoked" -> Right KeyRevoked
    t -> Left ("unknown signing-key status: " <> t)

{- | Rebuild an 'Email' from a stored value. The column only ever holds emails that were
already normalized through 'mkEmail' on the way in, so this should never fail; a 'Left'
here signals a corrupt row.
-}
emailFromDb :: Text -> Either Text Email
emailFromDb t = case mkEmail t of
    Right e -> Right e
    Left _ -> Left ("invalid email in database: " <> t)
