-- | Hashing and constant-time verification for service-account client secrets.
module Shomei.ServiceAccount.Secret
  ( sha256Hex,
    verifyServiceSecret,
  )
where

import Crypto.Hash (SHA256 (..), hashWith)
import Data.ByteArray qualified as BA
import Data.ByteArray.Encoding (Base (Base16), convertToBase)
import Data.ByteString (ByteString)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TE
import Shomei.Prelude

-- | Constant-time check of a presented secret against a stored lowercase SHA-256 hex digest.
verifyServiceSecret :: Text -> Text -> Bool
verifyServiceSecret expectedHash presentedSecret =
  let expected = TE.encodeUtf8 (Text.toLower expectedHash)
      actual = TE.encodeUtf8 (sha256Hex presentedSecret)
   in expected `BA.constEq` actual

sha256Hex :: Text -> Text
sha256Hex secret =
  let digest = hashWith SHA256 (TE.encodeUtf8 secret)
   in Text.toLower (TE.decodeUtf8 (convertToBase Base16 digest :: ByteString))
