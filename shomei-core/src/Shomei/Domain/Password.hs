{- | Password types and the pure password-policy validator.

'PlainPassword' is the user-supplied secret. It has a redacting 'Show' instance and
deliberately no JSON instances, so it is never logged, serialized, or persisted.
'PasswordHash' is the opaque hash produced by the 'Shomei.Effect.PasswordHasher' port
(Argon2id in production, EP-3).
-}
module Shomei.Domain.Password (
    PlainPassword (..),
    PasswordHash (..),
    PasswordPolicy (..),
    PasswordContext (..),
    emptyPasswordContext,
    defaultPasswordPolicy,
    validatePassword,
) where

import Shomei.Prelude

import Data.Text qualified as Text
import Shomei.Domain.CommonPasswords (isCommonPassword)
import Shomei.Error (PasswordPolicyViolation (..))

-- | Never logged, serialized, or persisted: redacting 'Show', no 'FromJSON'/'ToJSON'.
newtype PlainPassword = PlainPassword Text
    deriving stock (Generic)

instance Show PlainPassword where
    show _ = "PlainPassword <redacted>"

newtype PasswordHash = PasswordHash Text
    deriving stock (Generic)
    deriving newtype (Eq, Show, FromJSON, ToJSON)

data PasswordPolicy = PasswordPolicy
    { minLength :: !Int
    , maxLength :: !Int
    , rejectCommonPasswords :: !Bool -- consumed by EP-2 (docs/plans/21-...)
    , rejectContextualPasswords :: !Bool -- consumed by EP-2 (docs/plans/21-...)
    , breachCheckEnabled :: !Bool -- consumed by EP-3 (docs/plans/22-...)
    , breachCheckFailClosed :: !Bool -- consumed by EP-3 (docs/plans/22-...)
    , breachCheckTimeoutMs :: !Int -- consumed by EP-3 (docs/plans/22-...)
    }
    deriving stock (Generic, Eq, Show)
    deriving anyclass (FromJSON, ToJSON)

defaultPasswordPolicy :: PasswordPolicy
defaultPasswordPolicy =
    PasswordPolicy
        { minLength = 12
        , maxLength = 256
        , rejectCommonPasswords = True
        , rejectContextualPasswords = True
        , breachCheckEnabled = False
        , breachCheckFailClosed = False
        , breachCheckTimeoutMs = 1000
        }

-- | The identity context a password is checked against (for the contextual check).
data PasswordContext = PasswordContext
    { contextEmail :: !(Maybe Text)
    -- ^ the user's email address (raw text), if known
    , contextDisplayName :: !(Maybe Text)
    -- ^ the user's display name, if any
    }
    deriving stock (Generic, Eq, Show)

-- | No identity context (length and common-password checks still apply).
emptyPasswordContext :: PasswordContext
emptyPasswordContext = PasswordContext{contextEmail = Nothing, contextDisplayName = Nothing}

{- | Validate a password against the policy and the user's identity context. Check order:
length (cheap) first, then the common-password dictionary (if 'rejectCommonPasswords'),
then the contextual identity check (if 'rejectContextualPasswords').
-}
validatePassword ::
    PasswordPolicy -> PasswordContext -> PlainPassword -> Either PasswordPolicyViolation ()
validatePassword policy context (PlainPassword pw)
    | Text.length pw < policy.minLength = Left (PasswordTooShort policy.minLength)
    | Text.length pw > policy.maxLength = Left (PasswordTooLong policy.maxLength)
    | policy.rejectCommonPasswords && isCommonPassword pw = Left PasswordTooCommon
    | policy.rejectContextualPasswords && resemblesIdentity context pw = Left PasswordResemblesIdentity
    | otherwise = Right ()

{- | Does the password (trimmed, lowercased) exactly equal the user's email local-part,
full email, or display name (each trimmed, lowercased)? Exact equality only — no
substring rule, to avoid rejecting long passphrases that merely contain a short name.
-}
resemblesIdentity :: PasswordContext -> Text -> Bool
resemblesIdentity ctx pw =
    let p = Text.toLower (Text.strip pw)
        norm = Text.toLower . Text.strip
        emailCandidates = case ctx.contextEmail of
            Nothing -> []
            Just e -> let e' = norm e in [e', Text.takeWhile (/= '@') e']
        nameCandidates = maybe [] (\n -> [norm n]) ctx.contextDisplayName
     in not (Text.null p) && p `elem` (emailCandidates <> nameCandidates)
