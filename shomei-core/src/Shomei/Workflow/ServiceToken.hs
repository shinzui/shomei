-- | Service-account token issuance.
--
-- This workflow authenticates a configured service account with a shared secret,
-- creates a short-lived refresh-less session for that account's user, and signs an
-- access token carrying only the requested scopes allowed by configuration.
module Shomei.Workflow.ServiceToken
  ( IssueServiceToken (..),
    IssuedServiceToken (..),
    issueServiceToken,
    sha256Hex,
  )
where

import Crypto.Hash (SHA256 (..), hashWith)
import Data.ByteArray qualified as BA
import Data.ByteArray.Encoding (Base (Base16), convertToBase)
import Data.ByteString (ByteString)
import Data.Foldable (traverse_)
import Data.Generics.Labels ()
import Data.List (find)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TE
import Data.Time (NominalDiffTime, addUTCTime)
import Effectful (Eff, (:>))
import Effectful.Error.Static (runErrorNoCallStack, throwError)
import Shomei.Config (ServiceAccountConfig (..), ServiceAccountId (..), ServiceTokenConfig (..), ShomeiConfig (..))
import Shomei.Domain.Claims (Scope)
import Shomei.Domain.Event qualified as Event
import Shomei.Domain.Session (NewSession (..))
import Shomei.Domain.Token (AccessToken)
import Shomei.Domain.User (UserStatus (UserActive))
import Shomei.Effect.AuthEventPublisher (AuthEventPublisher, publishAuthEvent)
import Shomei.Effect.Clock (Clock, now)
import Shomei.Effect.SessionStore (SessionStore, createSession)
import Shomei.Effect.TokenSigner (TokenSigner, signAccessToken)
import Shomei.Effect.UserStore (UserStore, findUserById)
import Shomei.Error (AuthError (..))
import Shomei.Id (SessionId, UserId)
import Shomei.Prelude
import Shomei.Workflow.Session (buildClaims)

data IssueServiceToken = IssueServiceToken
  { accountId :: !ServiceAccountId,
    secret :: !Text,
    scopes :: !(Set Scope),
    actorId :: !(Maybe UserId)
  }
  deriving stock (Generic, Eq, Show)

data IssuedServiceToken = IssuedServiceToken
  { accessToken :: !AccessToken,
    expiresIn :: !NominalDiffTime,
    sessionId :: !SessionId
  }
  deriving stock (Generic, Eq, Show)

issueServiceToken ::
  ( UserStore :> es,
    SessionStore :> es,
    TokenSigner :> es,
    AuthEventPublisher :> es,
    Clock :> es
  ) =>
  ShomeiConfig ->
  IssueServiceToken ->
  Eff es (Either AuthError IssuedServiceToken)
issueServiceToken cfg cmd = runErrorNoCallStack do
  let serviceCfg = cfg ^. #serviceTokenConfig
  unless (serviceCfg ^. #enabled) (throwError ServiceTokenDisabled)
  account <- maybe (throwError ServiceAccountNotFound) pure (findAccount serviceCfg (cmd ^. #accountId))
  unless (verifyServiceSecret (account ^. #secretHash) (cmd ^. #secret)) (throwError ServiceAccountSecretInvalid)
  when (Set.null (cmd ^. #scopes)) (throwError ServiceTokenScopeDenied)
  unless ((cmd ^. #scopes) `Set.isSubsetOf` (account ^. #allowedScopes)) (throwError ServiceTokenScopeDenied)
  serviceUser <- requireActiveUser ServiceTokenActorInvalid (account ^. #userId)
  traverse_ (requireActiveUser ServiceTokenActorInvalid) (cmd ^. #actorId)
  ts <- now
  let expires = addUTCTime (serviceCfg ^. #ttl) ts
  session <-
    createSession
      NewSession
        { userId = serviceUser ^. #userId,
          createdAt = ts,
          expiresAt = expires,
          actor = cmd ^. #actorId
        }
  let claims =
        (buildClaims cfg (serviceUser ^. #userId) (session ^. #sessionId) ts)
          & #expiresAt .~ expires
          & #scopes .~ (cmd ^. #scopes)
          & #actor .~ (cmd ^. #actorId)
  access <- signAccessToken claims
  publishAuthEvent
    ( Event.ServiceTokenIssued
        Event.ServiceTokenIssuedData
          { userId = serviceUser ^. #userId,
            sessionId = session ^. #sessionId,
            accountId = account ^. #accountId,
            scopes = cmd ^. #scopes,
            actorId = cmd ^. #actorId,
            occurredAt = ts
          }
    )
  pure
    IssuedServiceToken
      { accessToken = access,
        expiresIn = serviceCfg ^. #ttl,
        sessionId = session ^. #sessionId
      }
  where
    requireActiveUser err uid = do
      user <- maybe (throwError err) pure =<< findUserById uid
      unless (user ^. #status == UserActive) (throwError err)
      pure user

findAccount :: ServiceTokenConfig -> ServiceAccountId -> Maybe ServiceAccountConfig
findAccount cfg sid =
  find (\acct -> acct ^. #accountId == sid) (cfg ^. #accounts)

verifyServiceSecret :: Text -> Text -> Bool
verifyServiceSecret expectedHash presentedSecret =
  let expected = TE.encodeUtf8 (Text.toLower expectedHash)
      actual = TE.encodeUtf8 (sha256Hex presentedSecret)
   in expected `BA.constEq` actual

sha256Hex :: Text -> Text
sha256Hex secret =
  let digest = hashWith SHA256 (TE.encodeUtf8 secret)
   in Text.toLower (TE.decodeUtf8 (convertToBase Base16 digest :: ByteString))
