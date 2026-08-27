-- | Compatibility re-export for hosts written before canonical client-IP rendering moved
-- to "Shomei.Servant.ClientIp".
module Shomei.Servant.RemoteHost (clientIpText) where

import Shomei.Servant.ClientIp (clientIpText)
