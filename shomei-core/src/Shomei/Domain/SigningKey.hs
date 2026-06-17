{- | The storage-agnostic signing-key record that crosses the
'Shomei.Effect.SigningKeyStore' port (IP-4).

To keep @shomei-core@ (and @shomei-postgres@) free of any @jose@ dependency, key
material crosses the port as opaque 'Text' (JWK JSON). Only @shomei-jwt@ (EP-4)
converts a 'StoredSigningKey' to/from a @jose@ @JWK@.
-}
module Shomei.Domain.SigningKey (
    SigningKeyStatus (..),
    SigningAlgorithm (..),
    signingAlgorithmToText,
    signingAlgorithmFromText,
    StoredSigningKey (..),
) where

import Shomei.Prelude

import Data.Text qualified as Text

data SigningKeyStatus = KeyPending | KeyActive | KeyRetired | KeyRevoked
    deriving stock (Generic, Eq, Show)
    deriving anyclass (FromJSON, ToJSON)

{- | The JWT signing algorithm a key uses. A closed enum kept in @shomei-core@ so
the in-memory decision is type-safe; the storage representation
('StoredSigningKey.algorithm') and the config stay 'Text', and only @shomei-jwt@
maps this enum to a @jose@ @Alg@. @ES256@ is ECDSA over P-256/SHA-256 (the
default); @RS256@ is RSASSA-PKCS1-v1_5 with SHA-256.
-}
data SigningAlgorithm = ES256 | RS256
    deriving stock (Generic, Eq, Show)
    deriving anyclass (FromJSON, ToJSON)

signingAlgorithmToText :: SigningAlgorithm -> Text
signingAlgorithmToText ES256 = "ES256"
signingAlgorithmToText RS256 = "RS256"

{- | Parse the stored algorithm text. Unknown values are an error rather than a
silent default, so a corrupt/forward-incompatible key is caught loudly.
-}
signingAlgorithmFromText :: Text -> Either Text SigningAlgorithm
signingAlgorithmFromText t = case Text.strip t of
    "ES256" -> Right ES256
    "RS256" -> Right RS256
    other -> Left ("unknown signing algorithm: " <> other)

data StoredSigningKey = StoredSigningKey
    { keyId :: !Text
    -- ^ the @kid@
    , algorithm :: !Text
    -- ^ e.g. @"ES256"@
    , publicKeyJwk :: !Text
    -- ^ opaque JWK JSON; core never imports jose
    , privateKeyJwk :: !Text
    -- ^ opaque JWK JSON
    , status :: !SigningKeyStatus
    , createdAt :: !UTCTime
    , activatedAt :: !(Maybe UTCTime)
    , retiredAt :: !(Maybe UTCTime)
    }
    deriving stock (Generic, Eq, Show)
    deriving anyclass (FromJSON, ToJSON)
