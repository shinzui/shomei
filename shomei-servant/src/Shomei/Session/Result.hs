-- | Named session response lists and handler result types.
module Shomei.Session.Result
  ( LoginResponses,
    LoginResult,
    RefreshResponses,
    RefreshResult,
    LogoutResponses,
    LogoutResult,
    CurrentSessionResponses,
    CurrentSessionResult,
    ListSessionsResponses,
    ListSessionsResult,
    RevokeSessionsResponses,
    RevokeSessionsResult,
    RevokeSessionResponses,
    RevokeSessionResult,
  )
where

import Shomei.Servant.Result
import Shomei.Session.Dto (LoginResponse, SessionResponse, TokenPairResponse)

type LoginResponses = ApplicationCookieResponses 200 "Authenticated" LoginResponse

type LoginResult = ApplicationResult (CookieResponse LoginResponse)

type RefreshResponses = ApplicationCookieResponses 200 "Tokens refreshed" TokenPairResponse

type RefreshResult = ApplicationResult (CookieResponse TokenPairResponse)

type LogoutResponses = ApplicationCookieEmptyResponses 204 "Logged out"

type LogoutResult = ApplicationResult (CookieResponse ())

type CurrentSessionResponses = ApplicationResponses 200 "Current session" SessionResponse

type CurrentSessionResult = ApplicationResult SessionResponse

type ListSessionsResponses = ApplicationResponses 200 "Sessions" [SessionResponse]

type ListSessionsResult = ApplicationResult [SessionResponse]

type RevokeSessionsResponses = ApplicationEmptyResponses 204 "Sessions revoked"

type RevokeSessionsResult = ApplicationResult ()

type RevokeSessionResponses = ApplicationEmptyResponses 204 "Session revoked"

type RevokeSessionResult = ApplicationResult ()
