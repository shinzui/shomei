-- | Resolve a client address only when the immediate peer is an explicitly trusted proxy.
module Shomei.Server.Middleware.TrustedProxy
  ( TrustedProxies,
    emptyTrustedProxies,
    parseTrustedProxies,
    trustedProxyTexts,
    isTrustedPeer,
    forwardedClient,
    trustedProxyMiddleware,
  )
where

import Data.ByteString (ByteString)
import Data.ByteString.Char8 qualified as BC
import Data.IP (IP (..), IPRange (..), fromSockAddr, ipv4ToIPv6, isMatchedTo, toSockAddr)
import Data.Maybe (listToMaybe)
import Data.Text qualified as Text
import Network.Wai (Middleware, Request (..))
import Shomei.Prelude
import Text.Read (readMaybe)

newtype TrustedProxies = TrustedProxies [IPRange]
  deriving stock (Eq, Show)

emptyTrustedProxies :: TrustedProxies
emptyTrustedProxies = TrustedProxies []

trustedProxyTexts :: TrustedProxies -> [Text]
trustedProxyTexts (TrustedProxies ranges) = Text.pack . show <$> ranges

-- | Parse CIDR ranges. A bare address means a single-host @/32@ or @/128@ range.
parseTrustedProxies :: [Text] -> Either Text TrustedProxies
parseTrustedProxies = fmap TrustedProxies . traverse parseOne
  where
    parseOne raw =
      let value = Text.strip raw
          cidr
            | Text.any (== '/') value = value
            | Text.any (== ':') value = value <> "/128"
            | otherwise = value <> "/32"
       in maybe
            (Left ("trustedProxies: " <> raw <> " is not an IP address or CIDR block"))
            Right
            (readMaybe (Text.unpack cidr))

isTrustedPeer :: TrustedProxies -> IP -> Bool
isTrustedPeer (TrustedProxies ranges) ip = any (inRange ip) ranges
  where
    inRange (IPv4 address) (IPv4Range range) = address `isMatchedTo` range
    inRange (IPv6 address) (IPv6Range range) = address `isMatchedTo` range
    inRange (IPv4 address) (IPv6Range range) = ipv4ToIPv6 address `isMatchedTo` range
    inRange _ _ = False

-- | Resolve the rightmost untrusted forwarded hop. If every forwarded hop is trusted,
-- the leftmost hop is the original client. Headers are ignored unless the socket peer is trusted.
forwardedClient :: TrustedProxies -> Request -> Maybe IP
forwardedClient proxies req = do
  (peer, _) <- fromSockAddr (remoteHost req)
  guard (isTrustedPeer proxies peer)
  let hops =
        concatMap
          (mapMaybe parseHop . BC.split ',')
          [value | (name, value) <- requestHeaders req, name == "X-Forwarded-For"]
      untrusted = filter (not . isTrustedPeer proxies) hops
  case untrusted of
    [] -> listToMaybe hops
    _ -> listToMaybe (reverse untrusted)

-- | Accept the address forms emitted by common proxies: a bare address, IPv4 with a port,
-- or bracketed IPv6 with an optional port. Malformed entries are ignored.
parseHop :: ByteString -> Maybe IP
parseHop raw = readMaybe (BC.unpack address)
  where
    value = BC.strip raw
    address
      | Just rest <- BC.stripPrefix "[" value = BC.takeWhile (/= ']') rest
      | BC.count ':' value == 1 = BC.takeWhile (/= ':') value
      | otherwise = value

-- | Rewrite 'remoteHost' before downstream middleware and handlers read it.
trustedProxyMiddleware :: TrustedProxies -> Middleware
trustedProxyMiddleware proxies app req =
  app
    case forwardedClient proxies req of
      Nothing -> req
      Just ip -> req {remoteHost = toSockAddr (ip, 0)}
