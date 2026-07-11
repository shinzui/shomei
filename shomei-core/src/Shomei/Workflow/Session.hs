-- | The shared token-issuing tail of the authentication workflows.
--
-- 'issueSession' mints a fresh session + refresh token + signed access token for an
-- already-authenticated user and publishes 'LoginSucceeded' + 'SessionStarted'. It is the
-- exact tail that 'Shomei.Workflow.login' (non-MFA path), 'Shomei.Workflow.Mfa.completeMfa',
-- and 'Shomei.Workflow.Mfa.completePasswordlessLogin' share, factored out so the call sites
-- cannot drift. 'buildClaims' assembles the access-token claims for a fresh session.
--
-- This module is a leaf: it imports no passkey domain types, so it is free of the
-- @OverloadedRecordDot@/@HasField@ ambiguity that co-importing the passkey records triggers
-- (a MasterPlan-3 discovery). It exists as its own module to break the import cycle that
-- would otherwise form between 'Shomei.Workflow' (which calls 'issueSession') and
-- 'Shomei.Workflow.Mfa' (which also calls 'issueSession'). 'Shomei.Workflow' re-exports
-- 'issueSession' so the public interface remains @Shomei.Workflow.issueSession@.
module Shomei.Workflow.Session
  ( buildClaims,
    buildClaimsWith,
    buildEnrichedClaims,
    SessionOptions (..),
    defaultSessionOptions,
    issueSession,
    issueSessionWith,
    ensureEmailVerified,
  )
where

import Data.Aeson (Object)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Time (addUTCTime)
import Effectful (Eff, (:>))
import Shomei.Config (NotifierConfig (..), ShomeiConfig (..))
import Shomei.Domain.Claims (AuthClaims (..), Scope, mkExtraClaims, noExtraClaims)
import Shomei.Domain.Event qualified as Event
import Shomei.Domain.Session (NewSession (..), Session (..))
import Shomei.Domain.Token (TokenPair (..))
import Shomei.Domain.User (User (..))
import Shomei.Effect.AuthUnitOfWork (AuthUnitOfWork, NewSessionToken (..), persistNewSession)
import Shomei.Effect.ClaimsEnricher (ClaimsDelta (..), ClaimsEnricher, enrichClaims)
import Shomei.Effect.RoleStore (RoleStore, listRolesForUser, permissionsForRoles)
import Shomei.Effect.TokenGen (TokenGen, generateOpaqueToken, hashRefreshToken)
import Shomei.Effect.TokenSigner (TokenSigner, signAccessToken)
import Shomei.Error (AuthError (EmailNotVerified))
import Shomei.Id (SessionId, UserId)
import Shomei.Prelude

-- | The @emailVerificationRequired@ gate, called by every token-issuing path.
--
-- Blocks only an account that /has/ an email which is unverified. An account with no email
-- is exempt: it can never complete verification, so gating it would permanently brick
-- login-id-only deployments that enable the flag for their email accounts.
--
-- Pure 'Either' so callers in both the @Error@-effect and the explicit-@Either@ styles can
-- use it.
ensureEmailVerified :: ShomeiConfig -> User -> Either AuthError ()
ensureEmailVerified cfg user
  | cfg.notifierConfig.emailVerificationRequired
      && isJust user.email
      && isNothing user.emailVerifiedAt =
      Left EmailNotVerified
  | otherwise = Right ()

-- | The /base/ claims for a freshly-authenticated session: no scopes, no roles. The standard
-- workflows call 'buildEnrichedClaims', which fills those in from the role store and the host
-- hook. 'Shomei.Workflow.ServiceToken' uses this directly, because it sets @scopes@ itself from
-- the account's negotiated allow-list.
buildClaims :: ShomeiConfig -> UserId -> SessionId -> UTCTime -> AuthClaims
buildClaims cfg uid sid ts =
  AuthClaims
    { subject = uid,
      sessionId = sid,
      issuer = cfg.issuer,
      audience = cfg.audience,
      issuedAt = ts,
      expiresAt = addUTCTime cfg.accessTokenTTL ts,
      scopes = Set.empty,
      roles = Set.empty,
      permissions = Set.empty,
      actor = Nothing,
      extraClaims = noExtraClaims
    }

-- | Like 'buildClaims' but attaches a service-supplied custom-claims object (reserved
-- keys are dropped by 'mkExtraClaims'). A consuming service uses this to add its own
-- top-level JWT claims without modifying Shōmei; the standard workflows keep calling
-- 'buildClaims'.
buildClaimsWith :: ShomeiConfig -> Object -> UserId -> SessionId -> UTCTime -> AuthClaims
buildClaimsWith cfg extra uid sid ts =
  (buildClaims cfg uid sid ts) {extraClaims = mkExtraClaims extra}

-- | Build the access-token claims for a fresh user session: 'buildClaims' plus the roles the
-- 'RoleStore' holds for the subject, plus whatever the host's 'ClaimsEnricher' adds.
--
-- This is the single claims-construction point for every user-session mint — signup, login,
-- MFA completion, passwordless login, and refresh all reach it. Anything that needs the same
-- claims (an OIDC ID token, a userinfo response, an exchanged token) must call this rather than
-- re-reading the stores itself, or the two will drift.
--
-- The delta's extra claims run through 'mkExtraClaims', so the hook cannot forge a reserved
-- claim. Roles are the union of stored and hook-supplied ones; scopes come only from the hook
-- (Shōmei persists no scopes). Permissions (EP-9) are the union of the /effective/ role set's
-- catalog permissions — an enricher-added role brings its permissions with it — and cannot be
-- forged through @extraClaims@ ('permissions' is reserved). The stored roles are read as of the
-- mint instant, so an expired grant contributes neither its role nor its permissions.
buildEnrichedClaims ::
  (RoleStore :> es, ClaimsEnricher :> es) =>
  ShomeiConfig ->
  UserId ->
  SessionId ->
  UTCTime ->
  Eff es AuthClaims
buildEnrichedClaims cfg uid sid ts = do
  storeRoles <- listRolesForUser uid ts
  delta <- enrichClaims uid storeRoles
  let effectiveRoles = storeRoles <> delta.extraRoles
  perms <- permissionsForRoles effectiveRoles
  pure
    (buildClaims cfg uid sid ts)
      { roles = effectiveRoles,
        scopes = delta.extraScopes,
        permissions = perms,
        extraClaims = mkExtraClaims delta.extraClaims
      }

-- | Mint a fresh session + refresh token + signed access token for an authenticated user,
-- publishing 'LoginSucceeded' and 'SessionStarted'. Returns the new session id alongside the
-- token pair so a caller (e.g. 'Shomei.Workflow.Mfa.completeMfa') can name the session in its
-- own audit event. The session id is fresh each call.
--
-- The session row, the refresh-token row, and both audit events are written by a single
-- 'persistNewSession' — one database transaction, one round-trip — so a crash mid-tail cannot
-- leave a session without its token. Signing the access token is pure CPU work and stays
-- outside the transaction. The session id is generated inside the unit-of-work interpreter,
-- which is why the events are supplied as a function of it.
-- | What distinguishes one issuance from another. Everything here is 'mempty'-ish by default, so
-- 'issueSession' — the login\/MFA\/passwordless tail — behaves exactly as it did before EP-5.
data SessionOptions = SessionOptions
  { -- | the OAuth2 @client_id@ that minted this session (EP-5's authorization-code grant), which
    --     binds the session's refresh token to that client. 'Nothing' for every other flow.
    oauthClientId :: !(Maybe Text),
    -- | scopes to add to the minted access token's claims, beyond whatever the 'ClaimsEnricher'
    --     supplies. EP-5's authorization-code grant puts the scopes it granted here.
    extraScopes :: !(Set Scope)
  }
  deriving stock (Generic, Eq, Show)

defaultSessionOptions :: SessionOptions
defaultSessionOptions = SessionOptions {oauthClientId = Nothing, extraScopes = Set.empty}

issueSession ::
  ( AuthUnitOfWork :> es,
    TokenSigner :> es,
    TokenGen :> es,
    RoleStore :> es,
    ClaimsEnricher :> es
  ) =>
  ShomeiConfig ->
  User ->
  UTCTime ->
  Eff es (SessionId, TokenPair)
issueSession cfg user ts = do
  (sid, pair, _claims) <- issueSessionWith cfg defaultSessionOptions user ts
  pure (sid, pair)

-- | 'issueSession' with the OAuth-specific knobs, and returning the claims it signed.
--
-- The claims come back because EP-5's authorization-code grant must build its __ID token__ from
-- the same 'buildEnrichedClaims' output as the access token, per this MasterPlan's claims
-- integration point — never by re-reading the role store in the HTTP layer.
issueSessionWith ::
  ( AuthUnitOfWork :> es,
    TokenSigner :> es,
    TokenGen :> es,
    RoleStore :> es,
    ClaimsEnricher :> es
  ) =>
  ShomeiConfig ->
  SessionOptions ->
  User ->
  UTCTime ->
  Eff es (SessionId, TokenPair, AuthClaims)
issueSessionWith cfg opts user ts = do
  rawToken <- generateOpaqueToken
  tokHash <- hashRefreshToken rawToken
  (session, _token) <-
    persistNewSession
      NewSession
        { userId = user.userId,
          createdAt = ts,
          expiresAt = addUTCTime cfg.sessionTTL ts,
          actor = Nothing,
          oauthClientId = opts.oauthClientId
        }
      NewSessionToken
        { tokenHash = tokHash,
          createdAt = ts,
          expiresAt = addUTCTime cfg.refreshTokenTTL ts
        }
      \sid ->
        [ Event.LoginSucceeded (Event.LoginSucceededData user.userId sid ts),
          Event.SessionStarted (Event.SessionStartedData sid user.userId ts)
        ]
  base <- buildEnrichedClaims cfg user.userId session.sessionId ts
  -- Union rather than replace: the host's 'ClaimsEnricher' scopes and the OAuth-granted scopes
  -- are both things this principal legitimately holds on this token.
  let claims = base {scopes = base.scopes <> opts.extraScopes}
  access <- signAccessToken claims
  pure
    ( session.sessionId,
      TokenPair {accessToken = access, refreshToken = rawToken, expiresIn = cfg.accessTokenTTL},
      claims
    )
