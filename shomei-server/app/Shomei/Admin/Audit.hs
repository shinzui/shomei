-- | @shomei-admin audit@ (EP-7, M3): read the append-only security audit trail without a
-- @psql@ shell. The subcommands are thin wrappers over the shared
-- 'Shomei.Effect.AuthEventReader' query layer (the same one the HTTP @GET \/admin\/audit\/events@
-- endpoint uses), run through the PostgreSQL interpreter over the admin pool:
--
-- @
-- shomei-admin audit events  [--user UUID] [--session UUID] [--type T ...] [--since TS] [--until TS] [--limit N] [--json]
-- shomei-admin audit user    \<UUID\> [filters]   -- shortcut for --user
-- shomei-admin audit session \<UUID\> [filters]   -- shortcut for --session
-- shomei-admin audit count   [filters]           -- how many events match
-- @
--
-- Default output is one tab-separated line per event
-- (@created_at \\t event_type \\t user_id \\t session_id \\t event_id@); @--json@ emits one JSON
-- object per line (NDJSON), including the raw event payload.
module Shomei.Admin.Audit
  ( AuditCommand (..),
    AuditFilters (..),
    auditParser,
    runAudit,
    runAuditReader,
  )
where

import Control.Monad (forM_)
import Data.Aeson (Value, encode, object, (.=))
import Data.ByteString.Lazy.Char8 qualified as BLC
import Data.List (intercalate)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (UTCTime)
import Data.Time.Format.ISO8601 (iso8601ParseM, iso8601Show)
import Data.UUID (UUID)
import Data.UUID qualified as UUID
import Effectful (Eff, IOE, runEff)
import Effectful.Error.Static (Error, runErrorNoCallStack)
import Hasql.Pool (Pool)
import Options.Applicative
import Shomei.Admin.Env (AdminEnv (..))
import Shomei.Effect.AuthEventReader
  ( AuditEventQuery (..),
    AuthEventReader,
    StoredAuthEvent (..),
    countAuthEvents,
    emptyAuditQuery,
    queryAuthEvents,
  )
import Shomei.Error (AuthError)
import Shomei.Postgres.AuthEventReader (runAuthEventReaderPostgres)
import Shomei.Postgres.Database (Database, runDatabasePool)
import System.Exit (exitFailure)
import System.IO (hPutStrLn, stderr)

-- The command tree -----------------------------------------------------------

-- | Textual filters as they arrive from the command line (parsed/validated in 'toQuery').
data AuditFilters = AuditFilters
  { fUser :: !(Maybe Text),
    fSession :: !(Maybe Text),
    fTypes :: ![Text],
    fSince :: !(Maybe Text),
    fUntil :: !(Maybe Text),
    fLimit :: !Int,
    fJson :: !Bool
  }

data AuditCommand
  = AuditEvents AuditFilters
  | AuditUser Text AuditFilters
  | AuditSession Text AuditFilters
  | AuditCount AuditFilters

auditParser :: Parser AuditCommand
auditParser =
  hsubparser
    ( command "events" (info (AuditEvents <$> filtersParser) (progDesc "List audit events, most recent first"))
        <> command "user" (info (AuditUser <$> uuidArg "USER_ID" <*> filtersParser) (progDesc "Event timeline for one user"))
        <> command "session" (info (AuditSession <$> uuidArg "SESSION_ID" <*> filtersParser) (progDesc "Event timeline for one session"))
        <> command "count" (info (AuditCount <$> filtersParser) (progDesc "Count events matching the filters"))
    )
  where
    uuidArg mv = Text.pack <$> argument str (metavar mv)

filtersParser :: Parser AuditFilters
filtersParser =
  AuditFilters
    <$> optional (txt (long "user" <> metavar "UUID" <> help "Filter by user id"))
    <*> optional (txt (long "session" <> metavar "UUID" <> help "Filter by session id"))
    <*> many (txt (long "type" <> metavar "EVENT_TYPE" <> help "Filter by event type (repeatable)"))
    <*> optional (txt (long "since" <> metavar "ISO8601" <> help "Only events at or after this time (inclusive)"))
    <*> optional (txt (long "until" <> metavar "ISO8601" <> help "Only events strictly before this time"))
    <*> option auto (long "limit" <> metavar "N" <> value 50 <> showDefault <> help "Max rows (clamped to 1000)")
    <*> switch (long "json" <> help "Emit one JSON object per line (NDJSON)")
  where
    txt = fmap Text.pack . strOption

-- Execution ------------------------------------------------------------------

runAudit :: AdminEnv -> AuditCommand -> IO ()
runAudit env = \case
  AuditEvents f -> listEvents env f
  AuditUser uuid f -> listEvents env f {fUser = Just uuid}
  AuditSession uuid f -> listEvents env f {fSession = Just uuid}
  AuditCount f -> countEvents env f

listEvents :: AdminEnv -> AuditFilters -> IO ()
listEvents env f = do
  q <- toQuery f
  rows <- runReaderOrDie env.pool (queryAuthEvents q)
  if f.fJson
    then forM_ rows (BLC.putStrLn . encode . toJsonObject)
    else forM_ rows (putStrLn . tabLine)

countEvents :: AdminEnv -> AuditFilters -> IO ()
countEvents env f = do
  q <- toQuery f
  n <- runReaderOrDie env.pool (countAuthEvents q)
  print n

-- | Tab-separated line: @created_at \\t event_type \\t user_id \\t session_id \\t event_id@.
tabLine :: StoredAuthEvent -> String
tabLine s =
  intercalate
    "\t"
    [ iso8601Show s.storedCreatedAt,
      Text.unpack s.storedEventType,
      maybe "-" UUID.toString s.storedUserId,
      maybe "-" UUID.toString s.storedSessionId,
      UUID.toString s.storedEventId
    ]

toJsonObject :: StoredAuthEvent -> Value
toJsonObject s =
  object
    [ "eventId" .= UUID.toText s.storedEventId,
      "eventType" .= s.storedEventType,
      "userId" .= fmap UUID.toText s.storedUserId,
      "sessionId" .= fmap UUID.toText s.storedSessionId,
      "createdAt" .= iso8601Show s.storedCreatedAt,
      "payload" .= s.storedPayload
    ]

-- | Validate the textual filters into an 'AuditEventQuery' (a bad UUID/timestamp aborts).
toQuery :: AuditFilters -> IO AuditEventQuery
toQuery f = do
  user <- parseUuidOpt "--user" f.fUser
  session <- parseUuidOpt "--session" f.fSession
  since <- parseTimeOpt "--since" f.fSince
  until_ <- parseTimeOpt "--until" f.fUntil
  pure
    emptyAuditQuery
      { queryUserId = user,
        querySessionId = session,
        queryEventTypes = f.fTypes,
        querySince = since,
        queryUntil = until_,
        queryLimit = f.fLimit
      }

parseUuidOpt :: String -> Maybe Text -> IO (Maybe UUID)
parseUuidOpt _ Nothing = pure Nothing
parseUuidOpt nm (Just t) =
  maybe (die (nm <> ": invalid UUID: " <> Text.unpack t)) (pure . Just) (UUID.fromText t)

parseTimeOpt :: String -> Maybe Text -> IO (Maybe UTCTime)
parseTimeOpt _ Nothing = pure Nothing
parseTimeOpt nm (Just t) =
  maybe (die (nm <> ": invalid ISO-8601 timestamp: " <> Text.unpack t)) (pure . Just) (iso8601ParseM (Text.unpack t))

-- | Run a read over the 'AuthEventReader' PostgreSQL interpreter on the admin pool, aborting
-- on an infrastructure error. Mirrors @Shomei.Admin.Users.runSignup@'s minimal stack.
runAuditReader ::
  Pool ->
  Eff '[AuthEventReader, Database, Error AuthError, IOE] a ->
  IO (Either AuthError a)
runAuditReader pool =
  runEff
    . runErrorNoCallStack
    . runDatabasePool pool
    . runAuthEventReaderPostgres

runReaderOrDie :: Pool -> Eff '[AuthEventReader, Database, Error AuthError, IOE] a -> IO a
runReaderOrDie pool act = do
  res <- runAuditReader pool act
  either (\e -> die ("database error: " <> show e)) pure res

die :: String -> IO a
die msg = hPutStrLn stderr ("shomei-admin: " <> msg) >> exitFailure
