{-# LANGUAGE DataKinds #-}

-- | A pure, I/O-free RFC 6238 TOTP primitive, pinned by the RFC's own test vectors.
--
-- TOTP is HOTP (RFC 4226) applied to time. Let @K@ be a shared secret (20 raw bytes
-- here), @X = 30@ seconds. The time-step counter is @C = floor(unixTime / X)@. The code
-- is @DT(HMAC-SHA1(K, C))@ where @DT@ is RFC 4226 dynamic truncation, taken @mod 10^digits@
-- and zero-padded. Production fixes @digits = 6@; the vectors in "Shomei.TotpSpec" pin
-- the RFC 6238 Appendix B 8-digit outputs, so 'totpCode' takes @digits@ as a parameter.
--
-- Base32 comes from @ram@'s 'Data.ByteArray.Encoding' ('Base32' is RFC 4648, uppercase);
-- a 20-byte secret encodes to exactly 32 characters with no padding, so no @base32@
-- package is needed (see the plan's Decision Log).
module Shomei.Totp
  ( TotpSecret (..),
    totpPeriod,
    totpCode,
    totpCounter,
    verifyTotp,
    secretToBase32,
    base32ToSecret,
    otpauthUri,
  )
where

import Crypto.Hash.Algorithms (SHA1)
import Crypto.MAC.HMAC (HMAC, hmac)
import Data.Bits (shiftL, shiftR, (.&.), (.|.))
import Data.ByteArray qualified as BA
import Data.ByteArray.Encoding (Base (Base32), convertFromBase, convertToBase)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Int (Int64)
import Data.List (find)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TE
import Data.Time.Clock.POSIX (utcTimeToPOSIXSeconds)
import Data.Word (Word32)
import Shomei.Prelude

-- | A raw TOTP shared secret: 20 random bytes. The 'Show' instance redacts it — a secret
-- printed to a log or a trace is a secret leaked — and 'Eq' is constant-time.
newtype TotpSecret = TotpSecret ByteString

instance Show TotpSecret where
  show _ = "TotpSecret <redacted>"

instance Eq TotpSecret where
  TotpSecret a == TotpSecret b = BA.constEq a b

-- | The TOTP time step, in seconds. Fixed at 30 — the value every mainstream
-- authenticator app assumes (Google Authenticator historically ignores @period@ URI
-- overrides), so it is deliberately not configurable.
totpPeriod :: Int64
totpPeriod = 30

-- | The RFC 6238 time-step counter for an instant: @floor(unixSeconds / 30)@.
totpCounter :: UTCTime -> Int64
totpCounter t = floor (utcTimeToPOSIXSeconds t) `div` totpPeriod

-- | Serialize a counter as an 8-byte big-endian integer (RFC 4226 message).
counterBytes :: Int64 -> ByteString
counterBytes c = BS.pack [fromIntegral (c `shiftR` (8 * i)) | i <- [7, 6 .. 0]]

-- | @totpCode digits secret counter@: HMAC-SHA1 over the counter, RFC 4226 dynamic
-- truncation, reduced @mod 10^digits@ and rendered as exactly @digits@ digits with
-- leading zeros. Production uses @digits = 6@; the RFC vectors use 8.
totpCode :: Int -> TotpSecret -> Int64 -> Text
totpCode digits (TotpSecret key) counter =
  let h = BA.convert (hmac key (counterBytes counter) :: HMAC SHA1) :: ByteString
      -- low 4 bits of the last byte give the truncation offset (0..15)
      offset = fromIntegral (BS.index h 19 .&. 0x0f) :: Int
      binCode :: Word32
      binCode =
        ((fromIntegral (BS.index h offset) .&. 0x7f) `shiftL` 24)
          .|. (fromIntegral (BS.index h (offset + 1)) `shiftL` 16)
          .|. (fromIntegral (BS.index h (offset + 2)) `shiftL` 8)
          .|. fromIntegral (BS.index h (offset + 3))
      value = binCode `mod` (10 ^ digits)
   in Text.justifyRight digits '0' (Text.pack (show value))

-- | @verifyTotp secret lastUsedCounter now presented@: try the counters
-- @[c-1, c, c+1]@ (a ±1 step acceptance window, tolerating ~30 s of clock skew each way)
-- and return @Just acceptedCounter@ for the first that both matches the presented
-- 6-digit code AND is strictly greater than @lastUsedCounter@ (a 'Nothing' bound accepts
-- any counter). The strictly-greater rule is RFC 6238 §5.2 replay defense: a verified code
-- is never accepted twice. Code comparison is constant-time.
verifyTotp :: TotpSecret -> Maybe Int64 -> UTCTime -> Text -> Maybe Int64
verifyTotp secret lastUsed now presented =
  find matches [c - 1, c, c + 1]
  where
    c = totpCounter now
    matches ctr =
      maybe True (ctr >) lastUsed
        && BA.constEq (TE.encodeUtf8 (totpCode 6 secret ctr)) (TE.encodeUtf8 presented)

-- | RFC 4648 Base32 (uppercase, unpadded for a 20-byte secret) — the form authenticator
-- apps expect for the shared secret.
secretToBase32 :: TotpSecret -> Text
secretToBase32 (TotpSecret k) = TE.decodeUtf8 (convertToBase Base32 k)

-- | Inverse of 'secretToBase32'; used by tests to prove the round-trip.
base32ToSecret :: Text -> Either String TotpSecret
base32ToSecret t =
  TotpSecret <$> (convertFromBase Base32 (TE.encodeUtf8 t) :: Either String ByteString)

-- | The enrollment URI authenticator apps scan:
-- @otpauth:\/\/totp\/{issuer}:{account}?secret={BASE32(K)}&issuer={issuer}@. Callers pass
-- label-safe @issuerLabel@ and @accountLabel@ (the workflow sanitizes them).
otpauthUri :: Text -> Text -> TotpSecret -> Text
otpauthUri issuerLabel accountLabel secret =
  "otpauth://totp/"
    <> issuerLabel
    <> ":"
    <> accountLabel
    <> "?secret="
    <> secretToBase32 secret
    <> "&issuer="
    <> issuerLabel
