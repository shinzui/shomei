{- | Normalized login identifiers — the principal of an account.

A 'LoginId' is a free-form, case-insensitive, unique handle: it may be a username,
an agent id like @agent-4815162342@, or (for backward compatibility) an email
address. Unlike 'Shomei.Domain.Email.Email' it does NOT require an @\@@ or a dot —
that is the whole point: a principal need not be an email.

The raw 'LoginId' constructor is not exported: the only way to build one is
'mkLoginId', which trims whitespace, lowercases the handle, and rejects the empty
string or any value containing internal whitespace. This makes invalid identifiers
unrepresentable outside this module, mirroring 'Shomei.Domain.Email'.
-}
module Shomei.Domain.LoginId (
    LoginId,
    mkLoginId,
    loginIdText,
    loginIdFromEmail,
) where

import Shomei.Prelude

import Data.Char (isSpace)
import Data.Text qualified as Text
import Shomei.Domain.Email (Email, emailText)
import Shomei.Error (AuthError (..))

newtype LoginId = LoginId Text
    deriving stock (Generic)
    deriving newtype (Eq, Ord, Show, FromJSON, ToJSON)

-- | Project the normalized identifier text.
loginIdText :: LoginId -> Text
loginIdText (LoginId t) = t

{- | Trim leading/trailing whitespace; lowercase the handle (case-insensitive
principal); reject the empty string and any value containing internal whitespace.
Does NOT require an @\@@ or a dot — a username principal is valid.
-}
mkLoginId :: Text -> Either AuthError LoginId
mkLoginId raw =
    let t = Text.toLower (Text.strip raw)
     in if Text.null t || Text.any isSpace t
            then Left InvalidLoginId
            else Right (LoginId t)

{- | Build a 'LoginId' from an already-validated 'Email' by taking its text. This is
the compatibility bridge — "identifier equals email by default". Since the email is
already normalized (trimmed, lowercased, no internal whitespace), this is total and
needs no re-validation.
-}
loginIdFromEmail :: Email -> LoginId
loginIdFromEmail = LoginId . emailText
