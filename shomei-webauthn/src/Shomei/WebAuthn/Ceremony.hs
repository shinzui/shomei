{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}

-- | The real 'WebAuthnCeremony' interpreter, backed by the @tweag/webauthn@ library
-- (MasterPlan 3, EP-1 M2).
--
-- This is the infrastructure side of the IP-1 port: it owns every @webauthn@ library type
-- (@shomei-core@ never names one). 'runWebAuthnCeremonyLibrary' closes over the
-- 'WebAuthnConfig' Relying Party identity and:
--
--   * /begin/ steps build the library's 'WA.CredentialOptions', encode them with
--     @webauthn-json@ to the browser-facing JSON ('optionsJson') and to an opaque
--     persisted blob ('optionsBlob', the same JSON as bytes — EP-2 stores it);
--   * /complete/ steps decode the persisted options blob (via the exposed-internal
--     'WJI.decode'), decode the browser's credential JSON, run the library's
--     'WA.verifyRegistrationResponse' / 'WA.verifyAuthenticationResponse', and map the
--     result (or the library's error families) to the small closed 'WebAuthnError' set.
--
-- A potentially-cloned signature counter fails closed ('WebAuthnCounterCloned'), per the
-- EP-1 Decision Log. The Metadata Service registry is empty ('mempty') — consumer
-- passkeys with @attestation = none@; MDS trust is deferred per the MasterPlan scope.
--
-- Note: 'WebAuthnConfig' fields are read via their plain selectors (@rpId cfg@, …) rather
-- than @cfg.rpId@ record-dot, because GHC does not derive @HasField@ for these records
-- under @DuplicateRecordFields@.
module Shomei.WebAuthn.Ceremony (runWebAuthnCeremonyLibrary) where

import Control.Monad.Except (runExcept)
import Crypto.Hash (hash)
import Crypto.WebAuthn qualified as WA
import Crypto.WebAuthn.Encoding.Internal.WebAuthnJson qualified as WJI
import Crypto.WebAuthn.Encoding.Strings qualified as WStr
import Crypto.WebAuthn.Encoding.WebAuthnJson qualified as WJ
import Data.Aeson (Value, eitherDecodeStrict', encode, fromJSON, toJSON)
import Data.Aeson qualified as Aeson
import Data.Bifunctor (first)
import Data.ByteString (ByteString)
import Data.ByteString.Lazy qualified as LBS
import Data.List.NonEmpty (NonEmpty)
import Data.List.NonEmpty qualified as NE
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding (encodeUtf8)
import Data.Time (NominalDiffTime)
import Data.Validation (Validation (Failure, Success))
import Effectful (Eff, IOE, liftIO, (:>))
import Effectful.Dispatch.Dynamic (interpret_)
import Shomei.Config
  ( AttestationPolicy (..),
    UserVerificationPolicy (..),
    WebAuthnConfig,
    attestation,
    ceremonyTimeout,
    origins,
    rpId,
    rpName,
    userVerification,
  )
import Shomei.Domain.Passkey
  ( PublicKeyBytes (..),
    SignatureCounter (..),
    UserHandle (..),
    WebAuthnCredentialId (..),
  )
import Shomei.Effect.WebAuthnCeremony
  ( BeginCeremony (..),
    CredentialUserInfo (..),
    StoredCredentialForVerify (..),
    VerifiedAuthentication (..),
    VerifiedRegistration (..),
    WebAuthnCeremony (..),
    WebAuthnError (..),
  )
import Time.System (dateCurrent)

runWebAuthnCeremonyLibrary :: (IOE :> es) => WebAuthnConfig -> Eff (WebAuthnCeremony : es) a -> Eff es a
runWebAuthnCeremonyLibrary cfg = interpret_ \case
  BeginRegistrationCeremony userInfo excludeIds -> liftIO (beginRegistration cfg userInfo excludeIds)
  CompleteRegistrationCeremony blob credJson -> liftIO (completeRegistration cfg blob credJson)
  BeginAuthenticationCeremony allowIds -> liftIO (beginAuthentication cfg allowIds)
  CompleteAuthenticationCeremony blob stored credJson ->
    pure (completeAuthentication cfg blob stored credJson)

-- Begin steps -----------------------------------------------------------------

beginRegistration :: WebAuthnConfig -> CredentialUserInfo -> [WebAuthnCredentialId] -> IO BeginCeremony
beginRegistration cfg (CredentialUserInfo uh accountName displayName) excludeIds = do
  challenge <- WA.generateChallenge
  let opts =
        WA.CredentialOptionsRegistration
          { WA.corRp =
              WA.CredentialRpEntity
                { WA.creId = Just (WA.RpId (rpId cfg)),
                  WA.creName = WA.RelyingPartyName (rpName cfg)
                },
            WA.corUser =
              WA.CredentialUserEntity
                { WA.cueId = toWAUserHandle uh,
                  WA.cueDisplayName = WA.UserAccountDisplayName displayName,
                  WA.cueName = WA.UserAccountName accountName
                },
            WA.corChallenge = challenge,
            WA.corPubKeyCredParams =
              [ WA.CredentialParameters {WA.cpTyp = WA.CredentialTypePublicKey, WA.cpAlg = WA.CoseAlgorithmES256},
                WA.CredentialParameters {WA.cpTyp = WA.CredentialTypePublicKey, WA.cpAlg = WA.CoseAlgorithmRS256}
              ],
            WA.corTimeout = Just (mkTimeout (ceremonyTimeout cfg)),
            WA.corExcludeCredentials = map mkDescriptor excludeIds,
            WA.corAuthenticatorSelection =
              Just
                WA.AuthenticatorSelectionCriteria
                  { WA.ascAuthenticatorAttachment = Nothing,
                    WA.ascResidentKey = WA.ResidentKeyRequirementDiscouraged,
                    WA.ascUserVerification = mapUV (userVerification cfg)
                  },
            WA.corHints = [],
            WA.corAttestation = mapAttestation (attestation cfg),
            WA.corExtensions = Nothing
          }
      wjOpts = WJ.wjEncodeCredentialOptionsRegistration opts
  pure BeginCeremony {optionsJson = toJSON wjOpts, optionsBlob = LBS.toStrict (encode wjOpts)}

beginAuthentication :: WebAuthnConfig -> [WebAuthnCredentialId] -> IO BeginCeremony
beginAuthentication cfg allowIds = do
  challenge <- WA.generateChallenge
  let opts =
        WA.CredentialOptionsAuthentication
          { WA.coaRpId = Just (WA.RpId (rpId cfg)),
            WA.coaTimeout = Just (mkTimeout (ceremonyTimeout cfg)),
            WA.coaChallenge = challenge,
            WA.coaAllowCredentials = map mkDescriptor allowIds,
            WA.coaUserVerification = mapUV (userVerification cfg),
            WA.coaHints = [],
            WA.coaExtensions = Nothing
          }
      wjOpts = WJ.wjEncodeCredentialOptionsAuthentication opts
  pure BeginCeremony {optionsJson = toJSON wjOpts, optionsBlob = LBS.toStrict (encode wjOpts)}

-- Complete steps --------------------------------------------------------------

completeRegistration :: WebAuthnConfig -> ByteString -> Value -> IO (Either WebAuthnError VerifiedRegistration)
completeRegistration cfg blob credJson = do
  now <- dateCurrent
  pure do
    opts <- recoverRegistrationOptions blob
    cred <- decodeRegistrationCredential credJson
    case WA.verifyRegistrationResponse (originsOf cfg) (rpIdHashOf cfg) mempty now opts cred of
      Failure errs -> Left (mapRegError (NE.head errs))
      Success result -> Right (entryToRegistration (WA.rrEntry result))

completeAuthentication ::
  WebAuthnConfig ->
  ByteString ->
  StoredCredentialForVerify ->
  Value ->
  Either WebAuthnError VerifiedAuthentication
completeAuthentication cfg blob (StoredCredentialForVerify scid suh spk scnt strans) credJson = do
  opts <- recoverAuthenticationOptions blob
  cred <- decodeAuthenticationCredential credJson
  let entry =
        WA.CredentialEntry
          { WA.ceCredentialId = toWACredId scid,
            WA.ceUserHandle = toWAUserHandle suh,
            WA.cePublicKeyBytes = toWAPubKey spk,
            WA.ceSignCounter = toWACounter scnt,
            WA.ceTransports = map WStr.decodeAuthenticatorTransport strans
          }
  case WA.verifyAuthenticationResponse (originsOf cfg) (rpIdHashOf cfg) (Just (toWAUserHandle suh)) entry opts cred of
    Failure errs -> Left (mapAuthError (NE.head errs))
    Success (WA.AuthenticationResult counterResult) -> case counterResult of
      WA.SignatureCounterZero -> Right (verifiedAuth scid scnt)
      WA.SignatureCounterUpdated c -> Right (verifiedAuth scid (SignatureCounter (WA.unSignatureCounter c)))
      WA.SignatureCounterPotentiallyCloned -> Left WebAuthnCounterCloned
  where
    verifiedAuth cid newCounter =
      VerifiedAuthentication {credentialId = cid, newSignCounter = newCounter, cloneWarning = False}

-- Options / credential (de)serialization --------------------------------------

recoverRegistrationOptions :: ByteString -> Either WebAuthnError (WA.CredentialOptions 'WA.Registration)
recoverRegistrationOptions blob = do
  wjOpts <- first (WebAuthnDecodeError . Text.pack) (eitherDecodeStrict' blob)
  first WebAuthnDecodeError (runExcept (WJI.decode (WJ._unWJCredentialOptionsRegistration wjOpts)))

recoverAuthenticationOptions :: ByteString -> Either WebAuthnError (WA.CredentialOptions 'WA.Authentication)
recoverAuthenticationOptions blob = do
  wjOpts <- first (WebAuthnDecodeError . Text.pack) (eitherDecodeStrict' blob)
  first WebAuthnDecodeError (runExcept (WJI.decode (WJ._unWJCredentialOptionsAuthentication wjOpts)))

decodeRegistrationCredential :: Value -> Either WebAuthnError (WA.Credential 'WA.Registration 'True)
decodeRegistrationCredential v = do
  wjCred <- case fromJSON v of
    Aeson.Success c -> Right c
    Aeson.Error e -> Left (WebAuthnDecodeError (Text.pack e))
  first (WebAuthnDecodeError . Text.pack . show) (WJ.wjDecodeCredentialRegistration wjCred)

decodeAuthenticationCredential :: Value -> Either WebAuthnError (WA.Credential 'WA.Authentication 'True)
decodeAuthenticationCredential v = do
  wjCred <- case fromJSON v of
    Aeson.Success c -> Right c
    Aeson.Error e -> Left (WebAuthnDecodeError (Text.pack e))
  first (WebAuthnDecodeError . Text.pack . show) (WJ.wjDecodeCredentialAuthentication wjCred)

entryToRegistration :: WA.CredentialEntry -> VerifiedRegistration
entryToRegistration e =
  VerifiedRegistration
    { credentialId = WebAuthnCredentialId (WA.unCredentialId (WA.ceCredentialId e)),
      userHandle = UserHandle (WA.unUserHandle (WA.ceUserHandle e)),
      publicKey = PublicKeyBytes (WA.unPublicKeyBytes (WA.cePublicKeyBytes e)),
      signCounter = SignatureCounter (WA.unSignatureCounter (WA.ceSignCounter e)),
      transports = map WStr.encodeAuthenticatorTransport (WA.ceTransports e)
    }

-- RP identity / policy mapping ------------------------------------------------

originsOf :: WebAuthnConfig -> NonEmpty WA.Origin
originsOf cfg = NE.fromList (map WA.Origin (origins cfg))

rpIdHashOf :: WebAuthnConfig -> WA.RpIdHash
rpIdHashOf cfg = WA.RpIdHash (hash (encodeUtf8 (rpId cfg)))

mkTimeout :: NominalDiffTime -> WA.Timeout
mkTimeout dt = WA.Timeout (round (realToFrac dt * 1000 :: Double))

mkDescriptor :: WebAuthnCredentialId -> WA.CredentialDescriptor
mkDescriptor cid =
  WA.CredentialDescriptor
    { WA.cdTyp = WA.CredentialTypePublicKey,
      WA.cdId = toWACredId cid,
      WA.cdTransports = Nothing
    }

mapUV :: UserVerificationPolicy -> WA.UserVerificationRequirement
mapUV UVRequired = WA.UserVerificationRequirementRequired
mapUV UVPreferred = WA.UserVerificationRequirementPreferred
mapUV UVDiscouraged = WA.UserVerificationRequirementDiscouraged

mapAttestation :: AttestationPolicy -> WA.AttestationConveyancePreference
mapAttestation AttestationNone = WA.AttestationConveyancePreferenceNone
mapAttestation AttestationDirect = WA.AttestationConveyancePreferenceDirect

-- Type bridges (Shōmei domain <-> webauthn newtypes) --------------------------

toWAUserHandle :: UserHandle -> WA.UserHandle
toWAUserHandle (UserHandle bs) = WA.UserHandle bs

toWACredId :: WebAuthnCredentialId -> WA.CredentialId
toWACredId (WebAuthnCredentialId bs) = WA.CredentialId bs

toWAPubKey :: PublicKeyBytes -> WA.PublicKeyBytes
toWAPubKey (PublicKeyBytes bs) = WA.PublicKeyBytes bs

toWACounter :: SignatureCounter -> WA.SignatureCounter
toWACounter (SignatureCounter w) = WA.SignatureCounter w

-- Error mapping ---------------------------------------------------------------

mapRegError :: WA.RegistrationError -> WebAuthnError
mapRegError = \case
  WA.RegistrationChallengeMismatch {} -> WebAuthnChallengeMismatch
  WA.RegistrationOriginMismatch {} -> WebAuthnOriginMismatch
  WA.RegistrationRpIdHashMismatch {} -> WebAuthnRpIdMismatch
  WA.RegistrationUserNotPresent {} -> WebAuthnUserNotPresent
  WA.RegistrationUserNotVerified {} -> WebAuthnUserNotVerified
  err -> WebAuthnOtherError (Text.pack (show err))

mapAuthError :: WA.AuthenticationError -> WebAuthnError
mapAuthError = \case
  WA.AuthenticationChallengeMismatch {} -> WebAuthnChallengeMismatch
  WA.AuthenticationOriginMismatch {} -> WebAuthnOriginMismatch
  WA.AuthenticationRpIdHashMismatch {} -> WebAuthnRpIdMismatch
  WA.AuthenticationUserNotPresent {} -> WebAuthnUserNotPresent
  WA.AuthenticationUserNotVerified {} -> WebAuthnUserNotVerified
  WA.AuthenticationSignatureInvalid {} -> WebAuthnSignatureInvalid
  err -> WebAuthnOtherError (Text.pack (show err))
