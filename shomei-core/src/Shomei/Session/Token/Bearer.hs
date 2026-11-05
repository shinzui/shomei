-- | RFC 6750 section 2.1 credentials. Schemes are case-insensitive; separators are
-- one or more ASCII spaces, and token padding is allowed only at the end.
module Shomei.Session.Token.Bearer (parseBearer) where

import Data.Text qualified as Text
import Shomei.Prelude

parseBearer :: Text -> Maybe Text
parseBearer raw = do
  let (scheme, separator) = Text.break (== ' ') raw
      token = Text.dropWhile (== ' ') separator
      (body, padding) = Text.break (== '=') token
  if Text.toCaseFold scheme == "bearer"
    && not (Text.null separator)
    && not (Text.null body)
    && Text.all tokenChar body
    && Text.all (== '=') padding
    then Just token
    else Nothing
  where
    tokenChar c =
      (c >= 'A' && c <= 'Z')
        || (c >= 'a' && c <= 'z')
        || (c >= '0' && c <= '9')
        || c `elem` ("-._~+/" :: String)
