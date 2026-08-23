-- | Audit-query parameters and response wire types.
module Shomei.Audit.Dto
  ( AuditEventResponse (..),
    AuditEventsPage (..),
    AuditUserId (..),
    AuditSessionId (..),
    AuditTimestamp (..),
    AuditPageCursor (..),
    storedToResponse,
    encodeCursor,
    decodeCursor,
  )
where

import Data.Aeson (Value)
import Data.Text qualified as Text
import Data.Time.Format.ISO8601 (iso8601ParseM, iso8601Show)
import Data.UUID qualified as UUID
import Shomei.Audit.Reader.Store (AuditCursor (..), StoredAuthEvent (..))
import Shomei.Id (SessionId, UserId, idText, parseId)
import Shomei.Prelude
import Web.HttpApiData (FromHttpApiData (..), ToHttpApiData (..))

data AuditEventResponse = AuditEventResponse
  { eventId :: !Text,
    eventType :: !Text,
    userId :: !(Maybe Text),
    sessionId :: !(Maybe Text),
    createdAt :: !Text,
    payload :: !Value
  }
  deriving stock (Generic)
  deriving anyclass (FromJSON, ToJSON)

data AuditEventsPage = AuditEventsPage
  { events :: ![AuditEventResponse],
    nextCursor :: !(Maybe Text)
  }
  deriving stock (Generic)
  deriving anyclass (FromJSON, ToJSON)

newtype AuditUserId = AuditUserId {auditUserId :: UserId}
  deriving stock (Eq, Show)

instance FromHttpApiData AuditUserId where
  parseUrlPiece value = either (Left . Text.pack . show) (Right . AuditUserId) (parseId value)

instance ToHttpApiData AuditUserId where
  toUrlPiece = idText . (.auditUserId)

newtype AuditSessionId = AuditSessionId {auditSessionId :: SessionId}
  deriving stock (Eq, Show)

instance FromHttpApiData AuditSessionId where
  parseUrlPiece value = either (Left . Text.pack . show) (Right . AuditSessionId) (parseId value)

instance ToHttpApiData AuditSessionId where
  toUrlPiece = idText . (.auditSessionId)

newtype AuditTimestamp = AuditTimestamp {auditTimestamp :: UTCTime}
  deriving stock (Eq, Show)

instance FromHttpApiData AuditTimestamp where
  parseUrlPiece value = maybe (Left "invalid ISO-8601 timestamp") (Right . AuditTimestamp) (iso8601ParseM (Text.unpack value))

instance ToHttpApiData AuditTimestamp where
  toUrlPiece = Text.pack . iso8601Show . (.auditTimestamp)

newtype AuditPageCursor = AuditPageCursor {auditCursor :: AuditCursor}
  deriving stock (Eq, Show)

instance FromHttpApiData AuditPageCursor where
  parseUrlPiece value = maybe (Left "invalid before cursor") (Right . AuditPageCursor) (decodeCursor value)

instance ToHttpApiData AuditPageCursor where
  toUrlPiece = encodeCursor . (.auditCursor)

storedToResponse :: StoredAuthEvent -> AuditEventResponse
storedToResponse stored =
  AuditEventResponse
    { eventId = UUID.toText stored.storedEventId,
      eventType = stored.storedEventType,
      userId = UUID.toText <$> stored.storedUserId,
      sessionId = UUID.toText <$> stored.storedSessionId,
      createdAt = Text.pack (iso8601Show stored.storedCreatedAt),
      payload = stored.storedPayload
    }

encodeCursor :: AuditCursor -> Text
encodeCursor cursor =
  Text.pack (iso8601Show cursor.cursorCreatedAt) <> ";" <> UUID.toText cursor.cursorEventId

decodeCursor :: Text -> Maybe AuditCursor
decodeCursor value = case Text.breakOn ";" value of
  (timestamp, rest)
    | Just identifier <- Text.stripPrefix ";" rest -> do
        createdAt <- iso8601ParseM (Text.unpack timestamp)
        eventId <- UUID.fromText identifier
        pure AuditCursor {cursorCreatedAt = createdAt, cursorEventId = eventId}
  _ -> Nothing
