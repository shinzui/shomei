-- | A small synchronous audit boundary for this example's protected read. One sink owns
-- one private append file in one process; use a collector for multi-process deployments.
module Downstream.Audit
  ( AuditRecord (..),
    AuditOutcome (..),
    AuditSink (..),
    newFileAuditSink,
  )
where

import Control.Concurrent.MVar (newMVar, withMVar)
import Control.Exception (bracket, bracketOnError)
import Data.Aeson (ToJSON, encode)
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as LBS
import Data.Text (Text)
import Data.Time (UTCTime)
import GHC.Generics (Generic)
import System.IO (hClose, hFlush, hSetBinaryMode)
import System.Posix.Files (setFdMode)
import System.Posix.IO (OpenFileFlags (..), OpenMode (WriteOnly), closeFd, defaultFileFlags, fdToHandle, openFd)
import System.Posix.Unistd (fileSynchronise)

data AuditOutcome = AuditSucceeded | AuditRejected | AuditUnavailable
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON)

data AuditRecord = AuditRecord
  { occurredAt :: !UTCTime,
    actor :: !(Maybe Text),
    subject :: !(Maybe Text),
    action :: !Text,
    resource :: !Text,
    result :: !AuditOutcome,
    requestId :: !Text
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON)

newtype AuditSink = AuditSink {appendAudit :: AuditRecord -> IO ()}

-- | Each successful call flushes and fsyncs before returning. Creation and existing file
-- permissions are owner-only; O_NOFOLLOW refuses a symlink. No token or unverified claim
-- is part of the record type. The operator supplies an existing private parent directory.
newFileAuditSink :: FilePath -> IO AuditSink
newFileAuditSink path = do
  lock <- newMVar ()
  let open = bracketOnError (openFd path WriteOnly defaultFileFlags {append = True, creat = Just 0o600, nofollow = True}) closeFd \fd -> do
        setFdMode fd 0o600
        handle <- fdToHandle fd
        pure (fd, handle)
  pure . AuditSink $ \record -> withMVar lock \() -> bracket open (hClose . snd) \(fd, handle) -> do
    hSetBinaryMode handle True
    BS.hPut handle (LBS.toStrict (encode record) <> "\n")
    hFlush handle
    fileSynchronise fd
