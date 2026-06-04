{- | The storage-agnostic signing-key record that crosses the
'Shomei.Effect.SigningKeyStore' port (IP-4).

To keep @shomei-core@ (and @shomei-postgres@) free of any @jose@ dependency, key
material crosses the port as opaque 'Text' (JWK JSON). Only @shomei-jwt@ (EP-4)
converts a 'StoredSigningKey' to/from a @jose@ @JWK@.
-}
module Shomei.Domain.SigningKey (
    SigningKeyStatus (..),
    StoredSigningKey (..),
) where

import Shomei.Prelude

data SigningKeyStatus = KeyPending | KeyActive | KeyRetired | KeyRevoked
    deriving stock (Generic, Eq, Show)
    deriving anyclass (FromJSON, ToJSON)

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
