-- | A resource server's view of the public introspection response.
module ResourceServerFixture
  ( Evidence (..),
    Refusal (..),
    inspect,
    acceptingRoutes,
  )
where

import Control.Exception (try)
import Control.Monad (guard)
import Data.Aeson (Object, Value, withObject, (.:))
import Data.Aeson.KeyMap qualified as KM
import Data.Aeson.Types (Parser, parseMaybe)
import Data.Maybe (fromMaybe, isJust)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time (UTCTime)
import Data.Time.Clock.POSIX (utcTimeToPOSIXSeconds)
import Network.HTTP.Client (HttpException)
import Network.HTTP.Types (Header)
import Shomei.Authorization.Claims.Domain (Audience, Issuer, Scope (..), validScopeName)
import Shomei.Id (SessionId, UserId)
import Shomei.Session.Domain (SessionKind (..))

data Evidence = Evidence
  { subject :: UserId,
    sessionId :: SessionId,
    kind :: SessionKind,
    scopes :: Set Scope,
    actor :: Maybe UserId
  }
  deriving stock (Eq, Show)

data Refusal = Inactive | UnsuitableCredential | LookupFailed | MalformedReply
  deriving stock (Eq, Show)

inspect :: Issuer -> Audience -> UTCTime -> IO (Int, [Header], Maybe Value) -> IO (Either Refusal Evidence)
inspect issuer audience clock request = do
  response <- try @HttpException request
  pure $ case response of
    Right (200, _, body) -> fromMaybe (Left MalformedReply) (body >>= parseMaybe (withObject "introspection" parseReply))
    _ -> Left LookupFailed
  where
    parseReply obj = do
      active <- obj .: "active"
      if active then parseActive obj else pure (Left Inactive)

    parseActive obj = do
      tokenType <- obj .: "token_type"
      case tokenType :: Text of
        "Bearer" -> do
          iss <- obj .: "iss"
          aud <- obj .: "aud"
          expSeconds <- obj .: "exp"
          if iss == issuer && aud == audience && expSeconds > (floor (utcTimeToPOSIXSeconds clock) :: Integer)
            then Right <$> parseEvidence obj
            else pure (Left UnsuitableCredential)
        _ -> pure (Left UnsuitableCredential)

parseEvidence :: Object -> Parser Evidence
parseEvidence obj = do
  subject <- obj .: "sub"
  sessionId <- obj .: "sid"
  name <- obj .: "session_kind"
  kind <- case name :: Text of
    "interactive" -> pure InteractiveSession
    "machine" -> pure MachineSession
    "delegated" -> pure DelegatedSession
    _ -> fail "unknown session kind"
  actor <- traverse (withObject "actor" parseActor) (KM.lookup "act" obj)
  guard (isJust actor == (kind == DelegatedSession))
  scope <- obj .: "scope"
  let scopes = Set.fromList [Scope s | s <- T.splitOn " " scope, not (T.null s)]
  guard (all validScopeName scopes)
  pure Evidence {subject, sessionId, kind, scopes, actor}
  where
    parseActor a = do
      guard (KM.size a == 1)
      a .: "sub"

-- | Each route chooses its own accepted kinds and required scopes.
acceptingRoutes :: Evidence -> [Text]
acceptingRoutes evidence =
  [ route
  | (route, kinds, required) <-
      [ ("member", [InteractiveSession], []),
        ("machine-ingest", [MachineSession], [ingest]),
        ("service-ingest", [MachineSession, DelegatedSession], [ingest])
      ],
    evidence.kind `elem` kinds,
    all (`Set.member` evidence.scopes) required
  ]
  where
    ingest = Scope "kawa:ingest"
