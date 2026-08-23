{-# LANGUAGE EmptyCase #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE UndecidableInstances #-}
{-# OPTIONS_GHC -Wno-orphans #-}

-- | The shared typed response vocabulary for application routes.
--
-- Protocol APIs (OAuth and health) intentionally define their own response sums. Every ordinary
-- Shōmei application operation uses the fixed error tail below, so a new 'AuthError' remains a
-- total transport mapping and store unavailability is visible as an operation-owned 503.
module Shomei.Servant.Result
  ( AuthenticationPreHandlerResponses,
    AuthorizationPreHandlerResponses,
    BadRequestPreHandlerResponses,
    CsrfPreHandlerResponses,
    RateLimitPreHandlerResponses,
    ApplicationErrorResponses,
    ApplicationContentTypes,
    ApplicationResponses,
    ApplicationEmptyResponses,
    ApplicationCookieResponses,
    ApplicationCookieEmptyResponses,
    ApplicationResult (..),
    CookieHeaders,
    CookieResponse (..),
    WwwAuthenticateHeaders,
    ProblemWithAuthenticate (..),
    RetryAfterHeaders,
    ProblemWithRetryAfter (..),
    cookieResponse,
    applicationError,
    problemResult,
    fromPortResult,
    mapApplicationResult,
  )
where

import Data.ByteString (ByteString)
import Data.Foldable (toList)
import Data.SOP (I (..), NP (..), NS (..))
import Data.Sequence (Seq)
import Network.HTTP.Types qualified as HTTP
import Numeric.Natural (Natural)
import Servant (JSON, ServerError (..))
import Servant.API.MultiVerb
  ( AsHeaders (..),
    AsUnion (..),
    DescHeader,
    OptHeader,
    RespondAs,
    RespondEmpty,
    ServantHeaders (..),
    WithHeaders,
  )
import Shomei.Config (ShomeiConfig (..), transportUsesCookies)
import Shomei.Error (AuthError)
import Shomei.Prelude
import Shomei.Servant.Cookie (CookiePair (..))
import Shomei.Servant.Error
  ( ProblemDetails,
    ProblemJSON,
    ProblemOccurrence (..),
    ProblemSpec (..),
    authErrorProblem,
    problemDetails,
  )
import Web.HttpApiData (FromHttpApiData (parseHeader), ToHttpApiData (toHeader))

type WwwAuthenticateHeaders =
  '[OptHeader (DescHeader "WWW-Authenticate" "Bearer authentication challenge" Text)]

data ProblemWithAuthenticate = ProblemWithAuthenticate
  { authenticateProblem :: !ProblemDetails,
    authenticateHeader :: !(Maybe Text)
  }
  deriving stock (Eq, Show, Generic)

instance AsHeaders '[Maybe Text] ProblemDetails ProblemWithAuthenticate where
  toHeaders response = (I response.authenticateHeader :* Nil, response.authenticateProblem)
  fromHeaders (I authenticateHeader :* Nil, authenticateProblem) = ProblemWithAuthenticate {authenticateProblem, authenticateHeader}

instance {-# OVERLAPPING #-} ServantHeaders WwwAuthenticateHeaders '[Maybe Text] where
  constructHeaders (I authenticateHeader :* Nil) = optionalHeader "WWW-Authenticate" authenticateHeader
  extractHeaders headers = (\value -> I value :* Nil) <$> extractOptionalHeader "WWW-Authenticate" headers

type RetryAfterHeaders =
  '[OptHeader (DescHeader "Retry-After" "Seconds until the request may be retried" Natural)]

data ProblemWithRetryAfter = ProblemWithRetryAfter
  { retryProblem :: !ProblemDetails,
    retryAfterHeader :: !(Maybe Natural)
  }
  deriving stock (Eq, Show, Generic)

instance AsHeaders '[Maybe Natural] ProblemDetails ProblemWithRetryAfter where
  toHeaders response = (I response.retryAfterHeader :* Nil, response.retryProblem)
  fromHeaders (I retryAfterHeader :* Nil, retryProblem) = ProblemWithRetryAfter {retryProblem, retryAfterHeader}

instance {-# OVERLAPPING #-} ServantHeaders RetryAfterHeaders '[Maybe Natural] where
  constructHeaders (I retryAfterHeader :* Nil) = optionalHeader "Retry-After" retryAfterHeader
  extractHeaders headers = (\value -> I value :* Nil) <$> extractOptionalHeader "Retry-After" headers

type CookieHeaders =
  '[ OptHeader (DescHeader "Set-Cookie" "Session cookie" Text),
     OptHeader (DescHeader "Set-Cookie" "Refresh cookie" Text)
   ]

data CookieResponse a = CookieResponse
  { cookieBody :: !a,
    sessionCookieHeader :: !(Maybe Text),
    refreshCookieHeader :: !(Maybe Text)
  }
  deriving stock (Eq, Show, Generic, Functor)

instance AsHeaders '[Maybe Text, Maybe Text] a (CookieResponse a) where
  toHeaders response =
    ( I response.sessionCookieHeader :* I response.refreshCookieHeader :* Nil,
      response.cookieBody
    )
  fromHeaders (I sessionCookieHeader :* I refreshCookieHeader :* Nil, cookieBody) =
    CookieResponse {cookieBody, sessionCookieHeader, refreshCookieHeader}

-- servant 0.20.3's generic decoder requires every header to be present and partitions all
-- duplicate names into the first field. Shōmei's cookie response deliberately has two optional
-- Set-Cookie fields, so its client decoder must preserve absence and assign duplicates in order.
instance {-# OVERLAPPING #-} ServantHeaders CookieHeaders '[Maybe Text, Maybe Text] where
  constructHeaders (I sessionCookieHeader :* I refreshCookieHeader :* Nil) =
    optionalHeader "Set-Cookie" sessionCookieHeader
      <> optionalHeader "Set-Cookie" refreshCookieHeader
  extractHeaders headers = do
    values <- traverse decodeHeader (matchingHeaderValues "Set-Cookie" headers)
    case values of
      [] -> pure (I Nothing :* I Nothing :* Nil)
      [sessionCookieHeader] -> pure (I (Just sessionCookieHeader) :* I Nothing :* Nil)
      [sessionCookieHeader, refreshCookieHeader] ->
        pure (I (Just sessionCookieHeader) :* I (Just refreshCookieHeader) :* Nil)
      _ -> Nothing

optionalHeader :: (ToHttpApiData a) => HTTP.HeaderName -> Maybe a -> [HTTP.Header]
optionalHeader name = maybe [] (\value -> [(name, toHeader value)])

extractOptionalHeader :: (FromHttpApiData a) => HTTP.HeaderName -> Seq HTTP.Header -> Maybe (Maybe a)
extractOptionalHeader name headers = case matchingHeaderValues name headers of
  [] -> Just Nothing
  [value] -> Just <$> decodeHeader value
  _ -> Nothing

matchingHeaderValues :: HTTP.HeaderName -> Seq HTTP.Header -> [ByteString]
matchingHeaderValues name = map snd . filter ((== name) . fst) . toList

decodeHeader :: (FromHttpApiData a) => ByteString -> Maybe a
decodeHeader = either (const Nothing) Just . parseHeader

cookieResponse :: ShomeiConfig -> CookiePair -> a -> CookieResponse a
cookieResponse config cookies cookieBody
  | transportUsesCookies config.tokenTransport =
      CookieResponse
        { cookieBody,
          sessionCookieHeader = Just cookies.sessionCookie,
          refreshCookieHeader = Just cookies.refreshCookie
        }
  | otherwise = CookieResponse {cookieBody, sessionCookieHeader = Nothing, refreshCookieHeader = Nothing}

-- These small response lists are shared by the enforcing/pass-through combinators' OpenAPI
-- instances. Keeping them beside 'ApplicationErrorResponses' makes the pre-handler contract use
-- exactly the same media type, body, headers, and descriptions as the handler-owned result sum.
type AuthenticationPreHandlerResponses =
  '[ WithHeaders
       WwwAuthenticateHeaders
       ProblemWithAuthenticate
       (RespondAs ProblemJSON 401 "Authentication failed" ProblemDetails)
   ]

type AuthorizationPreHandlerResponses =
  '[ WithHeaders
       WwwAuthenticateHeaders
       ProblemWithAuthenticate
       (RespondAs ProblemJSON 401 "Authentication failed" ProblemDetails),
     RespondAs ProblemJSON 403 "Forbidden" ProblemDetails
   ]

type BadRequestPreHandlerResponses =
  '[RespondAs ProblemJSON 400 "Bad request" ProblemDetails]

type CsrfPreHandlerResponses =
  '[RespondAs ProblemJSON 403 "Forbidden" ProblemDetails]

type RateLimitPreHandlerResponses =
  '[ WithHeaders
       RetryAfterHeaders
       ProblemWithRetryAfter
       (RespondAs ProblemJSON 429 "Too many requests" ProblemDetails)
   ]

type ApplicationErrorResponses =
  '[ RespondAs ProblemJSON 400 "Bad request" ProblemDetails,
     WithHeaders
       WwwAuthenticateHeaders
       ProblemWithAuthenticate
       (RespondAs ProblemJSON 401 "Authentication failed" ProblemDetails),
     RespondAs ProblemJSON 403 "Forbidden" ProblemDetails,
     RespondAs ProblemJSON 404 "Not found" ProblemDetails,
     RespondAs ProblemJSON 409 "Conflict" ProblemDetails,
     RespondAs ProblemJSON 422 "Unprocessable content" ProblemDetails,
     WithHeaders
       RetryAfterHeaders
       ProblemWithRetryAfter
       (RespondAs ProblemJSON 429 "Too many requests" ProblemDetails),
     RespondAs ProblemJSON 500 "Internal server error" ProblemDetails,
     WithHeaders
       RetryAfterHeaders
       ProblemWithRetryAfter
       (RespondAs ProblemJSON 503 "Required dependency unavailable" ProblemDetails)
   ]

-- Both media types must be in the terminal content list: servant-client validates the response
-- Content-Type against this list before dispatching to a 'RespondAs' alternative.
type ApplicationContentTypes = '[JSON, ProblemJSON]

type ApplicationResponses status description body =
  RespondAs JSON status description body ': ApplicationErrorResponses

type ApplicationEmptyResponses status description =
  RespondEmpty status description ': ApplicationErrorResponses

type ApplicationCookieResponses status description body =
  WithHeaders CookieHeaders (CookieResponse body) (RespondAs JSON status description body)
    ': ApplicationErrorResponses

type ApplicationCookieEmptyResponses status description =
  WithHeaders CookieHeaders (CookieResponse ()) (RespondEmpty status description)
    ': ApplicationErrorResponses

data ApplicationResult a
  = ApplicationSuccess !a
  | ApplicationBadRequest !ProblemDetails
  | ApplicationAuthenticationFailed !ProblemWithAuthenticate
  | ApplicationForbidden !ProblemDetails
  | ApplicationNotFound !ProblemDetails
  | ApplicationConflict !ProblemDetails
  | ApplicationUnprocessable !ProblemDetails
  | ApplicationRateLimited !ProblemWithRetryAfter
  | ApplicationInternal !ProblemDetails
  | ApplicationUnavailable !ProblemWithRetryAfter
  deriving stock (Eq, Show, Generic, Functor)

-- | Load-bearing constructor-to-status mapping. It is intentionally written out: most error
-- arms have the same body type, so a generic derivation would make their order too easy to swap.
instance AsUnion (RespondAs JSON status description a ': ApplicationErrorResponses) (ApplicationResult a) where
  toUnion = \case
    ApplicationSuccess value -> Z (I value)
    ApplicationBadRequest value -> S (Z (I value))
    ApplicationAuthenticationFailed value -> S (S (Z (I value)))
    ApplicationForbidden value -> S (S (S (Z (I value))))
    ApplicationNotFound value -> S (S (S (S (Z (I value)))))
    ApplicationConflict value -> S (S (S (S (S (Z (I value))))))
    ApplicationUnprocessable value -> S (S (S (S (S (S (Z (I value)))))))
    ApplicationRateLimited value -> S (S (S (S (S (S (S (Z (I value))))))))
    ApplicationInternal value -> S (S (S (S (S (S (S (S (Z (I value)))))))))
    ApplicationUnavailable value -> S (S (S (S (S (S (S (S (S (Z (I value))))))))))

  fromUnion = \case
    Z (I value) -> ApplicationSuccess value
    S (Z (I value)) -> ApplicationBadRequest value
    S (S (Z (I value))) -> ApplicationAuthenticationFailed value
    S (S (S (Z (I value)))) -> ApplicationForbidden value
    S (S (S (S (Z (I value))))) -> ApplicationNotFound value
    S (S (S (S (S (Z (I value)))))) -> ApplicationConflict value
    S (S (S (S (S (S (Z (I value))))))) -> ApplicationUnprocessable value
    S (S (S (S (S (S (S (Z (I value)))))))) -> ApplicationRateLimited value
    S (S (S (S (S (S (S (S (Z (I value))))))))) -> ApplicationInternal value
    S (S (S (S (S (S (S (S (S (Z (I value)))))))))) -> ApplicationUnavailable value
    S (S (S (S (S (S (S (S (S (S (impossible)))))))))) -> absurdNS impossible

-- Empty and cookie successes have different MultiVerb response return types, while retaining
-- exactly the same fixed error-tail mapping.
instance AsUnion (RespondEmpty status description ': ApplicationErrorResponses) (ApplicationResult ()) where
  toUnion = applicationToUnion
  fromUnion = applicationFromUnion

instance AsUnion (WithHeaders CookieHeaders (CookieResponse a) response ': ApplicationErrorResponses) (ApplicationResult (CookieResponse a)) where
  toUnion = applicationToUnion
  fromUnion = applicationFromUnion

applicationToUnion :: ApplicationResult a -> NS I (a ': '[ProblemDetails, ProblemWithAuthenticate, ProblemDetails, ProblemDetails, ProblemDetails, ProblemDetails, ProblemWithRetryAfter, ProblemDetails, ProblemWithRetryAfter])
applicationToUnion = \case
  ApplicationSuccess value -> Z (I value)
  ApplicationBadRequest value -> S (Z (I value))
  ApplicationAuthenticationFailed value -> S (S (Z (I value)))
  ApplicationForbidden value -> S (S (S (Z (I value))))
  ApplicationNotFound value -> S (S (S (S (Z (I value)))))
  ApplicationConflict value -> S (S (S (S (S (Z (I value))))))
  ApplicationUnprocessable value -> S (S (S (S (S (S (Z (I value)))))))
  ApplicationRateLimited value -> S (S (S (S (S (S (S (Z (I value))))))))
  ApplicationInternal value -> S (S (S (S (S (S (S (S (Z (I value)))))))))
  ApplicationUnavailable value -> S (S (S (S (S (S (S (S (S (Z (I value))))))))))

applicationFromUnion :: NS I (a ': '[ProblemDetails, ProblemWithAuthenticate, ProblemDetails, ProblemDetails, ProblemDetails, ProblemDetails, ProblemWithRetryAfter, ProblemDetails, ProblemWithRetryAfter]) -> ApplicationResult a
applicationFromUnion = \case
  Z (I value) -> ApplicationSuccess value
  S (Z (I value)) -> ApplicationBadRequest value
  S (S (Z (I value))) -> ApplicationAuthenticationFailed value
  S (S (S (Z (I value)))) -> ApplicationForbidden value
  S (S (S (S (Z (I value))))) -> ApplicationNotFound value
  S (S (S (S (S (Z (I value)))))) -> ApplicationConflict value
  S (S (S (S (S (S (Z (I value))))))) -> ApplicationUnprocessable value
  S (S (S (S (S (S (S (Z (I value)))))))) -> ApplicationRateLimited value
  S (S (S (S (S (S (S (S (Z (I value))))))))) -> ApplicationInternal value
  S (S (S (S (S (S (S (S (S (Z (I value)))))))))) -> ApplicationUnavailable value
  S (S (S (S (S (S (S (S (S (S (impossible)))))))))) -> absurdNS impossible

absurdNS :: NS I '[] -> a
absurdNS = \case {}

applicationError :: AuthError -> ApplicationResult a
applicationError err = uncurry problemResult (authErrorProblem err)

fromPortResult :: Either AuthError a -> ApplicationResult a
fromPortResult = either applicationError ApplicationSuccess

problemResult :: ProblemSpec -> ProblemOccurrence -> ApplicationResult a
problemResult spec occurrence =
  case spec.problemStatus.errHTTPCode of
    400 -> ApplicationBadRequest body
    401 -> ApplicationAuthenticationFailed (ProblemWithAuthenticate body occurrence.wwwAuthenticate)
    403 -> ApplicationForbidden body
    404 -> ApplicationNotFound body
    409 -> ApplicationConflict body
    422 -> ApplicationUnprocessable body
    429 -> ApplicationRateLimited (ProblemWithRetryAfter body occurrence.retryAfterSeconds)
    503 -> ApplicationUnavailable (ProblemWithRetryAfter body occurrence.retryAfterSeconds)
    _ -> ApplicationInternal body
  where
    body = problemDetails spec occurrence

mapApplicationResult :: (a -> b) -> ApplicationResult a -> ApplicationResult b
mapApplicationResult f = \case
  ApplicationSuccess value -> ApplicationSuccess (f value)
  ApplicationBadRequest value -> ApplicationBadRequest value
  ApplicationAuthenticationFailed value -> ApplicationAuthenticationFailed value
  ApplicationForbidden value -> ApplicationForbidden value
  ApplicationNotFound value -> ApplicationNotFound value
  ApplicationConflict value -> ApplicationConflict value
  ApplicationUnprocessable value -> ApplicationUnprocessable value
  ApplicationRateLimited value -> ApplicationRateLimited value
  ApplicationInternal value -> ApplicationInternal value
  ApplicationUnavailable value -> ApplicationUnavailable value
