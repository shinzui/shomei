{-# LANGUAGE DataKinds #-}

-- | Passkey (WebAuthn credential) domain types (MasterPlan 3, EP-1).
--
-- These are pure data with no @webauthn@ dependency — the heavy library lives only in
-- the @shomei-webauthn@ package, and the 'Shomei.Effect.WebAuthnCeremony' port crosses
-- the package boundary using aeson 'Data.Aeson.Value' plus the types defined here. Later
-- plans persist them: EP-2 stores 'PasskeyCredential' and 'PendingCeremony', EP-3's
-- enrollment workflow produces 'NewPasskeyCredential', and EP-4's login reads them back.
--
-- The three @ByteString@ newtypes ('WebAuthnCredentialId', 'UserHandle',
-- 'PublicKeyBytes') are opaque authenticator bytes. aeson has no default 'ByteString'
-- JSON instance, so each carries hand-written instances encoding the bytes as
-- base64url-without-padding 'Text' via 'b64urlEncode' / 'b64urlDecode' (the same
-- encoding the rest of the codebase uses). These JSON instances matter because the
-- deterministic fake ceremony interpreter and the EP-3/EP-4 workflows move these values
-- around as JSON; PostgreSQL persistence (EP-2) uses native @bytea@, not JSON.
module Shomei.Domain.Passkey
  ( WebAuthnCredentialId (..),
    UserHandle (..),
    PublicKeyBytes (..),
    SignatureCounter (..),
    NewPasskeyCredential (..),
    PasskeyCredential (..),
    CeremonyKind (..),
    PendingCeremony (..),

    -- * base64url helpers (reused by EP-2..EP-4)
    b64urlEncode,
    b64urlDecode,
  )
where

import Data.Base64.Types (extractBase64)
import Data.ByteString (ByteString)
import Data.ByteString.Base64.URL qualified as B64U
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TE
import Data.Word (Word32)
import Shomei.Id (CeremonyId, PasskeyId, UserId)
import Shomei.Prelude

-- | base64url-without-padding encode strict bytes to text.
b64urlEncode :: ByteString -> Text
b64urlEncode = extractBase64 . B64U.encodeBase64Unpadded

-- | Decode base64url-without-padding text back to strict bytes.
b64urlDecode :: Text -> Either String ByteString
b64urlDecode = either (Left . Text.unpack) Right . B64U.decodeBase64UnpaddedUntyped . TE.encodeUtf8

-- | The authenticator-assigned credential id (stored as bytea). Opaque bytes.
newtype WebAuthnCredentialId = WebAuthnCredentialId ByteString
  deriving stock (Generic, Eq, Show)

instance ToJSON WebAuthnCredentialId where
  toJSON (WebAuthnCredentialId bs) = toJSON (b64urlEncode bs)

instance FromJSON WebAuthnCredentialId where
  parseJSON v = WebAuthnCredentialId <$> (parseJSON v >>= either fail pure . b64urlDecode)

-- | The RP-assigned per-user handle (random bytes the authenticator returns at login).
newtype UserHandle = UserHandle ByteString
  deriving stock (Generic, Eq, Show)

instance ToJSON UserHandle where
  toJSON (UserHandle bs) = toJSON (b64urlEncode bs)

instance FromJSON UserHandle where
  parseJSON v = UserHandle <$> (parseJSON v >>= either fail pure . b64urlDecode)

-- | The COSE public-key bytes exactly as the webauthn library serializes them.
newtype PublicKeyBytes = PublicKeyBytes ByteString
  deriving stock (Generic, Eq, Show)

instance ToJSON PublicKeyBytes where
  toJSON (PublicKeyBytes bs) = toJSON (b64urlEncode bs)

instance FromJSON PublicKeyBytes where
  parseJSON v = PublicKeyBytes <$> (parseJSON v >>= either fail pure . b64urlDecode)

-- | The authenticator's signature counter (clone-detection aid).
newtype SignatureCounter = SignatureCounter Word32
  deriving stock (Generic, Eq, Show)
  deriving newtype (FromJSON, ToJSON)

-- | A freshly verified registration, ready for EP-2's store to persist.
data NewPasskeyCredential = NewPasskeyCredential
  { userId :: !UserId,
    credentialId :: !WebAuthnCredentialId,
    userHandle :: !UserHandle,
    publicKey :: !PublicKeyBytes,
    signCounter :: !SignatureCounter,
    transports :: ![Text],
    label :: !(Maybe Text),
    createdAt :: !UTCTime
  }
  deriving stock (Generic, Eq, Show)
  deriving anyclass (FromJSON, ToJSON)

-- | A persisted passkey (EP-2 reads/writes this; EP-1 only defines it).
data PasskeyCredential = PasskeyCredential
  { passkeyId :: !PasskeyId,
    userId :: !UserId,
    credentialId :: !WebAuthnCredentialId,
    userHandle :: !UserHandle,
    publicKey :: !PublicKeyBytes,
    signCounter :: !SignatureCounter,
    transports :: ![Text],
    label :: !(Maybe Text),
    createdAt :: !UTCTime,
    lastUsedAt :: !(Maybe UTCTime)
  }
  deriving stock (Generic, Eq, Show)
  deriving anyclass (FromJSON, ToJSON)

-- | Which ceremony a pending blob belongs to.
data CeremonyKind = RegistrationCeremony | AuthenticationCeremony
  deriving stock (Generic, Eq, Show)
  deriving anyclass (FromJSON, ToJSON)

-- | The short-lived challenge/options state (EP-1 defines; EP-2 persists).
data PendingCeremony = PendingCeremony
  { ceremonyId :: !CeremonyId,
    userId :: !(Maybe UserId),
    kind :: !CeremonyKind,
    optionsBlob :: !ByteString,
    createdAt :: !UTCTime,
    expiresAt :: !UTCTime
  }
  deriving stock (Generic, Eq, Show)
