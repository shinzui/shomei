{- | The audit / security event vocabulary.

'AuthEvent' is the sum of everything worth recording for audit and intrusion
detection. Each arm carries a @*Data@ record with the relevant identifiers and the
@occurredAt@ timestamp. The 'Shomei.Effect.AuthEventPublisher' port publishes them; in
the bootstrap EP-3 persists them to the @shomei_auth_events@ table.

Note: several constructor names (e.g. 'SessionRevoked', 'RefreshTokenReuseDetected')
intentionally mirror 'Shomei.Error.AuthError' constructors and domain status
constructors. Consumers import this module qualified to disambiguate.
-}
module Shomei.Domain.Event (
    AuthEvent (..),
    UserRegisteredData (..),
    LoginSucceededData (..),
    LoginFailedData (..),
    SessionStartedData (..),
    SessionRevokedData (..),
    RefreshTokenRotatedData (..),
    RefreshTokenReuseDetectedData (..),
    PasswordChangedData (..),
    UserSuspendedData (..),
    UserDeletedData (..),
) where

import Shomei.Prelude

import Shomei.Domain.Email (Email)
import Shomei.Id (RefreshTokenId, SessionId, UserId)

data UserRegisteredData = UserRegisteredData
    { userId :: !UserId
    , email :: !Email
    , occurredAt :: !UTCTime
    }
    deriving stock (Generic, Eq, Show)
    deriving anyclass (FromJSON, ToJSON)

data LoginSucceededData = LoginSucceededData
    { userId :: !UserId
    , sessionId :: !SessionId
    , occurredAt :: !UTCTime
    }
    deriving stock (Generic, Eq, Show)
    deriving anyclass (FromJSON, ToJSON)

data LoginFailedData = LoginFailedData
    { email :: !Email
    , occurredAt :: !UTCTime
    }
    deriving stock (Generic, Eq, Show)
    deriving anyclass (FromJSON, ToJSON)

data SessionStartedData = SessionStartedData
    { sessionId :: !SessionId
    , userId :: !UserId
    , occurredAt :: !UTCTime
    }
    deriving stock (Generic, Eq, Show)
    deriving anyclass (FromJSON, ToJSON)

data SessionRevokedData = SessionRevokedData
    { sessionId :: !SessionId
    , occurredAt :: !UTCTime
    }
    deriving stock (Generic, Eq, Show)
    deriving anyclass (FromJSON, ToJSON)

data RefreshTokenRotatedData = RefreshTokenRotatedData
    { sessionId :: !SessionId
    , oldTokenId :: !RefreshTokenId
    , occurredAt :: !UTCTime
    }
    deriving stock (Generic, Eq, Show)
    deriving anyclass (FromJSON, ToJSON)

data RefreshTokenReuseDetectedData = RefreshTokenReuseDetectedData
    { sessionId :: !SessionId
    , refreshTokenId :: !RefreshTokenId
    , occurredAt :: !UTCTime
    }
    deriving stock (Generic, Eq, Show)
    deriving anyclass (FromJSON, ToJSON)

data PasswordChangedData = PasswordChangedData
    { userId :: !UserId
    , occurredAt :: !UTCTime
    }
    deriving stock (Generic, Eq, Show)
    deriving anyclass (FromJSON, ToJSON)

data UserSuspendedData = UserSuspendedData
    { userId :: !UserId
    , occurredAt :: !UTCTime
    }
    deriving stock (Generic, Eq, Show)
    deriving anyclass (FromJSON, ToJSON)

data UserDeletedData = UserDeletedData
    { userId :: !UserId
    , occurredAt :: !UTCTime
    }
    deriving stock (Generic, Eq, Show)
    deriving anyclass (FromJSON, ToJSON)

data AuthEvent
    = UserRegistered UserRegisteredData
    | LoginSucceeded LoginSucceededData
    | LoginFailed LoginFailedData
    | SessionStarted SessionStartedData
    | SessionRevoked SessionRevokedData
    | RefreshTokenRotated RefreshTokenRotatedData
    | RefreshTokenReuseDetected RefreshTokenReuseDetectedData
    | PasswordChanged PasswordChangedData
    | UserSuspended UserSuspendedData
    | UserDeleted UserDeletedData
    deriving stock (Generic, Eq, Show)
    deriving anyclass (FromJSON, ToJSON)
