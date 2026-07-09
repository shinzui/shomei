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
    MfaCompleteRequest (..),
    PasskeyLoginBeginResponse (..),
    PasskeyLoginCompleteRequest (..),
    ImpersonateRequest (..),
    ImpersonateResponse (..),
    ServiceTokenRequest (..),
    ServiceTokenResponse (..),
    AuditEventResponse (..),
    AuditEventsPage (..),
    userToResponse,
    tokenPairToResponse,
    sessionToResponse,
    passkeyToResponse,
    loginResultToResponse,
    impersonateToResponse,
    serviceTokenToResponse,
    storedToResponse,
    encodeCursor,
    decodeCursor,
  )
where

import Data.Aeson (Value, object, withObject, (.:))
import Data.Maybe (catMaybes)
import Data.Aeson qualified as Aeson
import Data.Aeson.Types (Parser)
import Data.Text qualified as Text
import Data.Time.Format.ISO8601 (iso8601ParseM, iso8601Show)
import Data.UUID qualified as UUID
import Shomei.Config (ShomeiConfig (..), transportIncludesBodyTokens)
import Shomei.Domain.Email (emailText)
import Shomei.Domain.LoginId (loginIdText)
import Shomei.Domain.Passkey (PasskeyCredential (..))
import Shomei.Domain.RefreshToken (RefreshToken (..))
import Shomei.Domain.Session (Session (..))
import Shomei.Domain.Token (AccessToken (..), TokenPair (..))
import Shomei.Domain.User (User (..), UserStatus (..))
import Shomei.Effect.AuthEventReader (AuditCursor (..), StoredAuthEvent (..))
import Shomei.Id (idText)
import Shomei.Prelude
import Shomei.Workflow (LoginResult (..), MfaChallenge (..))
import Shomei.Workflow.ServiceToken (IssuedServiceToken (..))

-- | @POST /v1/auth/signup@ body. The principal is @loginId@; @email@ is optional. For backward
-- compatibility either field may be omitted: an email-only caller (no @loginId@) defaults the
-- login id to the email text in the handler, and at least one of the two must be present.
data SignupRequest = SignupRequest
  { loginId :: !(Maybe Text),
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

-- | @POST /v1/auth/login@ body. Log in by @loginId@ (the principal); @email@ is accepted for
-- backward compatibility and, when @loginId@ is omitted, the login id defaults to the email text.
data LoginRequest = LoginRequest
  { loginId :: !(Maybe Text),
    email :: !(Maybe Text),
    password :: !Text
  }
  deriving stock (Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | @POST /v1/auth/login@ response. Either a completed login (user + token, the legacy shape
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
        options :: !Value
      }
  deriving stock (Generic)

instance ToJSON LoginResponse where
  toJSON = \case
    LoginCompleteResponse u t ->
      object ["status" Aeson..= ("complete" :: Text), "user" Aeson..= u, "token" Aeson..= t]
    LoginMfaRequiredResponse cid opts ->
      object
        [ "status" Aeson..= ("mfa_required" :: Text),
          "ceremonyId" Aeson..= cid,
          "options" Aeson..= opts
        ]

instance FromJSON LoginResponse where
  parseJSON = withObject "LoginResponse" \o -> do
    status <- o .: "status" :: Parser Text
    case status of
      "complete" -> LoginCompleteResponse <$> o .: "user" <*> o .: "token"
      "mfa_required" -> LoginMfaRequiredResponse <$> o .: "ceremonyId" <*> o .: "options"
      other -> fail ("unknown login status: " <> Text.unpack other)

-- | @POST /v1/auth/mfa/complete@ body: the ceremony id from the login challenge + the assertion JSON.
data MfaCompleteRequest = MfaCompleteRequest
  { ceremonyId :: !Text,
    assertion :: !Value
  }
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
    expiresAt :: !Text
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
  MfaRequired (MfaChallenge cid opts) ->
    LoginMfaRequiredResponse {ceremonyId = idText cid, options = opts}

-- | @POST /v1/auth/impersonate@ body: the target user id, a required reason, and an
-- optional support ticket id.
data ImpersonateRequest = ImpersonateRequest
  { userId :: !Text,
    reason :: !Text,
    ticketId :: !(Maybe Text)
  }
  deriving stock (Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | @POST /v1/auth/impersonate@ response: the delegated access token, the subject
-- (customer) and actor (operator) ids, and the token expiry as ISO-8601.
data ImpersonateResponse = ImpersonateResponse
  { accessToken :: !Text,
    subjectUserId :: !Text,
    actorUserId :: !Text,
    expiresAt :: !Text
  }
  deriving stock (Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | @POST /v1/auth/service-token@ body: configured service account id, shared secret,
-- requested coarse scopes, and optional actor user id for @act@ attribution.
data ServiceTokenRequest = ServiceTokenRequest
  { accountId :: !Text,
    secret :: !Text,
    scopes :: ![Text],
    actorId :: !(Maybe Text)
  }
  deriving stock (Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | @POST /v1/auth/service-token@ response: refresh-less access token and lifetime.
data ServiceTokenResponse = ServiceTokenResponse
  { accessToken :: !Text,
    expiresIn :: !Int
  }
  deriving stock (Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | Render the @(Session, AccessToken)@ a successful impersonation returns into the
-- wire DTO. The session's @actor@ is always 'Just' for a delegated session; an empty
-- string is a defensive fallback that should never occur.
impersonateToResponse :: Session -> AccessToken -> ImpersonateResponse
impersonateToResponse s (AccessToken tok) =
  ImpersonateResponse
    { accessToken = tok,
      subjectUserId = idText s.userId,
      actorUserId = maybe "" idText s.actor,
      expiresAt = Text.pack (iso8601Show s.expiresAt)
    }

serviceTokenToResponse :: IssuedServiceToken -> ServiceTokenResponse
serviceTokenToResponse issued =
  ServiceTokenResponse
    { accessToken = unAccess issued.accessToken,
      expiresIn = round (realToFrac issued.expiresIn :: Double)
    }
  where
    unAccess (AccessToken t) = t

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

-- | Render a domain 'Session' to the wire DTO (timestamps as ISO-8601).
sessionToResponse :: Session -> SessionResponse
sessionToResponse s =
  SessionResponse
    { sessionId = idText s.sessionId,
      userId = idText s.userId,
      createdAt = Text.pack (iso8601Show s.createdAt),
      expiresAt = Text.pack (iso8601Show s.expiresAt)
    }
