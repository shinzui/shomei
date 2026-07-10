-- | The authorization-code issuing half of the OAuth2 authorization-code grant (RFC 6749 §4.1),
-- behind @GET \/oauth\/authorize@.
--
-- The caller (the HTTP layer) has already done the two things this workflow cannot: it resolved
-- the @client_id@ to an active 'OAuthClient', and it checked the presented @redirect_uri@ against
-- that client's registered list by exact string equality. Those two checks decide whether an error
-- may be /redirected/ at all, which is an HTTP-shape decision — see the two validation regimes in
-- "Shomei.Servant.Handlers". Everything else — PKCE policy, scope policy, minting and storing the
-- code, auditing it — is here.
--
-- __Errors here are not 'Shomei.Error.AuthError'.__ Each one becomes an @error=@ parameter on a
-- redirect back to the client (RFC 6749 §4.1.2.1), never a problem document and never an OAuth
-- token-endpoint error object. Giving them their own type keeps them out of the problem catalog,
-- which describes only what the application envelope can carry.
module Shomei.Workflow.OAuthAuthorize
  ( AuthorizeParams (..),
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
import Shomei.Config (ShomeiConfig)
import Shomei.Domain.AuthorizationCode (NewAuthorizationCode (..))
import Shomei.Domain.Claims (AuthClaims (..), Scope (..))
import Shomei.Domain.Event qualified as Event
-- Imported WITHOUT (..): 'OAuthClient' shares @clientId@ / @status@ / @createdAt@ with several
-- other domain records, which would defeat @OverloadedRecordDot@. Every field is read through a
-- generic-lens label, as 'Shomei.Workflow.ClientCredentials' does for 'ServiceAccount'.
import Shomei.Domain.OAuthClient (ClientType (..), OAuthClient)
import Shomei.Domain.RefreshToken (RefreshToken (..))
import Shomei.Effect.AuthEventPublisher (AuthEventPublisher, publishAuthEvent)
import Shomei.Effect.Clock (Clock, now)
import Shomei.Effect.OAuthCodeStore (OAuthCodeStore, putAuthorizationCode)
import Shomei.Effect.TokenGen (TokenGen, generateOpaqueToken)
import Shomei.Prelude
import Shomei.Workflow.ServiceToken (sha256Hex)

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

-- | The RFC 6749 §4.1.2.1 error codes this workflow can produce. Each becomes
-- @?error=<code>&error_description=…&state=…@ on a redirect to the (already validated)
-- @redirect_uri@.
data AuthorizeError
  = -- | @response_type@ was absent or not @code@
    UnsupportedResponseType
  | -- | a PKCE policy violation; the text names it
    AuthorizeInvalidRequest !Text
  | -- | the requested scope is empty or exceeds the client's allow-list
    AuthorizeInvalidScope
  deriving stock (Generic, Eq, Show)

authorizeErrorCode :: AuthorizeError -> Text
authorizeErrorCode = \case
  UnsupportedResponseType -> "unsupported_response_type"
  AuthorizeInvalidRequest _ -> "invalid_request"
  AuthorizeInvalidScope -> "invalid_scope"

authorizeErrorDescription :: AuthorizeError -> Text
authorizeErrorDescription = \case
  UnsupportedResponseType -> "response_type must be code"
  AuthorizeInvalidRequest what -> what
  AuthorizeInvalidScope -> "the requested scope is empty or exceeds what this client may request"

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
-- @auth_time@ is the authorizing token's @iat@: the moment the user actually authenticated, which
-- is what OIDC's @auth_time@ claim means — not the moment they arrived at this endpoint.
authorize ::
  ( OAuthCodeStore :> es,
    TokenGen :> es,
    AuthEventPublisher :> es,
    Clock :> es
  ) =>
  ShomeiConfig ->
  OAuthClient ->
  AuthClaims ->
  AuthorizeParams ->
  Eff es (Either AuthorizeError IssuedCode)
authorize cfg client claims params = runErrorNoCallStack do
  unless (params.responseType == Just "code") (throwError UnsupportedResponseType)
  challenge <- resolvePkce
  granted <- resolveScopes
  ts <- now
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
        authTime = claims.issuedAt,
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
      Nothing -> pure (client ^. #allowedScopes)
      Just requested -> do
        when (Set.null requested) (throwError AuthorizeInvalidScope)
        unless (requested `Set.isSubsetOf` (client ^. #allowedScopes)) (throwError AuthorizeInvalidScope)
        pure requested
