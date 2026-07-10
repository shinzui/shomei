-- | RFC 6238 conformance for "Shomei.Totp": the Appendix B vectors, the ±1 acceptance
-- window, the strictly-greater replay rule, and a Base32 round-trip.
module Shomei.TotpSpec (tests) where

import Data.Text (Text)
import Data.Time.Clock.POSIX (posixSecondsToUTCTime)
import Shomei.Totp
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, testCase, (@?=))

-- | The RFC 6238 Appendix B secret: the 20 ASCII bytes @"12345678901234567890"@.
rfcSecret :: TotpSecret
rfcSecret = TotpSecret "12345678901234567890"

-- | The 8-digit code the RFC prescribes for a given Unix time.
vectorAt :: Integer -> Text -> TestTree
vectorAt t expected =
  testCase ("matches RFC 6238 vector at t=" <> show t) $
    totpCode 8 rfcSecret (totpCounter (posixSecondsToUTCTime (fromIntegral t))) @?= expected

tests :: TestTree
tests =
  testGroup
    "Shomei.Totp"
    [ vectorAt 59 "94287082",
      vectorAt 1111111109 "07081804",
      vectorAt 1234567890 "89005924",
      vectorAt 2000000000 "69279037",
      testCase "counter derivation floors to the 30-second step" $ do
        totpCounter (posixSecondsToUTCTime 59) @?= 1
        totpCounter (posixSecondsToUTCTime 1234567890) @?= 41152263,
      testCase "6-digit code is the 8-digit value mod 10^6" $
        -- 94287082 `mod` 1000000 == 287082
        totpCode 6 rfcSecret 1 @?= "287082",
      testCase "accepts a code for the current counter and returns it" $ do
        let now = posixSecondsToUTCTime 1234567890
            c = totpCounter now
        verifyTotp rfcSecret Nothing now (totpCode 6 rfcSecret c) @?= Just c,
      testCase "accepts the previous-step code within the window" $ do
        let now = posixSecondsToUTCTime 1234567890
            c = totpCounter now
        verifyTotp rfcSecret Nothing now (totpCode 6 rfcSecret (c - 1)) @?= Just (c - 1),
      testCase "rejects a code two steps in the past (outside the window)" $ do
        let now = posixSecondsToUTCTime 1234567890
            c = totpCounter now
        verifyTotp rfcSecret Nothing now (totpCode 6 rfcSecret (c - 2)) @?= Nothing,
      testCase "rejects a replayed counter (strictly-greater rule)" $ do
        let now = posixSecondsToUTCTime 1234567890
            c = totpCounter now
        verifyTotp rfcSecret (Just c) now (totpCode 6 rfcSecret c) @?= Nothing,
      testCase "rejects a wrong code" $ do
        let now = posixSecondsToUTCTime 1234567890
        verifyTotp rfcSecret Nothing now "000000" @?= Nothing,
      testCase "Base32 of the RFC secret is the well-known value" $
        secretToBase32 rfcSecret @?= "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ",
      testCase "Base32 round-trips" $
        assertBool "decode . encode == id" (base32ToSecret (secretToBase32 rfcSecret) == Right rfcSecret),
      testCase "otpauth URI carries the Base32 secret and issuer" $
        otpauthUri "shomei" "alice" rfcSecret
          @?= "otpauth://totp/shomei:alice?secret=GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ&issuer=shomei"
    ]
