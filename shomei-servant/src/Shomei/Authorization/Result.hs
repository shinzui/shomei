module Shomei.Authorization.Result
  ( GrantRoleResponses,
    GrantRoleResult,
    RevokeRoleResponses,
    RevokeRoleResult,
  )
where

import Shomei.Servant.Result

type GrantRoleResponses = ApplicationEmptyResponses 204 "Role granted"

type GrantRoleResult = ApplicationResult ()

type RevokeRoleResponses = ApplicationEmptyResponses 204 "Role revoked"

type RevokeRoleResult = ApplicationResult ()
