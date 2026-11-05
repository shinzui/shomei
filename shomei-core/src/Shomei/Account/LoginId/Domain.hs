-- | Normalized login identifiers — the principal of an account.
--
-- A 'LoginId' is a free-form, case-insensitive, unique handle: it may be a username,
-- an agent id like @agent-4815162342@, or an email-shaped identifier
-- address. Unlike 'Shomei.Account.Email.Domain.Email' it does NOT require an @\@@ or a dot —
-- that is the whole point: a principal need not be an email.
--
-- New writes use 'mkLoginId', which normalizes and bounds the handle. The explicitly
-- named compatibility parser is reserved for authentication and persisted snapshots.
module Shomei.Account.LoginId.Domain
  ( LoginId,
    mkLoginId,
    parseLoginIdForAuthentication,
    loginIdText,
  )
where

import Data.Aeson (withText)
import Data.Char (isSpace)
import Data.Text qualified as Text
import Shomei.Error (AuthError (..))
import Shomei.Prelude

newtype LoginId = LoginId Text
  deriving stock (Generic)
  deriving newtype (Eq, Ord, Show, ToJSON)

-- | Project the normalized identifier text.
loginIdText :: LoginId -> Text
loginIdText (LoginId t) = t

-- | Trim leading/trailing whitespace; lowercase the handle (case-insensitive
-- principal); reject the empty string and any value containing internal whitespace.
-- Does NOT require an @\@@ or a dot — a username principal is valid.
mkLoginId :: Text -> Either AuthError LoginId
mkLoginId raw
  | Text.length raw > 256 = Left InvalidLoginId
  | otherwise = do
      lid <- parseLoginIdForAuthentication raw
      if Text.length (loginIdText lid) <= 256 then Right lid else Left InvalidLoginId

-- | Compatibility parser for persisted identities and authentication only. New writes must
-- revalidate with mkLoginId; legacy principals are never truncated or renamed.
parseLoginIdForAuthentication :: Text -> Either AuthError LoginId
parseLoginIdForAuthentication raw =
  let t = Text.toLower (Text.strip raw)
   in if Text.null t || Text.any isSpace t
        then Left InvalidLoginId
        else Right (LoginId t)

instance FromJSON LoginId where
  parseJSON = withText "LoginId" (either (const (fail "invalid login identifier")) pure . mkLoginId)
