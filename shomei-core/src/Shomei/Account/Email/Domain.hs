-- | Normalized email addresses.
--
-- New writes use 'mkEmail'. 'parseStoredEmail' preserves legacy snapshot and recovery
-- compatibility; it must not be used to validate new writes.
module Shomei.Account.Email.Domain
  ( Email,
    mkEmail,
    parseStoredEmail,
    emailText,
  )
where

import Data.Aeson (withText)
import Data.ByteString qualified as BS
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TE
import Shomei.Error (AuthError (..))
import Shomei.Prelude

newtype Email = Email Text
  deriving stock (Generic)
  deriving newtype (Eq, Ord, Show, ToJSON)

emailText :: Email -> Text
emailText (Email t) = t

-- | Trim whitespace; lowercase the whole address (initial impl); reject invalid shape.
-- Does NOT collapse gmail dots or plus-addressing.
mkEmail :: Text -> Either AuthError Email
mkEmail raw
  | Text.length raw > 254 || BS.length (TE.encodeUtf8 raw) > 254 = Left InvalidEmail
  | otherwise = do
      email <- parseStoredEmail raw
      if BS.length (TE.encodeUtf8 (emailText email)) <= 254 then Right email else Left InvalidEmail

-- | Compatibility decoding for persisted identities and recovery lookup; never for writes.
parseStoredEmail :: Text -> Either AuthError Email
parseStoredEmail raw =
  let t = Text.toLower (Text.strip raw)
   in if isValidShape t then Right (Email t) else Left InvalidEmail
  where
    isValidShape t = case Text.splitOn "@" t of
      [local, domain] ->
        not (Text.null local)
          && not (Text.null domain)
          && Text.isInfixOf "." domain
          && not (Text.isInfixOf " " t)
      _ -> False

instance FromJSON Email where
  parseJSON = withText "Email" (either (const (fail "invalid email")) pure . mkEmail)
