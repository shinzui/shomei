-- | Shared Warp lifecycle for standalone and embedded hosts. Rejected connections never
-- wait for a permit. Warp brackets onOpen/onClose even when onOpen returns False; track
-- admitted worker identities so rejected closes cannot release someone else's capacity.
module Shomei.Server.Runtime (hostWarpSettings) where

import Control.Concurrent (myThreadId)
import Control.Concurrent.STM (atomically, newTVarIO, readTVar, writeTVar)
import Control.Monad (when)
import Data.Set qualified as Set
import Data.String (fromString)
import Data.Text qualified as Text
import Network.Wai.Handler.Warp qualified as Warp
import Shomei.Config (ObservabilityConfig (..), ShomeiConfig (..))
import Shomei.Server.Config (ProxyProtocolMode (..), ServerSettings (..))
import Shomei.Server.ExceptionResponse (problemExceptionResponse)
import Shomei.Server.Observability.Logging (logServerError)

hostWarpSettings :: ShomeiConfig -> ServerSettings -> Warp.Settings -> IO Warp.Settings
hostWarpSettings cfg settings base = do
  when
    (settings.serverMaxConnections <= 0 || settings.serverSlowClientTimeoutSeconds <= 0 || settings.serverSlowClientTimeoutSeconds > maxBound `div` 1000000 || Text.null settings.serverBindHost)
    (ioError (userError "host bind, connection limit and slow-client timeout must be finite and positive"))
  admitted <- newTVarIO Set.empty
  let onOpen _ = do
        worker <- myThreadId
        atomically do
          active <- readTVar admitted
          if Set.size active >= settings.serverMaxConnections
            then pure False
            else do
              writeTVar admitted (Set.insert worker active)
              pure True
      onClose _ = do
        worker <- myThreadId
        atomically do
          active <- readTVar admitted
          writeTVar admitted (Set.delete worker active)
      proxy = case settings.serverProxyProtocol of
        ProxyProtocolOff -> Warp.setProxyProtocolNone
        ProxyProtocolRequired -> Warp.setProxyProtocolRequired
      onException request err = when (Warp.defaultShouldDisplayException err) (logServerError request err)
  pure
    $ Warp.setPort settings.serverPort
      . Warp.setHost (fromString (Text.unpack settings.serverBindHost))
      . Warp.setTimeout settings.serverSlowClientTimeoutSeconds
      . Warp.setOnOpen onOpen
      . Warp.setOnClose onClose
      . Warp.setGracefulShutdownTimeout (Just cfg.observabilityConfig.gracefulShutdownTimeoutSeconds)
      . Warp.setServerName "shomei"
      . Warp.setOnException onException
      . Warp.setOnExceptionResponse problemExceptionResponse
      . proxy
    $ base
