-- | Refuse oversized request bodies before they reach a handler (EP-8).
--
-- Nothing else in the stack bounds how much a client may send: warp has no request-body size
-- setting (body limiting is a middleware concern), and Shōmei's JSON handlers happily begin
-- consuming whatever arrives. This middleware answers HTTP 413 to any request that declares a
-- @Content-Length@ above the cap, without reading a byte of the body. Bodies without a declared
-- length are metered chunk by chunk as the downstream application consumes them.
module Shomei.Server.Middleware.BodyLimit
  ( bodyLimitMiddleware,
    defaultBodyLimitBytes,
  )
where

import Control.Exception (Exception, catch, throwIO)
import Control.Monad (when)
import Data.ByteString qualified as BS
import Data.IORef (atomicModifyIORef', newIORef, readIORef, writeIORef)
import Data.Word (Word64)
import Network.Wai
  ( Middleware,
    RequestBodyLength (KnownLength),
    getRequestBodyChunk,
    requestBodyLength,
    setRequestBodyChunks,
  )
import Shomei.Servant.Error (noProblemOccurrence, pcPayloadTooLarge)
import Shomei.Servant.Middleware (problemResponse)

data BodyOverCap = BodyOverCap Word64
  deriving stock (Show)
  deriving anyclass (Exception)

-- | 1 MiB. Three orders of magnitude above the largest legitimate Shōmei request body (a
-- WebAuthn attestation), and small enough that a flood of maximal bodies cannot exhaust memory.
defaultBodyLimitBytes :: Word64
defaultBodyLimitBytes = 1024 * 1024

-- | Reject a request once its declared or observed body length is strictly greater than @limit@.
bodyLimitMiddleware :: Word64 -> Middleware
bodyLimitMiddleware limit app req respond
  | KnownLength n <- requestBodyLength req, n > limit = respond tooLarge
  | otherwise = do
      seen <- newIORef 0
      responded <- newIORef False
      let metered = do
            chunk <- getRequestBodyChunk req
            total <-
              atomicModifyIORef' seen \n ->
                let n' = n + fromIntegral (BS.length chunk)
                 in (n', n')
            when (total > limit) (throwIO (BodyOverCap limit))
            pure chunk
          respond' res = writeIORef responded True >> respond res
      app (setRequestBodyChunks metered req) respond' `catch` \e@(BodyOverCap _) -> do
        already <- readIORef responded
        if already then throwIO e else respond tooLarge
  where
    tooLarge = problemResponse pcPayloadTooLarge noProblemOccurrence
