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
    defaultPasswordPolicy,
    validatePassword,
) where

import Shomei.Prelude

import Data.Text qualified as Text
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

validatePassword :: PasswordPolicy -> PlainPassword -> Either PasswordPolicyViolation ()
validatePassword policy (PlainPassword pw)
    | Text.length pw < policy.minLength = Left (PasswordTooShort policy.minLength)
    | Text.length pw > policy.maxLength = Left (PasswordTooLong policy.maxLength)
    | otherwise = Right ()
