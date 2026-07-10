-- | The OpenID Connect discovery document (EP-5), served at
-- @GET \/.well-known\/openid-configuration@.
--
-- This one document is the entire point of the OIDC surface: Envoy's JWT filter, oauth2-proxy,
-- Spring Security, ASP.NET Core, and every OIDC client library configure themselves from it, so
-- a deployment that publishes it is consumable with zero Shōmei-specific integration code.
--
-- __The issuer is the base URL.__ OIDC Core requires the document to live at
-- @{issuer}\/.well-known\/openid-configuration@ and ID tokens to carry @iss = issuer@, so every
-- endpoint URL below is derived from 'Shomei.Config.issuer' rather than from a second
-- "public base URL" field that could disagree with it. The standalone server refuses to boot with
-- @oidcEnabled@ set and an issuer that is not an absolute @http(s)@ URL
-- (see @Shomei.Server.Boot.validateOidcIssuer@).
module Shomei.Servant.Oidc
  ( discoveryDocument,
    oidcEndpointBase,
    isAbsoluteHttpUrl,
    supportedScopes,
  )
where

import Data.Aeson (Value)
import Data.Aeson qualified as Aeson
import Data.Text qualified as Text
import Shomei.Config (ShomeiConfig (..), configSigningAlgorithm)
import Shomei.Domain.Claims (Issuer (..))
import Shomei.Domain.SigningKey (signingAlgorithmToText)
import Shomei.Prelude

-- | The issuer with any trailing slashes removed, so @issuer <> "\/oauth\/token"@ never yields a
-- doubled slash. OIDC compares @iss@ byte-for-byte, so the issuer itself is published verbatim in
-- the @issuer@ member — only the /derived/ endpoint URLs are built on this normalized base.
oidcEndpointBase :: ShomeiConfig -> Text
oidcEndpointBase cfg = Text.dropWhileEnd (== '/') (issuerText cfg.issuer)
  where
    issuerText (Issuer t) = t

-- | Does this text parse as an absolute @http@ or @https@ URL? The boot-time issuer check.
--
-- Deliberately a prefix test rather than a full URI parse: the failure it must catch is the
-- default issuer @"shomei"@ (an opaque name, not a URL), which would produce a discovery document
-- advertising @shomei\/oauth\/token@ as an endpoint.
isAbsoluteHttpUrl :: Text -> Bool
isAbsoluteHttpUrl t = any (`Text.isPrefixOf` t) ["http://", "https://"]

-- | The scopes the discovery document advertises.
--
-- @openid@ is what makes a request an OIDC request (it is what causes an ID token to be issued).
-- @profile@ and @email@ are the conventional OIDC claim bundles. @offline_access@ is accepted and
-- ignored: Shōmei's session model always pairs an access token with a refresh token, so there is
-- no variant to gate (recorded in the ExecPlan's Decision Log).
supportedScopes :: [Text]
supportedScopes = ["openid", "profile", "email", "offline_access"]

-- | Build the discovery document from configuration alone.
--
-- A pure function of 'ShomeiConfig', so it needs no store, no clock, and no 'Shomei.Servant.Seam.Env'
-- field: the handler evaluates it per request, which costs one small object encode. (The @jwks@
-- route precomputes /its/ document because that one is derived from mutable key material reloaded
-- at runtime; this one is not.)
--
-- Only the subset EP-5 actually implements is advertised. In particular @response_types_supported@
-- is @["code"]@ alone: the implicit and hybrid flows are excluded by the OAuth 2.0 Security BCP,
-- and advertising a flow the server does not implement is worse than advertising nothing —
-- stock middleware would negotiate it.
discoveryDocument :: ShomeiConfig -> Value
discoveryDocument cfg =
  Aeson.object
    [ "issuer" Aeson..= issuerText cfg.issuer,
      "authorization_endpoint" Aeson..= (base <> "/oauth/authorize"),
      "token_endpoint" Aeson..= (base <> "/oauth/token"),
      "userinfo_endpoint" Aeson..= (base <> "/oauth/userinfo"),
      "introspection_endpoint" Aeson..= (base <> "/oauth/introspect"),
      "revocation_endpoint" Aeson..= (base <> "/oauth/revoke"),
      "jwks_uri" Aeson..= (base <> "/.well-known/jwks.json"),
      "response_types_supported" Aeson..= (["code"] :: [Text]),
      "grant_types_supported" Aeson..= (["authorization_code", "refresh_token", "client_credentials"] :: [Text]),
      "code_challenge_methods_supported" Aeson..= (["S256"] :: [Text]),
      "id_token_signing_alg_values_supported" Aeson..= [signingAlgorithmToText (configSigningAlgorithm cfg)],
      "subject_types_supported" Aeson..= (["public"] :: [Text]),
      "scopes_supported" Aeson..= supportedScopes,
      "token_endpoint_auth_methods_supported" Aeson..= (["client_secret_basic", "client_secret_post"] :: [Text])
    ]
  where
    base = oidcEndpointBase cfg
    issuerText (Issuer t) = t
