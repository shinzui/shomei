-- | Building Shōmei's transport cookies.
--
-- Two cookies, set together by every response that issues a token pair:
--
-- * @shomei_session@ — the access token. @Path=\/@, @Max-Age@ = @accessTokenTTL@.
-- * @shomei_refresh@ — the refresh token. @Path=\/v1\/auth\/refresh@, @Max-Age@ =
--   @refreshTokenTTL@. Scoping it to the one endpoint that consumes it means the browser
--   never presents this long-lived credential anywhere else.
--
-- Both are @HttpOnly@, so page JavaScript cannot read them and an XSS payload cannot
-- exfiltrate the session. Both carry @Secure@ and a @SameSite@ policy from
-- 'Shomei.Config.CookieConfig'.
--
-- In 'Shomei.Config.BearerToken' mode 'applyCookies' emits no headers at all, so a bearer
-- deployment's responses are byte-for-byte what they were before cookies existed.
module Shomei.Servant.Cookie
  ( WithCookies,
    CookiePair (..),
    sessionCookieName,
    refreshCookieName,
    tokenCookies,
    clearedCookies,
    applyCookies,
    refreshTokenFromCookie,
  )
where

import Data.ByteString (ByteString)
import Data.Text.Encoding qualified as Text
import Data.Time (secondsToDiffTime)
import Servant (Header, Headers, addHeader, noHeader)
import Shomei.Config (CookieConfig (..), SameSitePolicy (..), ShomeiConfig (..), transportUsesCookies)
import Shomei.Domain.RefreshToken (RefreshToken (..))
import Shomei.Domain.Token (AccessToken (..), TokenPair (..))
import Shomei.Prelude
import Web.Cookie
  ( SameSiteOption,
    SetCookie,
    defaultSetCookie,
    parseCookies,
    sameSiteLax,
    sameSiteNone,
    sameSiteStrict,
    setCookieHttpOnly,
    setCookieMaxAge,
    setCookieName,
    setCookiePath,
    setCookieSameSite,
    setCookieSecure,
    setCookieValue,
  )
import Web.HttpApiData (toUrlPiece)

-- | A response body carrying the two @Set-Cookie@ headers. Both are always present in the
-- type; 'applyCookies' decides whether they carry a value.
type WithCookies a =
  Headers '[Header "Set-Cookie" Text, Header "Set-Cookie" Text] a

-- | The rendered @Set-Cookie@ values for the session and refresh cookies.
data CookiePair = CookiePair
  { sessionCookie :: !Text,
    refreshCookie :: !Text
  }
  deriving stock (Eq, Show)

sessionCookieName :: ByteString
sessionCookieName = "shomei_session"

refreshCookieName :: ByteString
refreshCookieName = "shomei_refresh"

-- | The refresh cookie's @Path@ scope: the browser sends it to exactly one endpoint, so an
-- XSS anywhere else in the origin cannot read or replay it.
--
-- This must track the served path of 'Shomei.Servant.API.ShomeiAPI'\'s @refresh@ route, which
-- 'Shomei.Servant.API.ShomeiRoutes' mounts under @\/v1@. A host that mounts @ShomeiAPI@ at a
-- different prefix breaks the match and with it cookie-mode refresh.
refreshCookiePath :: ByteString
refreshCookiePath = "/v1/auth/refresh"

-- | The cookies that carry a freshly-issued token pair.
tokenCookies :: ShomeiConfig -> TokenPair -> CookiePair
tokenCookies cfg pair =
  CookiePair
    { sessionCookie = render (base sessionCookieName "/" cfg.accessTokenTTL) {setCookieValue = accessBytes},
      refreshCookie = render (base refreshCookieName refreshCookiePath cfg.refreshTokenTTL) {setCookieValue = refreshBytes}
    }
  where
    AccessToken accessText = pair.accessToken
    RefreshToken refreshText = pair.refreshToken
    accessBytes = Text.encodeUtf8 accessText
    refreshBytes = Text.encodeUtf8 refreshText
    base name path ttl =
      (cookieBase cfg name path) {setCookieMaxAge = Just (secondsToDiffTime (round ttl))}

-- | Cookies that delete their counterparts: same name, path, and flags (browsers match on
-- all three), empty value, @Max-Age=0@.
clearedCookies :: ShomeiConfig -> CookiePair
clearedCookies cfg =
  CookiePair
    { sessionCookie = render (expire (cookieBase cfg sessionCookieName "/")),
      refreshCookie = render (expire (cookieBase cfg refreshCookieName refreshCookiePath))
    }
  where
    expire c = c {setCookieValue = "", setCookieMaxAge = Just (secondsToDiffTime 0)}

cookieBase :: ShomeiConfig -> ByteString -> ByteString -> SetCookie
cookieBase cfg name path =
  defaultSetCookie
    { setCookieName = name,
      setCookiePath = Just path,
      setCookieHttpOnly = True,
      setCookieSecure = cfg.cookieConfig.secure,
      setCookieSameSite = Just (sameSiteOption cfg.cookieConfig.sameSite)
    }

sameSiteOption :: SameSitePolicy -> SameSiteOption
sameSiteOption = \case
  SameSiteStrict -> sameSiteStrict
  SameSiteLax -> sameSiteLax
  SameSiteNone -> sameSiteNone

-- | @web-cookie@'s @ToHttpApiData SetCookie@ renders exactly the header value we want
-- (@name=value; Path=…; Max-Age=…; HttpOnly; Secure; SameSite=Lax@).
render :: SetCookie -> Text
render = toUrlPiece

-- | Attach the cookies when the transport uses them; emit no headers otherwise.
applyCookies :: ShomeiConfig -> CookiePair -> a -> WithCookies a
applyCookies cfg pair body
  | transportUsesCookies cfg.tokenTransport = addHeader pair.sessionCookie (addHeader pair.refreshCookie body)
  | otherwise = noHeader (noHeader body)

-- | The @shomei_refresh@ value from a raw @Cookie@ request header.
refreshTokenFromCookie :: Text -> Maybe Text
refreshTokenFromCookie raw =
  Text.decodeUtf8 <$> lookup refreshCookieName (parseCookies (Text.encodeUtf8 raw))
