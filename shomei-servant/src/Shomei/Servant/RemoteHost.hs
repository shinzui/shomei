-- | Shared conversion from Servant's socket peer to Shōmei's textual client-IP key.
module Shomei.Servant.RemoteHost (clientIpText) where

import Data.Text qualified as Text
import Network.Socket (SockAddr (..))
import Shomei.Prelude

clientIpText :: SockAddr -> Text
clientIpText = \case
  SockAddrInet _ host -> Text.pack (show host)
  SockAddrInet6 _ _ host _ -> Text.pack (show host)
  other -> Text.pack (show other)
