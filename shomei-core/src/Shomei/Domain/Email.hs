-- | Normalized email addresses.
--
-- The raw 'Email' constructor is not exported: the only way to build one is 'mkEmail',
-- which trims whitespace, lowercases the address, and rejects malformed input. This
-- makes invalid emails unrepresentable outside this module.
module Shomei.Domain.Email
  ( Email,
    mkEmail,
    emailText,
  )
where

import Data.Text qualified as Text
import Shomei.Error (AuthError (..))
import Shomei.Prelude

newtype Email = Email Text
  deriving stock (Generic)
  deriving newtype (Eq, Ord, Show, FromJSON, ToJSON)

emailText :: Email -> Text
emailText (Email t) = t

-- | Trim whitespace; lowercase the whole address (initial impl); reject invalid shape.
-- Does NOT collapse gmail dots or plus-addressing.
mkEmail :: Text -> Either AuthError Email
mkEmail raw =
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
