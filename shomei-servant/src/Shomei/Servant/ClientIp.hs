-- | Canonical textual client addresses shared by Servant handlers and WAI middleware.
module Shomei.Servant.ClientIp
  ( clientIpText,
    clientIpOf,
  )
where

import Data.List (maximumBy)
import Data.Ord (comparing)
import Data.Text qualified as Text
import Data.Word (Word16)
import Network.Socket (SockAddr (..), hostAddress6ToTuple, hostAddressToTuple)
import Numeric (showHex)
import Shomei.Prelude
import Shomei.Session.LoginAttempt.Domain (ClientIp (..))

clientIpOf :: SockAddr -> ClientIp
clientIpOf = ClientIp . clientIpText

-- | Render an IPv4 peer as a dotted quad and IPv6 according to RFC 5952.
-- The source port is deliberately omitted because the result is a security-policy key.
clientIpText :: SockAddr -> Text
clientIpText = \case
  SockAddrInet _ host ->
    let (a, b, c, d) = hostAddressToTuple host
     in Text.intercalate "." (Text.pack . show <$> [a, b, c, d])
  SockAddrInet6 _ _ host _ ->
    let (a, b, c, d, e, f, g, h) = hostAddress6ToTuple host
     in renderIpv6 [a, b, c, d, e, f, g, h]
  SockAddrUnix path -> Text.pack path

renderIpv6 :: [Word16] -> Text
renderIpv6 groups =
  case longestZeroRun groups of
    Nothing -> joined groups
    Just (start, len) ->
      let before = joined (take start groups)
          after = joined (drop (start + len) groups)
       in case (Text.null before, Text.null after) of
            (True, True) -> "::"
            (True, False) -> "::" <> after
            (False, True) -> before <> "::"
            (False, False) -> before <> "::" <> after
  where
    joined = Text.intercalate ":" . fmap (Text.pack . (`showHex` ""))

-- RFC 5952 compresses the longest run of at least two zero groups, choosing the
-- leftmost run on a tie. 'maximumBy' is fed the reversed candidates so its
-- rightmost-on-equality behavior preserves that leftmost run.
longestZeroRun :: [Word16] -> Maybe (Int, Int)
longestZeroRun groups =
  case reverse (zeroRuns 0 groups) of
    [] -> Nothing
    runs -> Just (maximumBy (comparing snd) runs)

zeroRuns :: Int -> [Word16] -> [(Int, Int)]
zeroRuns _ [] = []
zeroRuns offset values@(value : rest)
  | value /= 0 = zeroRuns (offset + 1) rest
  | otherwise =
      let len = length (takeWhile (== 0) values)
          remaining = zeroRuns (offset + len) (drop len values)
       in if len >= 2 then (offset, len) : remaining else remaining
