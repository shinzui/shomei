-- | Convert exceptions that escape WAI or Warp parsing into Shōmei's public error envelope.
module Shomei.Server.ExceptionResponse
  ( problemExceptionResponse,
  )
where

import Control.Exception (SomeAsyncException, SomeException, fromException, throw)
import Network.Wai (Response)
import Network.Wai.Handler.Warp (InvalidRequest (..))
import Shomei.Servant.Error (noProblemOccurrence, pcBadRequest, pcInternal, pcPayloadTooLarge)
import Shomei.Servant.Middleware (problemResponse)

-- | Warp's exception-response hook. Asynchronous cancellation must retain its control-flow
-- meaning; every synchronous failure receives a stable, detail-free public representation.
problemExceptionResponse :: SomeException -> Response
problemExceptionResponse err
  | Just _ <- (fromException err :: Maybe SomeAsyncException) = throw err
  | Just PayloadTooLarge <- (fromException err :: Maybe InvalidRequest) =
      problemResponse pcPayloadTooLarge noProblemOccurrence
  | Just _ <- (fromException err :: Maybe InvalidRequest) =
      problemResponse pcBadRequest noProblemOccurrence
  | otherwise = problemResponse pcInternal noProblemOccurrence
