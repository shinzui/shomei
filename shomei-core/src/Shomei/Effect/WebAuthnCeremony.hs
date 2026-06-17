{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE TypeFamilies #-}

{- | The WebAuthn ceremony port (MasterPlan 3, IP-1).

A passkey is a public-key credential a browser creates with
@navigator.credentials.create()@ and proves possession of with
@navigator.credentials.get()@. Each exchange is a /ceremony/ with a /begin/ step
(the server emits options carrying a random challenge) and a /complete/ step (the
server verifies the browser's signed response).

This port lets 'Shomei.Workflow' code orchestrate those ceremonies without
@shomei-core@ ever importing the heavy @webauthn@ library: its operations cross the
package boundary using only aeson 'Value' (the browser-facing @webauthn-json@
payloads, already a core dependency) plus the 'Shomei.Domain.Passkey' domain types.
The real interpreter (@runWebAuthnCeremonyLibrary@ in @shomei-webauthn@) does the
encode/decode/verify against the library; a deterministic fake
('Shomei.Effect.InMemory.runWebAuthnCeremonyFake') drives tests without cryptography.
-}
module Shomei.Effect.WebAuthnCeremony (
    WebAuthnCeremony (..),
    WebAuthnError (..),
    CredentialUserInfo (..),
    BeginCeremony (..),
    StoredCredentialForVerify (..),
    VerifiedRegistration (..),
    VerifiedAuthentication (..),
    beginRegistrationCeremony,
    completeRegistrationCeremony,
    beginAuthenticationCeremony,
    completeAuthenticationCeremony,
) where

import Shomei.Prelude

import Data.Aeson (Value)
import Data.ByteString (ByteString)
import Effectful (Dispatch (Dynamic), DispatchOf, Eff, Effect, (:>))
import Effectful.Dispatch.Dynamic (send)
import Shomei.Domain.Passkey (
    PublicKeyBytes,
    SignatureCounter,
    UserHandle,
    WebAuthnCredentialId,
 )

{- | The verification failure modes, mapped from the library's
RegistrationError/AuthenticationError families to a small stable closed set.
-}
data WebAuthnError
    = WebAuthnDecodeError Text
    | WebAuthnChallengeMismatch
    | WebAuthnOriginMismatch
    | WebAuthnRpIdMismatch
    | WebAuthnUserNotPresent
    | WebAuthnUserNotVerified
    | WebAuthnSignatureInvalid
    | WebAuthnCounterCloned
    | WebAuthnOtherError Text
    deriving stock (Generic, Eq, Show)
    deriving anyclass (FromJSON, ToJSON)

-- | The user identity baked into a registration's options.
data CredentialUserInfo = CredentialUserInfo
    { userHandle :: !UserHandle
    , accountName :: !Text
    , displayName :: !Text
    }
    deriving stock (Generic, Eq, Show)

{- | The two outputs of a begin step: the JSON for the browser and the opaque
blob for PendingCeremonyStore (EP-2).
-}
data BeginCeremony = BeginCeremony
    { optionsJson :: !Value
    , optionsBlob :: !ByteString
    }
    deriving stock (Generic, Eq, Show)

{- | The stored fields the authentication verify step needs (EP-4 reads them
from PasskeyStore and hands them here).
-}
data StoredCredentialForVerify = StoredCredentialForVerify
    { credentialId :: !WebAuthnCredentialId
    , userHandle :: !UserHandle
    , publicKey :: !PublicKeyBytes
    , signCounter :: !SignatureCounter
    , transports :: ![Text]
    }
    deriving stock (Generic, Eq, Show)

data VerifiedRegistration = VerifiedRegistration
    { credentialId :: !WebAuthnCredentialId
    , userHandle :: !UserHandle
    , publicKey :: !PublicKeyBytes
    , signCounter :: !SignatureCounter
    , transports :: ![Text]
    }
    deriving stock (Generic, Eq, Show)

data VerifiedAuthentication = VerifiedAuthentication
    { credentialId :: !WebAuthnCredentialId
    , newSignCounter :: !SignatureCounter
    , cloneWarning :: !Bool
    }
    deriving stock (Generic, Eq, Show)

data WebAuthnCeremony :: Effect where
    -- 2nd arg = excludeCredentials (ids already enrolled for this user).
    BeginRegistrationCeremony
        :: CredentialUserInfo -> [WebAuthnCredentialId] -> WebAuthnCeremony m BeginCeremony
    -- optionsBlob, then the browser's credential JSON.
    CompleteRegistrationCeremony
        :: ByteString -> Value -> WebAuthnCeremony m (Either WebAuthnError VerifiedRegistration)
    -- allowCredentials ([] = passwordless discovery).
    BeginAuthenticationCeremony
        :: [WebAuthnCredentialId] -> WebAuthnCeremony m BeginCeremony
    CompleteAuthenticationCeremony
        :: ByteString -> StoredCredentialForVerify -> Value
        -> WebAuthnCeremony m (Either WebAuthnError VerifiedAuthentication)

type instance DispatchOf WebAuthnCeremony = Dynamic

beginRegistrationCeremony
    :: (WebAuthnCeremony :> es) => CredentialUserInfo -> [WebAuthnCredentialId] -> Eff es BeginCeremony
beginRegistrationCeremony u xs = send (BeginRegistrationCeremony u xs)

completeRegistrationCeremony
    :: (WebAuthnCeremony :> es) => ByteString -> Value -> Eff es (Either WebAuthnError VerifiedRegistration)
completeRegistrationCeremony b v = send (CompleteRegistrationCeremony b v)

beginAuthenticationCeremony
    :: (WebAuthnCeremony :> es) => [WebAuthnCredentialId] -> Eff es BeginCeremony
beginAuthenticationCeremony = send . BeginAuthenticationCeremony

completeAuthenticationCeremony
    :: (WebAuthnCeremony :> es)
    => ByteString -> StoredCredentialForVerify -> Value -> Eff es (Either WebAuthnError VerifiedAuthentication)
completeAuthenticationCeremony b c v = send (CompleteAuthenticationCeremony b c v)
