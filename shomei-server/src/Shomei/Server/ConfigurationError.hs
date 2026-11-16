-- | Expected configuration rejection. Descriptions must contain no submitted values.
module Shomei.Server.ConfigurationError (ConfigurationError (..), configurationError, reportConfigurationError) where

import Control.Exception (Exception, catch, throwIO)
import Data.Char (isControl)
import System.Exit (exitFailure)
import System.IO (hPutStrLn, stderr)

newtype ConfigurationError = ConfigurationError String
  deriving stock (Show)
  deriving anyclass (Exception)

configurationError :: String -> IO a
configurationError = throwIO . ConfigurationError

-- | Catch only expected configuration failures at an executable's loading boundary.
reportConfigurationError :: String -> IO a -> IO a
reportConfigurationError prefix action =
  action `catch` \(ConfigurationError description) -> do
    hPutStrLn stderr (prefix <> ": " <> map (\c -> if isControl c then ' ' else c) description)
    exitFailure
