-- | The authorization-code issuing half of the OAuth2 authorization-code grant (RFC 6749 §4.1),
-- behind @GET \/oauth\/authorize@.
--
-- The caller (the HTTP layer) has already done the two things this workflow cannot: it resolved
-- the @client_id@ to an active 'OAuthClient', and it checked the presented @redirect_uri@ against
-- that client's registered list by exact string equality. Those two checks decide whether an error
-- may be /redirected/ at all, which is an HTTP-shape decision — see the two validation regimes in
-- "Shomei.OAuth.Handler". Everything else — PKCE policy, scope policy, minting and storing the
-- code, auditing it — is here.
--
-- __Errors here are not 'Shomei.Error.AuthError'.__ Parameter-policy errors become an @error=@
-- parameter on a redirect back to the client (RFC 6749 §4.1.2.1). 'AuthorizeLoginRequired' is
-- instead interpreted by the HTTP layer as an unauthenticated or non-interactive caller and is
-- never sent to the client's redirect URI.
module Shomei.OAuth.Authorize.Workflow
  ( AuthorizeParams (..),
    AuthorizeRefusal (..),
    AuthorizeError (..),
    authorizeErrorCode,
    authorizeErrorDescription,
    IssuedCode (..),
    authorize,
    isValidS256Challenge,
  )
where

import Data.Char (isAsciiLower, isAsciiUpper, isDigit)
import Data.Generics.Labels ()
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text qualified as Text
import Data.Time (addUTCTime)
import Effectful (Eff, (:>))
import Effectful.Error.Static (runErrorNoCallStack, throwError)
import Shomei.Audit.Event.Domain qualified as Event
-- Imported WITHOUT (..): 'OAuthClient' shares @clientId@ / @status@ / @createdAt@ with several
-- other domain records, which would defeat @OverloadedRecordDot@. Every field is read through a
-- generic-lens label, as 'Shomei.ServiceAccount.ClientCredentials.Workflow' does for 'ServiceAccount'.

import Shomei.Audit.Publisher.Store (AuthEventPublisher, publishAuthEvent)
import Shomei.Authorization.Claims.Domain (AuthClaims (..), Scope (..))
import Shomei.Authorization.Scope.Domain (privilegeScopes, privilegeScopesIn)
import Shomei.Config (ShomeiConfig)
import Shomei.OAuth.AuthorizationCode.Domain (NewAuthorizationCode (..))
import Shomei.OAuth.AuthorizationCode.Store (OAuthCodeStore, putAuthorizationCode)
import Shomei.OAuth.Client.Domain (ClientType (..), OAuthClient)
import Shomei.Prelude
import Shomei.ServiceAccount.Secret (sha256Hex)
import Shomei.Session.Domain (SessionKind (InteractiveSession))
import Shomei.Session.RefreshToken.Domain (RefreshToken (..))
import Shomei.Session.Store (SessionStore)
import Shomei.Session.Token.Generator (TokenGen, generateOpaqueToken)
import Shomei.Session.Workflow (requireLiveSession)
import Shomei.Time.Store (Clock, now)

-- | The authorize request's parameters, after the HTTP layer has validated @client_id@ and
-- @redirect_uri@ (which is why 'redirectUri' is a 'Text' and not a 'Maybe').
data AuthorizeParams = AuthorizeParams
  { responseType :: !(Maybe Text),
    redirectUri :: !Text,
    -- | the raw space-delimited @scope@ parameter; 'Nothing' when absent
    scope :: !(Maybe Text),
    -- | opaque, echoed back on both the success and the error redirect
    state :: !(Maybe Text),
    nonce :: !(Maybe Text),
    codeChallenge :: !(Maybe Text),
    codeChallengeMethod :: !(Maybe Text)
  }
  deriving stock (Generic, Eq, Show)

-- | Why an otherwise-verifying credential may not authorize a client.
data AuthorizeRefusal
  = -- | The token carries @act@, or its session was established by a machine or delegation.
    NonInteractiveCredential
  | -- | The token's session is missing, revoked, or past its absolute expiry.
    SessionNotLive
  deriving stock (Generic, Eq, Show)

-- | The authorization policy outcomes. Parameter-policy errors redirect to the validated client;
-- 'AuthorizeLoginRequired' is handled without such a redirect by the HTTP layer.
data AuthorizeError
  = -- | @response_type@ was absent or not @code@
    UnsupportedResponseType
  | -- | a PKCE policy violation; the text names it
    AuthorizeInvalidRequest !Text
  | -- | the requested scope is empty or exceeds the client's allow-list
    AuthorizeInvalidScope
  | -- | the caller is not a live interactive end-user login
    AuthorizeLoginRequired !AuthorizeRefusal
  deriving stock (Generic, Eq, Show)

authorizeErrorCode :: AuthorizeError -> Text
authorizeErrorCode = \case
  UnsupportedResponseType -> "unsupported_response_type"
  AuthorizeInvalidRequest _ -> "invalid_request"
  AuthorizeInvalidScope -> "invalid_scope"
  AuthorizeLoginRequired _ -> "login_required"

authorizeErrorDescription :: AuthorizeError -> Text
authorizeErrorDescription = \case
  UnsupportedResponseType -> "response_type must be code"
  AuthorizeInvalidRequest what -> what
  AuthorizeInvalidScope -> "the requested scope is empty or exceeds what this client may request"
  AuthorizeLoginRequired NonInteractiveCredential -> "an interactive login session is required to authorize a client"
  AuthorizeLoginRequired SessionNotLive -> "the session is no longer valid"

-- | What the browser is redirected back with.
data IssuedCode = IssuedCode
  { -- | the opaque code; only its SHA-256 digest was stored
    code :: !Text,
    -- | echoed verbatim from the request
    state :: !(Maybe Text),
    grantedScopes :: !(Set Scope)
  }
  deriving stock (Generic, Eq, Show)

-- | Is this a well-formed PKCE S256 challenge (RFC 7636 §4.2)?
--
-- @BASE64URL-ENCODE(SHA256(verifier))@ without padding is always exactly 43 characters of the
-- base64url alphabet. Checking the shape at authorize means a client that sent a padded, hex, or
-- truncated challenge learns so immediately, rather than at the exchange as a bare
-- @invalid_grant@ it cannot debug.
isValidS256Challenge :: Text -> Bool
isValidS256Challenge t =
  Text.length t == 43 && Text.all isBase64UrlChar t
  where
    isBase64UrlChar c = isAsciiLower c || isAsciiUpper c || isDigit c || c == '-' || c == '_'

-- | Enforce the request's policy, then mint, store, and audit a single-use code.
--
-- Steps, in order:
--
--   1. @response_type@ must be exactly @code@.
--   2. PKCE: a public client MUST supply a @code_challenge@ (with no secret it has no other
--      binding between this request and the exchange). Whenever a challenge is supplied, its
--      method must be @S256@ and its shape must be right.
--   3. Scope: an absent @scope@ grants the client's whole allow-list; a present one must name a
--      non-empty subset of it.
--   4. Mint a high-entropy opaque code, store only its SHA-256 digest along with every binding the
--      exchange will re-check, and publish 'Event.OAuthCodeIssued'.
--
-- @auth_time@ is copied from the authorizing token: the moment the user actually proved a
-- credential, which is what OIDC's claim means — not its refresh time or this request time.
authorize ::
  ( OAuthCodeStore :> es,
    TokenGen :> es,
    AuthEventPublisher :> es,
    Clock :> es,
    SessionStore :> es
  ) =>
  ShomeiConfig ->
  OAuthClient ->
  AuthClaims ->
  AuthorizeParams ->
  Eff es (Either AuthorizeError IssuedCode)
authorize cfg client claims params = runErrorNoCallStack do
  -- A code becomes a fresh, refreshable, fully enriched session. Only a token that is itself a
  -- live interactive login may mint one, regardless of the deployment's sessionCheckMode.
  when (isJust claims.actor) (throwError (AuthorizeLoginRequired NonInteractiveCredential))
  ts <- now
  session <-
    either (const (throwError (AuthorizeLoginRequired SessionNotLive))) pure
      =<< requireLiveSession ts claims.sessionId
  unless ((session ^. #kind) == InteractiveSession) $
    throwError (AuthorizeLoginRequired NonInteractiveCredential)
  unless (params.responseType == Just "code") (throwError UnsupportedResponseType)
  challenge <- resolvePkce
  granted <- resolveScopes
  -- The refresh-token generator is the codebase's single CSPRNG opaque-token source (32 bytes,
  -- base64url). A code is the same kind of secret with a shorter life.
  RefreshToken code <- generateOpaqueToken
  putAuthorizationCode
    NewAuthorizationCode
      { codeHash = sha256Hex code,
        clientId = client ^. #clientId,
        redirectUri = params.redirectUri,
        userId = claims.subject,
        scopes = granted,
        nonce = params.nonce,
        codeChallenge = challenge,
        authTime = claims.authTime,
        createdAt = ts,
        expiresAt = addUTCTime (cfg ^. #oauthConfig . #authorizationCodeTTL) ts
      }
  publishAuthEvent
    ( Event.OAuthCodeIssued
        Event.OAuthCodeIssuedData
          { clientId = client ^. #clientId,
            userId = claims.subject,
            scopes = granted,
            occurredAt = ts
          }
    )
  pure IssuedCode {code, state = params.state, grantedScopes = granted}
  where
    resolvePkce = case (params.codeChallenge, params.codeChallengeMethod) of
      (Nothing, _)
        -- A confidential client authenticates with its secret at the exchange, so PKCE is
        -- optional for it. A public client has nothing else, so PKCE is its only defense against
        -- a stolen code.
        | (client ^. #clientType) == PublicClient ->
            throwError (AuthorizeInvalidRequest "code_challenge is required for a public client")
        | otherwise -> pure Nothing
      (Just c, method) -> do
        -- RFC 7636 §4.3 defaults an absent method to `plain`, which this provider does not
        -- accept. Requiring it to be spelled out means a client cannot land on `plain` silently.
        unless (method == Just "S256") $
          throwError (AuthorizeInvalidRequest "code_challenge_method must be S256")
        unless (isValidS256Challenge c) $
          throwError (AuthorizeInvalidRequest "code_challenge must be 43 characters of unpadded base64url")
        pure (Just c)

    -- An absent `scope` takes a server-defined default (RFC 6749 §3.3); "everything this client is
    -- registered for" is the least surprising one. A present `scope` must be a non-empty subset:
    -- `scope=` is a malformed request, not a request for nothing.
    resolveScopes = case fmap (Set.fromList . map Scope . Text.words) params.scope of
      Nothing -> do
        let granted = (client ^. #allowedScopes) `Set.difference` privilegeScopes cfg
        when (Set.null granted) (throwError AuthorizeInvalidScope)
        pure granted
      Just requested -> do
        when (Set.null requested) (throwError AuthorizeInvalidScope)
        unless (requested `Set.isSubsetOf` (client ^. #allowedScopes)) (throwError AuthorizeInvalidScope)
        unless (Set.null (privilegeScopesIn cfg requested)) (throwError AuthorizeInvalidScope)
        pure requested
