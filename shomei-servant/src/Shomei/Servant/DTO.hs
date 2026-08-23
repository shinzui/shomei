-- | Request/response JSON DTOs for 'Shomei.Servant.API.ShomeiAPI' (MasterPlan IP-6).
--
-- A pure wire contract: no 'Handler', no 'Eff'. The mapping functions
-- ('userToResponse', 'tokenPairToResponse', 'sessionToResponse') render the EP-2
-- domain types into these wire shapes — identifiers as their TypeID text, emails as
-- their normalized text, status lowercased, timestamps as ISO-8601, and the
-- access-token lifetime as whole seconds.
module Shomei.Servant.DTO
  ( SignupRequest (..),
    SignupResponse (..),
    LoginRequest (..),
    LoginResponse (..),
    RefreshRequest (..),
    VerifyEmailRequest (..),
    ConfirmEmailVerificationRequest (..),
    PasswordResetRequest (..),
    ConfirmPasswordResetRequest (..),
    ChangePasswordRequest (..),
    TokenPairResponse (..),
    UserResponse (..),
    SessionResponse (..),
    HealthResponse (..),
    ReadyResponse (..),
    PasskeyRegisterBeginResponse (..),
    PasskeyRegisterCompleteRequest (..),
    PasskeyResponse (..),
    MfaProof (..),
    MfaCompleteRequest (..),
    mfaCompletionOf,
    TotpEnrollResponse (..),
    TotpVerifyRequest (..),
    TotpRemoveRequest (..),
    totpRemovalProofOf,
    RecoveryCodesResponse (..),
    RecoveryCodesCountResponse (..),
    PasskeyLoginBeginResponse (..),
    PasskeyLoginCompleteRequest (..),
    AuditEventResponse (..),
    AuditEventsPage (..),
    AdminUserResponse (..),
    AdminUsersPage (..),
    adminUserToResponse,
    userToResponse,
    tokenPairToResponse,
    sessionToResponse,
    passkeyToResponse,
    loginResultToResponse,
    storedToResponse,
    encodeCursor,
    decodeCursor,
    encodeUserCursor,
    decodeUserCursor,
  )
where

import Data.Aeson (Value, object, withObject, (.:), (.:?))
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KM
import Data.Aeson.Types (Parser)
import Data.List (sort)
import Data.Maybe (catMaybes, isJust)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text qualified as Text
import Data.Time.Format.ISO8601 (iso8601ParseM, iso8601Show)
import Data.UUID qualified as UUID
import Shomei.Account.Email.Domain (emailText)
import Shomei.Account.LoginId.Domain (loginIdText)
import Shomei.Account.User.Domain (User (..), UserStatus (..))
import Shomei.Account.User.Store (UserCursor (..))
import Shomei.Audit.Reader.Store (AuditCursor (..), StoredAuthEvent (..))
import Shomei.Authorization.Claims.Domain (Role (..))
import Shomei.Config (ShomeiConfig (..), transportIncludesBodyTokens)
import Shomei.Id (idText, userIdFromUUID, userIdToUUID)
import Shomei.Mfa.Totp.Workflow (TotpRemovalProof (..))
import Shomei.Mfa.Workflow (MfaCompletion (..))
import Shomei.Passkey.Domain (PasskeyCredential (..))
import Shomei.Prelude
import Shomei.Session.Authentication.Workflow (LoginResult (..), MfaChallenge (..))
import Shomei.Session.Domain (Session (..), SessionStatus (..))
import Shomei.Session.RefreshToken.Domain (RefreshToken (..))
import Shomei.Session.Token.Domain (AccessToken (..), TokenPair (..))

-- | @POST /v1/auth/signup@ body. The principal is @loginId@; @email@ is optional.
data SignupRequest = SignupRequest
  { loginId :: !Text,
    email :: !(Maybe Text),
    password :: !Text,
    displayName :: !Text
  }
  deriving stock (Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | A token pair as wire JSON: @{ accessToken, refreshToken, expiresIn }@.
--
-- The token fields are absent in cookie-only transport, where the values live in @HttpOnly@
-- cookies instead. They are __omitted__, not null or empty: the honest wire shape for "there
-- is no body token", and one an XSS payload cannot read. @expiresIn@ is always present.
data TokenPairResponse = TokenPairResponse
  { accessToken :: !(Maybe Text),
    refreshToken :: !(Maybe Text),
    expiresIn :: !Int
  }
  deriving stock (Generic)

instance ToJSON TokenPairResponse where
  toJSON r =
    object $
      catMaybes
        [ ("accessToken" Aeson..=) <$> r.accessToken,
          ("refreshToken" Aeson..=) <$> r.refreshToken,
          Just ("expiresIn" Aeson..= r.expiresIn)
        ]

instance FromJSON TokenPairResponse where
  parseJSON = withObject "TokenPairResponse" \o ->
    TokenPairResponse
      <$> o Aeson..:? "accessToken"
      <*> o Aeson..:? "refreshToken"
      <*> o .: "expiresIn"

-- | A user as wire JSON: @{ userId, loginId, email, displayName, status }@ (status lowercased).
data UserResponse = UserResponse
  { userId :: !Text,
    loginId :: !Text,
    email :: !(Maybe Text),
    displayName :: !Text,
    status :: !Text
  }
  deriving stock (Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | @POST /v1/auth/signup@ response: the user + the token pair.
data SignupResponse = SignupResponse
  { user :: !UserResponse,
    token :: !TokenPairResponse
  }
  deriving stock (Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | @POST /v1/auth/login@ body. Log in by the required @loginId@ principal.
data LoginRequest = LoginRequest
  { loginId :: !Text,
    password :: !Text
  }
  deriving stock (Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | @POST /v1/auth/login@ response. Either a completed login (user + token
-- under a @"complete"@ tag) or an MFA challenge (a ceremony id + WebAuthn @get()@ options, no
-- token). The wire JSON is a flat, @status@-tagged object:
--
-- @{ "status":"complete",     "user":{…}, "token":{…} }@
-- @{ "status":"mfa_required", "ceremonyId":"…", "options":{…} }@
--
-- A sum (not a record with nullable token fields) makes the two outcomes mutually exclusive at
-- the type level — a caller cannot read a token out of an MFA challenge. The instances are
-- hand-written so the wire shape is exactly the documented flat object.
data LoginResponse
  = LoginCompleteResponse
      { user :: !UserResponse,
        token :: !TokenPairResponse
      }
  | LoginMfaRequiredResponse
      { ceremonyId :: !Text,
        options :: !Value,
        -- | which factors can complete this challenge: @"passkey"@, @"totp"@, @"recovery_code"@
        methods :: ![Text]
      }
  deriving stock (Generic)

instance ToJSON LoginResponse where
  toJSON = \case
    LoginCompleteResponse u t ->
      object ["status" Aeson..= ("complete" :: Text), "user" Aeson..= u, "token" Aeson..= t]
    LoginMfaRequiredResponse cid opts methods ->
      object
        [ "status" Aeson..= ("mfa_required" :: Text),
          "ceremonyId" Aeson..= cid,
          "options" Aeson..= opts,
          "methods" Aeson..= methods
        ]

instance FromJSON LoginResponse where
  parseJSON = withObject "LoginResponse" \o -> do
    status <- o .: "status" :: Parser Text
    case status of
      "complete" -> LoginCompleteResponse <$> o .: "user" <*> o .: "token"
      "mfa_required" ->
        LoginMfaRequiredResponse
          <$> o .: "ceremonyId"
          <*> o .: "options"
          <*> o .: "methods"
      other -> fail ("unknown login status: " <> Text.unpack other)

-- | The proof used to complete an MFA challenge. Its wire representation is a tagged object.
data MfaProof
  = PasskeyProof {assertion :: !Value}
  | TotpProof {code :: !Text}
  | RecoveryCodeProof {code :: !Text}
  deriving stock (Generic)

instance FromJSON MfaProof where
  parseJSON = withObject "MfaProof" \o -> do
    proofType <- o .: "type" :: Parser Text
    case proofType of
      "passkey" -> requireProofKeys ["assertion", "type"] o >> PasskeyProof <$> o .: "assertion"
      "totp" -> requireProofKeys ["code", "type"] o >> TotpProof <$> o .: "code"
      "recovery_code" -> requireProofKeys ["code", "type"] o >> RecoveryCodeProof <$> o .: "code"
      other -> fail ("unknown MFA proof type: " <> Text.unpack other)
    where
      requireProofKeys expected o =
        let actual = sort (map Key.toText (KM.keys o))
         in unless (actual == expected) $ fail "MFA proof contains missing or unexpected fields"

instance ToJSON MfaProof where
  toJSON = \case
    PasskeyProof assertion ->
      object ["type" Aeson..= ("passkey" :: Text), "assertion" Aeson..= assertion]
    TotpProof code ->
      object ["type" Aeson..= ("totp" :: Text), "code" Aeson..= code]
    RecoveryCodeProof code ->
      object ["type" Aeson..= ("recovery_code" :: Text), "code" Aeson..= code]

-- | @POST /v1/auth/mfa/complete@ body: the ceremony id and one explicitly tagged proof.
data MfaCompleteRequest = MfaCompleteRequest
  { ceremonyId :: !Text,
    proof :: !MfaProof
  }
  deriving stock (Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | Map the tagged wire proof to the core completion type.
mfaCompletionOf :: MfaCompleteRequest -> MfaCompletion
mfaCompletionOf MfaCompleteRequest {proof} = case proof of
  PasskeyProof assertion -> MfaPasskey assertion
  TotpProof code -> MfaTotp code
  RecoveryCodeProof code -> MfaRecoveryCode code

-- | @POST /v1/auth/totp/enroll@ response: the Base32 secret (shown once) and the @otpauth://@ URI.
data TotpEnrollResponse = TotpEnrollResponse
  { secret :: !Text,
    otpauthUri :: !Text
  }
  deriving stock (Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | @POST /v1/auth/totp/verify@ body: the first valid code that activates an enrollment.
newtype TotpVerifyRequest = TotpVerifyRequest {code :: Text}
  deriving stock (Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | @DELETE /v1/auth/totp@ body: proof of possession — __exactly one__ of a current @code@ or a
-- @recoveryCode@.
data TotpRemoveRequest = TotpRemoveRequest
  { code :: !(Maybe Text),
    recoveryCode :: !(Maybe Text)
  }
  deriving stock (Generic)

instance FromJSON TotpRemoveRequest where
  parseJSON = withObject "TotpRemoveRequest" \o -> do
    code <- o .:? "code"
    recoveryCode <- o .:? "recoveryCode"
    case (isJust code, isJust recoveryCode) of
      (True, False) -> pure (TotpRemoveRequest code recoveryCode)
      (False, True) -> pure (TotpRemoveRequest code recoveryCode)
      _ -> fail "exactly one of code, recoveryCode must be present"

instance ToJSON TotpRemoveRequest where
  toJSON (TotpRemoveRequest c r) =
    object (catMaybes [("code" Aeson..=) <$> c, ("recoveryCode" Aeson..=) <$> r])

-- | The core 'TotpRemovalProof' a decoded request maps to (exactly-one is enforced by @FromJSON@).
totpRemovalProofOf :: TotpRemoveRequest -> TotpRemovalProof
totpRemovalProofOf (TotpRemoveRequest c r) = case (c, r) of
  (Just code, _) -> RemoveWithCode code
  (_, Just code) -> RemoveWithRecoveryCode code
  _ -> RemoveWithCode ""

-- | @POST /v1/auth/recovery-codes@ response: the freshly generated plaintext codes (shown once).
newtype RecoveryCodesResponse = RecoveryCodesResponse {codes :: [Text]}
  deriving stock (Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | @GET /v1/auth/recovery-codes@ response: how many unused codes remain.
newtype RecoveryCodesCountResponse = RecoveryCodesCountResponse {remaining :: Int}
  deriving stock (Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | @POST /v1/auth/login/passkey/begin@ response: the ceremony id + the @get()@ options.
data PasskeyLoginBeginResponse = PasskeyLoginBeginResponse
  { ceremonyId :: !Text,
    options :: !Value
  }
  deriving stock (Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | @POST /v1/auth/login/passkey/complete@ body: the ceremony id from begin + the assertion JSON.
data PasskeyLoginCompleteRequest = PasskeyLoginCompleteRequest
  { ceremonyId :: !Text,
    assertion :: !Value
  }
  deriving stock (Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | @POST /v1/auth/refresh@ body: the opaque refresh token.
--
-- Optional, because in cookie transport the token arrives in the @shomei_refresh@ cookie and
-- a browser client posts @{}@. A present body value takes precedence, so bearer clients are
-- unaffected and mixed-mode is deterministic.
newtype RefreshRequest = RefreshRequest {refreshToken :: Maybe Text}
  deriving stock (Generic)
  deriving anyclass (FromJSON, ToJSON)

newtype VerifyEmailRequest = VerifyEmailRequest {email :: Text}
  deriving stock (Generic)
  deriving anyclass (FromJSON, ToJSON)

newtype ConfirmEmailVerificationRequest = ConfirmEmailVerificationRequest {token :: Text}
  deriving stock (Generic)
  deriving anyclass (FromJSON, ToJSON)

newtype PasswordResetRequest = PasswordResetRequest {email :: Text}
  deriving stock (Generic)
  deriving anyclass (FromJSON, ToJSON)

data ConfirmPasswordResetRequest = ConfirmPasswordResetRequest
  { token :: !Text,
    newPassword :: !Text
  }
  deriving stock (Generic)
  deriving anyclass (FromJSON, ToJSON)

data ChangePasswordRequest = ChangePasswordRequest
  { currentPassword :: !Text,
    newPassword :: !Text
  }
  deriving stock (Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | @GET /v1/auth/session@ response.
data SessionResponse = SessionResponse
  { sessionId :: !Text,
    userId :: !Text,
    createdAt :: !Text,
    expiresAt :: !Text,
    -- | @active@ | @revoked@ | @expired@. Added by EP-2: an administrator listing a user's
    --     sessions must be able to tell a live one from a corpse, and the caller of
    --     @GET \/v1\/auth\/session@ benefits equally. Additive on the wire.
    status :: !Text,
    revokedAt :: !(Maybe Text)
  }
  deriving stock (Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | @GET /health@ response.
newtype HealthResponse = HealthResponse {status :: Text}
  deriving stock (Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | @GET /ready@ response (EP-3): which readiness checks passed.
data ReadyResponse = ReadyResponse
  { status :: !Text,
    database :: !Bool,
    signingKey :: !Bool
  }
  deriving stock (Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | @POST /v1/auth/passkeys/register/begin@ response: the ceremony id (echoed back at
-- complete) and the WebAuthn creation options the browser feeds to
-- @navigator.credentials.create()@.
data PasskeyRegisterBeginResponse = PasskeyRegisterBeginResponse
  { ceremonyId :: !Text,
    options :: !Value
  }
  deriving stock (Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | @POST /v1/auth/passkeys/register/complete@ body: the ceremony id from begin, the
-- browser's credential JSON verbatim (the @webauthn-json@ registration response), and an
-- optional label.
data PasskeyRegisterCompleteRequest = PasskeyRegisterCompleteRequest
  { ceremonyId :: !Text,
    credential :: !Value,
    label :: !(Maybe Text)
  }
  deriving stock (Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | A stored passkey as wire JSON. Never includes the public-key bytes.
data PasskeyResponse = PasskeyResponse
  { passkeyId :: !Text,
    label :: !(Maybe Text),
    transports :: ![Text],
    createdAt :: !Text,
    lastUsedAt :: !(Maybe Text)
  }
  deriving stock (Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | Render a domain 'PasskeyCredential' to its wire DTO (no public-key bytes).
passkeyToResponse :: PasskeyCredential -> PasskeyResponse
passkeyToResponse PasskeyCredential {passkeyId, label, transports, createdAt, lastUsedAt} =
  PasskeyResponse
    { passkeyId = idText passkeyId,
      label = label,
      transports = transports,
      createdAt = Text.pack (iso8601Show createdAt),
      lastUsedAt = Text.pack . iso8601Show <$> lastUsedAt
    }

-- | Render a domain 'User' to the wire DTO.
userToResponse :: User -> UserResponse
userToResponse u =
  UserResponse
    { userId = idText u.userId,
      loginId = loginIdText u.loginId,
      email = emailText <$> u.email,
      displayName = fromMaybe "" u.displayName,
      status = renderStatus u.status
    }
  where
    renderStatus UserActive = "active"
    renderStatus UserSuspended = "suspended"
    renderStatus UserDeleted = "deleted"

-- | Render a domain 'TokenPair' to the wire DTO (lifetime as whole seconds).
--
-- Token values appear in the body only when the configured transport puts them there. In
-- cookie-only mode they are omitted and travel as @Set-Cookie@ headers instead.
tokenPairToResponse :: ShomeiConfig -> TokenPair -> TokenPairResponse
tokenPairToResponse cfg tp =
  TokenPairResponse
    { accessToken = whenBodyTokens (unAccess tp.accessToken),
      refreshToken = whenBodyTokens (unRefresh tp.refreshToken),
      expiresIn = round (realToFrac tp.expiresIn :: Double)
    }
  where
    whenBodyTokens t = if transportIncludesBodyTokens cfg.tokenTransport then Just t else Nothing
    unAccess (AccessToken t) = t
    unRefresh (RefreshToken t) = t

-- | Map the core 'LoginResult' to the wire 'LoginResponse'. 'MfaChallenge' is read via a
-- record pattern (not @ch.ceremonyId@ dot syntax) for consistency with the rest of the
-- passkey-touching code.
loginResultToResponse :: ShomeiConfig -> LoginResult -> LoginResponse
loginResultToResponse cfg = \case
  LoginComplete user pair ->
    LoginCompleteResponse {user = userToResponse user, token = tokenPairToResponse cfg pair}
  MfaRequired (MfaChallenge cid opts methods) ->
    LoginMfaRequiredResponse {ceremonyId = idText cid, options = opts, methods = methods}

-- | One audit-trail row as wire JSON. The envelope columns plus the raw event 'payload'
-- (passed through verbatim — the read path never reshapes the stored JSON). Identifiers are
-- rendered as UUID text; @createdAt@ is ISO-8601.
data AuditEventResponse = AuditEventResponse
  { eventId :: !Text,
    eventType :: !Text,
    userId :: !(Maybe Text),
    sessionId :: !(Maybe Text),
    createdAt :: !Text,
    payload :: !Value
  }
  deriving stock (Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | A page of audit events plus an opaque 'nextCursor'. A non-'Nothing' cursor is passed
-- back as @?before=@ to fetch the next (older) page; it is 'Nothing' when the page was not
-- full (i.e. the last page).
data AuditEventsPage = AuditEventsPage
  { events :: ![AuditEventResponse],
    nextCursor :: !(Maybe Text)
  }
  deriving stock (Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | Render a 'StoredAuthEvent' to its wire DTO (raw payload passed through).
storedToResponse :: StoredAuthEvent -> AuditEventResponse
storedToResponse s =
  AuditEventResponse
    { eventId = UUID.toText s.storedEventId,
      eventType = s.storedEventType,
      userId = UUID.toText <$> s.storedUserId,
      sessionId = UUID.toText <$> s.storedSessionId,
      createdAt = Text.pack (iso8601Show s.storedCreatedAt),
      payload = s.storedPayload
    }

-- | The opaque keyset cursor wire format: @"\<iso8601Z\>;\<uuid\>"@ — the
-- @(created_at, event_id)@ of the last row of a page. 'encodeCursor'/'decodeCursor' are
-- total inverses; a malformed cursor decodes to 'Nothing' (the handler maps that to 400).
encodeCursor :: AuditCursor -> Text
encodeCursor c = Text.pack (iso8601Show c.cursorCreatedAt) <> ";" <> UUID.toText c.cursorEventId

decodeCursor :: Text -> Maybe AuditCursor
decodeCursor t = case Text.breakOn ";" t of
  (tsPart, rest)
    | Just idPart <- Text.stripPrefix ";" rest -> do
        ts <- iso8601ParseM (Text.unpack tsPart)
        eid <- UUID.fromText idPart
        pure (AuditCursor ts eid)
  _ -> Nothing

-- | The user-listing cursor rides the same @"\<iso8601Z\>;\<uuid\>"@ wire format, over
-- @(created_at, user_id)@. One format, one parser: a client cannot tell the two cursors apart, and
-- neither can be fed to the wrong endpoint without failing to decode into something meaningful.
encodeUserCursor :: UserCursor -> Text
encodeUserCursor c = encodeCursor (AuditCursor c.cursorCreatedAt (userIdToUUID c.cursorUserId))

decodeUserCursor :: Text -> Maybe UserCursor
decodeUserCursor t = do
  AuditCursor ts uuid <- decodeCursor t
  pure (UserCursor ts (userIdFromUUID uuid))

-- | @GET \/v1\/admin\/users\/{userId}@: the user plus the roles actually granted to them in the
-- store. The roles are the persistent grants, not whatever an outstanding token happens to carry.
data AdminUserResponse = AdminUserResponse
  { user :: !UserResponse,
    roles :: ![Text]
  }
  deriving stock (Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | @GET \/v1\/admin\/users@: one keyset page. @nextCursor@ is present only when this page came
-- back full, i.e. when there may be more; pass it back as @?before=@.
data AdminUsersPage = AdminUsersPage
  { users :: ![UserResponse],
    nextCursor :: !(Maybe Text)
  }
  deriving stock (Generic)
  deriving anyclass (FromJSON, ToJSON)

adminUserToResponse :: User -> Set Role -> AdminUserResponse
adminUserToResponse u roles =
  AdminUserResponse
    { user = userToResponse u,
      roles = sort [r | Role r <- Set.toList roles]
    }

-- | Render a domain 'Session' to the wire DTO (timestamps as ISO-8601).
sessionToResponse :: Session -> SessionResponse
sessionToResponse s =
  SessionResponse
    { sessionId = idText s.sessionId,
      userId = idText s.userId,
      createdAt = Text.pack (iso8601Show s.createdAt),
      expiresAt = Text.pack (iso8601Show s.expiresAt),
      status = renderSessionStatus s.status,
      revokedAt = Text.pack . iso8601Show <$> s.revokedAt
    }
  where
    renderSessionStatus SessionActive = "active"
    renderSessionStatus SessionRevoked = "revoked"
    renderSessionStatus SessionExpired = "expired"
