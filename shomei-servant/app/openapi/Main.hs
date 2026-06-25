-- | Emit the Shōmei OpenAPI 3.1 document as pretty JSON to stdout (EP-27).
--
-- > cabal run shomei-openapi > docs/api/openapi.json
--
-- The output is deterministic, so regenerating and diffing the committed
-- @docs/api/openapi.json@ surfaces any drift from the Servant types.
module Main (main) where

import Data.Aeson.Encode.Pretty (encodePretty)
import Data.ByteString.Lazy.Char8 qualified as BL
import Shomei.Servant.OpenApi (shomeiOpenApi)

main :: IO ()
main = BL.putStrLn (encodePretty shomeiOpenApi)
