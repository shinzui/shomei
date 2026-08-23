-- | Named account response lists and handler result types.
module Shomei.Account.Result
  ( SignupResponses,
    SignupResult,
    VerifyEmailRequestResponses,
    VerifyEmailRequestResult,
    VerifyEmailConfirmResponses,
    VerifyEmailConfirmResult,
    PasswordResetRequestResponses,
    PasswordResetRequestResult,
    PasswordResetConfirmResponses,
    PasswordResetConfirmResult,
    PasswordChangeResponses,
    PasswordChangeResult,
    MeResponses,
    MeResult,
    ListUsersResponses,
    ListUsersResult,
    GetUserResponses,
    GetUserResult,
    SuspendUserResponses,
    SuspendUserResult,
    ReinstateUserResponses,
    ReinstateUserResult,
    DeleteUserResponses,
    DeleteUserResult,
    AdminPasswordResetResponses,
    AdminPasswordResetResult,
  )
where

import Shomei.Account.Dto (SignupResponse)
import Shomei.Account.User.Dto (AdminUserResponse, AdminUsersPage, UserResponse)
import Shomei.Servant.Result

type SignupResponses = ApplicationCookieResponses 201 "Account created" SignupResponse

type SignupResult = ApplicationResult (CookieResponse SignupResponse)

type VerifyEmailRequestResponses = ApplicationEmptyResponses 202 "Verification request accepted"

type VerifyEmailRequestResult = ApplicationResult ()

type VerifyEmailConfirmResponses = ApplicationEmptyResponses 200 "Email verified"

type VerifyEmailConfirmResult = ApplicationResult ()

type PasswordResetRequestResponses = ApplicationEmptyResponses 202 "Password reset request accepted"

type PasswordResetRequestResult = ApplicationResult ()

type PasswordResetConfirmResponses = ApplicationEmptyResponses 200 "Password reset"

type PasswordResetConfirmResult = ApplicationResult ()

type PasswordChangeResponses = ApplicationEmptyResponses 204 "Password changed"

type PasswordChangeResult = ApplicationResult ()

type MeResponses = ApplicationResponses 200 "Current account" UserResponse

type MeResult = ApplicationResult UserResponse

type ListUsersResponses = ApplicationResponses 200 "Users" AdminUsersPage

type ListUsersResult = ApplicationResult AdminUsersPage

type GetUserResponses = ApplicationResponses 200 "User" AdminUserResponse

type GetUserResult = ApplicationResult AdminUserResponse

type SuspendUserResponses = ApplicationEmptyResponses 204 "User suspended"

type SuspendUserResult = ApplicationResult ()

type ReinstateUserResponses = ApplicationEmptyResponses 204 "User reinstated"

type ReinstateUserResult = ApplicationResult ()

type DeleteUserResponses = ApplicationEmptyResponses 204 "User deleted"

type DeleteUserResult = ApplicationResult ()

type AdminPasswordResetResponses = ApplicationEmptyResponses 202 "Password reset requested"

type AdminPasswordResetResult = ApplicationResult ()
