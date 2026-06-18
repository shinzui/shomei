{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE TypeFamilies #-}

-- | The password-breach-checker port: decide whether a password appears in a known public
-- breach. Implemented in production by a HIBP k-anonymity range query (EP-3) and in tests by an
-- in-memory fake. Kept separate from the pure 'Shomei.Domain.Password.validatePassword' because
-- the production check performs IO.
module Shomei.Effect.PasswordBreachChecker
  ( PasswordBreachChecker (..),
    BreachResult (..),
    checkPasswordBreached,

    -- * Pure helpers (shared by the production interpreter and tests)
    sha1PrefixSuffix,
    parseHibpResponse,
  )
where

import Crypto.Hash (SHA1 (..), hashWith)
import Data.ByteArray.Encoding (Base (Base16), convertToBase)
import Data.ByteString (ByteString)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TE
import Data.Text.Read qualified as TR
import Effectful (Dispatch (..), DispatchOf, Eff, Effect, (:>))
import Effectful.Dispatch.Dynamic (send)
import Shomei.Domain.Password (PlainPassword (..))
import Shomei.Prelude

-- | The outcome of a breach check; the third state lets policy choose fail-open vs fail-closed.
data BreachResult
  = NotBreached
  | Breached
  | BreachCheckUnavailable
  deriving stock (Eq, Show)

data PasswordBreachChecker :: Effect where
  CheckPasswordBreached :: PlainPassword -> PasswordBreachChecker m BreachResult

type instance DispatchOf PasswordBreachChecker = Dynamic

checkPasswordBreached :: (PasswordBreachChecker :> es) => PlainPassword -> Eff es BreachResult
checkPasswordBreached = send . CheckPasswordBreached

-- | Uppercase hex SHA-1 of the UTF-8 password, split into the 5-char k-anonymity prefix and
-- the 35-char suffix. @sha1PrefixSuffix "password" == ("5BAA6", "1E4C9B93F3F0682250B6CF8331B7EE68FD8")@.
-- Only the prefix is ever sent to HIBP; the full hash never leaves the process.
sha1PrefixSuffix :: PlainPassword -> (Text, Text)
sha1PrefixSuffix (PlainPassword pw) =
  let digest = hashWith SHA1 (TE.encodeUtf8 pw)
      hex = Text.toUpper (TE.decodeUtf8 (convertToBase Base16 digest :: ByteString))
   in (Text.take 5 hex, Text.drop 5 hex)

-- | Given a HIBP range response body and our 35-char suffix, return whether any line matches
-- our suffix (case-insensitive) with a count > 0. Padding lines (count 0) are ignored. Lines may
-- use CRLF; the trailing @\\r@ is stripped before splitting.
parseHibpResponse :: Text -> Text -> Bool
parseHibpResponse body suffix =
  let wantUpper = Text.toUpper suffix
      matches line =
        case Text.splitOn ":" (Text.dropWhileEnd (== '\r') line) of
          [s, c] -> Text.toUpper s == wantUpper && countPositive c
          _ -> False
   in any matches (Text.lines body)
  where
    countPositive c = case TR.decimal (Text.strip c) of
      Right (n, "") -> n > (0 :: Integer)
      _ -> False
