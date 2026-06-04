{-# LANGUAGE DataKinds #-}
{-# LANGUAGE UndecidableInstances #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}

{- | Typed, self-describing identifiers for Shōmei domain entities.

Each identifier is an 'mmzk-typeid' 'KindID' — a UUIDv7 with a type-level prefix
(@user_…@, @session_…@, @refresh_token_…@, @credential_…@). Because the prefix is a
type-level 'Symbol', 'UserId' and 'SessionId' are distinct types that cannot be
confused. The underlying UUID is stored as a native @uuid@ column in PostgreSQL
(EP-3) via 'userIdToUUID' / 'userIdFromUUID' (= 'getUUID' / 'decorateKindID').

The orphan 'FromHttpApiData' / 'ToHttpApiData' instances are required by EP-5's
Servant @Capture@s; @mmzk-typeid@ ships JSON instances but not these, and
@http-api-data@ is a pure dependency so it is acceptable in the transport-agnostic
core.
-}
module Shomei.Id (
    UserId,
    SessionId,
    RefreshTokenId,
    VerificationTokenId,
    PasswordResetTokenId,
    CredentialId,
    genUserId,
    genSessionId,
    genRefreshTokenId,
    genVerificationTokenId,
    genPasswordResetTokenId,
    genCredentialId,
    idText,
    parseId,
    userIdToUUID,
    userIdFromUUID,
    sessionIdToUUID,
    sessionIdFromUUID,
    refreshTokenIdToUUID,
    refreshTokenIdFromUUID,
    verificationTokenIdToUUID,
    verificationTokenIdFromUUID,
    passwordResetTokenIdToUUID,
    passwordResetTokenIdFromUUID,
    credentialIdToUUID,
    credentialIdFromUUID,
) where

import Shomei.Prelude

import Data.KindID.Class (ToPrefix (..), ValidPrefix)
import Data.KindID.V7 (KindID, decorateKindID, getUUID)
import Data.KindID.V7 qualified as KindID
import Data.Text qualified as Text
import Data.UUID (UUID)
import Web.HttpApiData (FromHttpApiData (..), ToHttpApiData (..))

type UserId = KindID "user"

type SessionId = KindID "session"

type RefreshTokenId = KindID "refresh_token"

type VerificationTokenId = KindID "verification_token"

type PasswordResetTokenId = KindID "password_reset_token"

type CredentialId = KindID "credential"

genUserId :: (MonadIO m) => m UserId
genUserId = KindID.genKindID @"user"

genSessionId :: (MonadIO m) => m SessionId
genSessionId = KindID.genKindID @"session"

genRefreshTokenId :: (MonadIO m) => m RefreshTokenId
genRefreshTokenId = KindID.genKindID @"refresh_token"

genVerificationTokenId :: (MonadIO m) => m VerificationTokenId
genVerificationTokenId = KindID.genKindID @"verification_token"

genPasswordResetTokenId :: (MonadIO m) => m PasswordResetTokenId
genPasswordResetTokenId = KindID.genKindID @"password_reset_token"

genCredentialId :: (MonadIO m) => m CredentialId
genCredentialId = KindID.genKindID @"credential"

idText :: (ToPrefix p, ValidPrefix (PrefixSymbol p)) => KindID p -> Text
idText = KindID.toText

parseId :: forall p. (ToPrefix p, ValidPrefix (PrefixSymbol p)) => Text -> Either Text (KindID p)
parseId t = case KindID.parseText @p t of
    Left e -> Left (Text.pack (show e))
    Right k -> Right k

userIdToUUID :: UserId -> UUID
userIdToUUID = getUUID

userIdFromUUID :: UUID -> UserId
userIdFromUUID = decorateKindID

sessionIdToUUID :: SessionId -> UUID
sessionIdToUUID = getUUID

sessionIdFromUUID :: UUID -> SessionId
sessionIdFromUUID = decorateKindID

refreshTokenIdToUUID :: RefreshTokenId -> UUID
refreshTokenIdToUUID = getUUID

refreshTokenIdFromUUID :: UUID -> RefreshTokenId
refreshTokenIdFromUUID = decorateKindID

verificationTokenIdToUUID :: VerificationTokenId -> UUID
verificationTokenIdToUUID = getUUID

verificationTokenIdFromUUID :: UUID -> VerificationTokenId
verificationTokenIdFromUUID = decorateKindID

passwordResetTokenIdToUUID :: PasswordResetTokenId -> UUID
passwordResetTokenIdToUUID = getUUID

passwordResetTokenIdFromUUID :: UUID -> PasswordResetTokenId
passwordResetTokenIdFromUUID = decorateKindID

credentialIdToUUID :: CredentialId -> UUID
credentialIdToUUID = getUUID

credentialIdFromUUID :: UUID -> CredentialId
credentialIdFromUUID = decorateKindID

instance (ToPrefix p, ValidPrefix (PrefixSymbol p)) => FromHttpApiData (KindID p) where
    parseUrlPiece = parseId

instance (ToPrefix p, ValidPrefix (PrefixSymbol p)) => ToHttpApiData (KindID p) where
    toUrlPiece = idText
