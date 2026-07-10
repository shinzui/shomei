-- | The two grants EP-5 adds to @POST \/oauth\/token@: @authorization_code@ (RFC 6749 §4.1.3,
-- with PKCE per RFC 7636) and @refresh_token@ (§6), both authenticated as an OAuth client.
--
-- __Errors here are not 'Shomei.Error.AuthError'.__ They become RFC 6749 §5.2 error objects at the
-- token endpoint, never problem documents, so a dedicated type keeps them out of the problem
-- catalog — which describes only what the application envelope can carry. (This mirrors
-- "Shomei.Workflow.OAuthAuthorize".)
--
-- __Rotation and reuse detection are not reimplemented here.__ 'refreshViaOAuth' adds one check —
-- that the session was minted by /this/ client — and then delegates to 'Shomei.Workflow.refresh',
-- the most security-sensitive machinery in the repository. Forking its invariants for OAuth
-- clients would be the single most likely way to break them.
module Shomei.Workflow.OAuthTokenGrant
  ( TokenGrantError (..),
    grantErrorCode,
    grantErrorDescription,
    ExchangeAuthorizationCode (..),
    RefreshViaOAuth (..),
    ExchangedTokens (..),
    exchangeAuthorizationCode,
    refreshViaOAuth,
    pkceChallengeFor,
  )
where

import Crypto.Hash (SHA256 (..), hashWith)
import Data.Bifunctor (first)
import Data.ByteArray qualified as BA
import Data.ByteArray.Encoding (Base (Base64URLUnpadded), convertToBase)
import Data.ByteString (ByteString)
import Data.Generics.Labels ()
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TE
import Data.Time (addUTCTime)
import Effectful (Eff, (:>))
import Effectful.Error.Static (Error, runErrorNoCallStack, throwError)
import Shomei.Config (ShomeiConfig)
import Shomei.Domain.AuthorizationCode (AuthorizationCode)
import Shomei.Domain.Claims (AuthClaims, Scope (..))
-- Imported WITHOUT (..): both share field names with 'Shomei.Domain.User.User', which would defeat
-- @OverloadedRecordDot@. Read through generic-lens labels.

import Shomei.Domain.Command (RefreshCommand (..))
import Shomei.Domain.IdTokenClaims (IdToken, IdTokenClaims (..))
import Shomei.Domain.OAuthClient (ClientType (..), OAuthClient, OAuthClientStatus (..))
import Shomei.Domain.RefreshToken (RefreshToken)
import Shomei.Domain.Session (Session)
import Shomei.Domain.Token (TokenPair)
import Shomei.Domain.User (User, UserStatus (UserActive))
import Shomei.Effect.AuthEventPublisher (AuthEventPublisher)
import Shomei.Effect.AuthUnitOfWork (AuthUnitOfWork)
import Shomei.Effect.ClaimsEnricher (ClaimsEnricher)
import Shomei.Effect.Clock (Clock, now)
import Shomei.Effect.OAuthClientStore (OAuthClientStore, findOAuthClientByClientId)
import Shomei.Effect.OAuthCodeStore (OAuthCodeStore, consumeAuthorizationCode)
import Shomei.Effect.RefreshTokenStore (RefreshTokenStore, findRefreshTokenByHash)
import Shomei.Effect.RoleStore (RoleStore)
import Shomei.Effect.SessionStore (SessionStore, findSessionById)
import Shomei.Effect.TokenGen (TokenGen, hashRefreshToken)
import Shomei.Effect.TokenSigner (TokenSigner, signIdToken)
import Shomei.Effect.UserStore (UserStore, findUserById)
import Shomei.Error (AuthError)
import Shomei.Id (SessionId)
import Shomei.Prelude
import Shomei.Workflow qualified as Wf
import Shomei.Workflow.ServiceToken (sha256Hex, verifyServiceSecret)
import Shomei.Workflow.Session (SessionOptions (..), issueSessionWith)

-- | The RFC 6749 §5.2 error codes these grants produce.
data TokenGrantError
  = -- | client authentication failed: unknown client, revoked client, wrong secret, a secret sent
    --     by a public client, or a secret withheld by a confidential one. Never says which.
    GrantInvalidClient
  | -- | the presented grant is invalid, expired, revoked, or not this client's. The text is for a
    --     human reading a log, never for the caller to branch on.
    GrantInvalidGrant !Text
  | GrantInvalidRequest !Text
  deriving stock (Generic, Eq, Show)

grantErrorCode :: TokenGrantError -> Text
grantErrorCode = \case
  GrantInvalidClient -> "invalid_client"
  GrantInvalidGrant _ -> "invalid_grant"
  GrantInvalidRequest _ -> "invalid_request"

grantErrorDescription :: TokenGrantError -> Text
grantErrorDescription = \case
  GrantInvalidClient -> "client authentication failed"
  -- One description for every invalid_grant, so a caller cannot tell a replayed code from an
  -- expired one from someone else's. The specific text stays server-side.
  GrantInvalidGrant _ -> "the provided grant is invalid, expired, or was issued to another client"
  GrantInvalidRequest what -> what

data ExchangeAuthorizationCode = ExchangeAuthorizationCode
  { clientId :: !Text,
    -- | 'Nothing' for a public client, which has none
    clientSecret :: !(Maybe Text),
    code :: !Text,
    redirectUri :: !Text,
    codeVerifier :: !(Maybe Text)
  }
  deriving stock (Generic, Eq, Show)

data RefreshViaOAuth = RefreshViaOAuth
  { clientId :: !Text,
    clientSecret :: !(Maybe Text),
    refreshToken :: !RefreshToken
  }
  deriving stock (Generic, Eq, Show)

data ExchangedTokens = ExchangedTokens
  { tokens :: !TokenPair,
    grantedScopes :: !(Set Scope),
    -- | present exactly when the granted scopes include @openid@
    idToken :: !(Maybe IdToken),
    sessionId :: !SessionId
  }
  deriving stock (Generic, Show)

-- | @BASE64URL-ENCODE(SHA256(ASCII(verifier)))@, unpadded (RFC 7636 §4.6).
--
-- Exported because a test that drives the real flow must produce a challenge the same way a client
-- does, and reimplementing it in the test would let both drift together.
pkceChallengeFor :: Text -> Text
pkceChallengeFor verifier =
  TE.decodeUtf8 (convertToBase Base64URLUnpadded (hashWith SHA256 (TE.encodeUtf8 verifier)) :: ByteString)

-- | RFC 6749 §4.1.3: authenticate the client, redeem the code, verify PKCE, mint the session.
--
-- Every check that could distinguish one failure from another answers the same @invalid_grant@:
-- a code that never existed, one already redeemed, one that expired, one issued to a different
-- client, one presented with a different @redirect_uri@, and one whose PKCE verifier does not
-- match are indistinguishable on the wire. The code is consumed __before__ any of those checks
-- that could fail, so a wrong-client or wrong-PKCE attempt still burns it: an attacker who steals a
-- code cannot grind at it.
exchangeAuthorizationCode ::
  ( OAuthClientStore :> es,
    OAuthCodeStore :> es,
    UserStore :> es,
    AuthUnitOfWork :> es,
    TokenSigner :> es,
    TokenGen :> es,
    RoleStore :> es,
    ClaimsEnricher :> es,
    Clock :> es
  ) =>
  ShomeiConfig ->
  ExchangeAuthorizationCode ->
  Eff es (Either TokenGrantError ExchangedTokens)
exchangeAuthorizationCode cfg cmd = runErrorNoCallStack do
  _client <- authenticateClient (cmd ^. #clientId) (cmd ^. #clientSecret)
  ts <- now
  row <-
    maybe (throwError (GrantInvalidGrant "no such code, already consumed, or expired")) pure
      =<< consumeAuthorizationCode (sha256Hex (cmd ^. #code)) ts
  -- The code was minted for one client at one redirect URI; both are re-checked here because the
  -- code travelled through the user's browser and anything in that path could have altered them.
  unless (row ^. #clientId == cmd ^. #clientId) $
    throwError (GrantInvalidGrant "the code was issued to a different client")
  unless (row ^. #redirectUri == cmd ^. #redirectUri) $
    throwError (GrantInvalidGrant "redirect_uri does not match the authorize request")
  verifyPkce row
  user <- do
    u <- maybe (throwError (GrantInvalidGrant "the code's user no longer exists")) pure =<< findUserById (row ^. #userId)
    unless ((u ^. #status) == UserActive) (throwError (GrantInvalidGrant "the code's user is not active"))
    pure u
  let granted = row ^. #scopes
  (sid, pair, claims) <-
    issueSessionWith
      cfg
      SessionOptions {oauthClientId = Just (cmd ^. #clientId), extraScopes = granted}
      user
      ts
  idToken <-
    if Scope "openid" `Set.member` granted
      then Just <$> signIdTokenFor cfg cmd row claims ts
      else pure Nothing
  pure ExchangedTokens {tokens = pair, grantedScopes = granted, idToken, sessionId = sid}
  where
    -- If the code carries a challenge, a matching verifier is mandatory. If it does not (a
    -- confidential client that skipped PKCE), a supplied verifier is ignored rather than treated
    -- as an error: the client has proven itself with its secret.
    verifyPkce row = case row ^. #codeChallenge of
      Nothing -> pure ()
      Just expected -> do
        verifier <- maybe (throwError (GrantInvalidGrant "code_verifier is required")) pure (cmd ^. #codeVerifier)
        let actual = pkceChallengeFor verifier
        unless (TE.encodeUtf8 expected `BA.constEq` TE.encodeUtf8 actual) $
          throwError (GrantInvalidGrant "code_verifier does not match the stored code_challenge")

-- | The ID token (OIDC Core §2) for a freshly exchanged code.
--
-- @sub@ comes from the claims 'issueSessionWith' just signed, not from a second store read, so an
-- ID token can never name a different subject than the access token issued beside it. @nonce@ and
-- @auth_time@ come from the authorize request, carried across in the code row.
signIdTokenFor ::
  (TokenSigner :> es) =>
  ShomeiConfig ->
  ExchangeAuthorizationCode ->
  AuthorizationCode ->
  AuthClaims ->
  UTCTime ->
  Eff es IdToken
signIdTokenFor cfg cmd row claims ts =
  signIdToken
    IdTokenClaims
      { issuer = cfg ^. #issuer,
        subject = claims ^. #subject,
        audience = cmd ^. #clientId,
        issuedAt = ts,
        expiresAt = addUTCTime (cfg ^. #oauthConfig . #idTokenTTL) ts,
        nonce = row ^. #nonce,
        authTime = row ^. #authTime
      }

-- | RFC 6749 §6, with client binding.
--
-- The session must have been minted by this same client through the authorization-code grant. A
-- session with no @oauth_client_id@ — every password login, passkey login, impersonation, and
-- service-account session — cannot be refreshed here at all: it is refreshed at the endpoint that
-- created it.
--
-- The binding is checked /before/ delegating, and a mismatch does not run reuse detection. That is
-- deliberate: otherwise any client could revoke another client's whole token family for a user
-- simply by presenting a refresh token it had somehow observed, turning reuse detection into a
-- denial-of-service tool.
refreshViaOAuth ::
  ( OAuthClientStore :> es,
    SessionStore :> es,
    RefreshTokenStore :> es,
    AuthUnitOfWork :> es,
    UserStore :> es,
    TokenSigner :> es,
    RoleStore :> es,
    ClaimsEnricher :> es,
    AuthEventPublisher :> es,
    Clock :> es,
    TokenGen :> es
  ) =>
  ShomeiConfig ->
  RefreshViaOAuth ->
  Eff es (Either TokenGrantError TokenPair)
refreshViaOAuth cfg cmd = do
  outcome <- runErrorNoCallStack do
    _client <- authenticateClient (cmd ^. #clientId) (cmd ^. #clientSecret)
    session <- resolveSession
    unless ((session ^. #oauthClientId) == Just (cmd ^. #clientId)) $
      throwError (GrantInvalidGrant "the refresh token was not issued to this client")
  case outcome of
    Left e -> pure (Left e)
    -- Everything past here -- rotation, the used/revoked reuse path, expiry -- is the existing
    -- workflow's, unchanged. Its 'AuthError's collapse to one `invalid_grant`, because a caller
    -- must not learn from the token endpoint whether a token was expired, revoked, or reused.
    Right () -> do
      result <- Wf.refresh cfg RefreshCommand {refreshToken = cmd ^. #refreshToken}
      pure (first (GrantInvalidGrant . tshow) result)
  where
    tshow :: AuthError -> Text
    tshow = Text.pack . show

    -- Look the token up to reach its session and check the binding. This costs two reads the
    -- delegated 'Wf.refresh' repeats; the alternative is threading the binding into 'refresh'
    -- itself and coupling the bespoke endpoint to OAuth.
    resolveSession = do
      tokHash <- hashRefreshToken (cmd ^. #refreshToken)
      tok <- maybe (throwError (GrantInvalidGrant "unknown refresh token")) pure =<< findRefreshTokenByHash tokHash
      maybe (throwError (GrantInvalidGrant "the refresh token's session is gone")) pure
        =<< findSessionById (tok ^. #sessionId)

-- | RFC 6749 §2.3: a confidential client proves itself with its secret; a public client has none.
--
-- Every failure is the single 'GrantInvalidClient'. A caller learns neither that a @client_id@
-- exists, nor that it is revoked, nor that it is of the other type.
--
-- The secret is verified before the status is checked, so a revoked client and an active one with
-- a wrong secret cost the same work — the same ordering 'Shomei.Workflow.ClientCredentials' uses.
authenticateClient ::
  (OAuthClientStore :> es, Error TokenGrantError :> es) =>
  Text ->
  Maybe Text ->
  Eff es OAuthClient
authenticateClient clientId mSecret = do
  client <- maybe (throwError GrantInvalidClient) pure =<< findOAuthClientByClientId clientId
  case (client ^. #clientType, client ^. #secretHash, mSecret) of
    (ConfidentialClient, Just expected, Just presented) ->
      unless (verifyServiceSecret expected presented) (throwError GrantInvalidClient)
    -- A public client that presents a secret is not "a public client being generous": it is a
    -- request Shōmei cannot honor, because there is nothing to check the secret against.
    (PublicClient, Nothing, Nothing) -> pure ()
    _ -> throwError GrantInvalidClient
  unless ((client ^. #status) == OAuthClientActive) (throwError GrantInvalidClient)
  pure client
