-- | Account and administrative-account HTTP adapters.
module Shomei.Account.Handler
  ( accountServer,
    adminAccountServer,
    loadUser,
    requireExistingUser,
  )
where

import Data.Text qualified as Text
import Servant (Handler)
import Servant.Server.Generic (AsServerT)
import Shomei.Account.Admin.Api (AdminAccountApi (..))
import Shomei.Account.Admin.Workflow qualified as Admin
import Shomei.Account.Api (AccountApi (..))
import Shomei.Account.Dto
import Shomei.Account.Email.Domain (mkEmail)
import Shomei.Account.Lifecycle.Workflow qualified as Account
import Shomei.Account.LoginId.Domain (mkLoginId)
import Shomei.Account.OneTimeToken.Domain (OneTimeToken (..))
import Shomei.Account.Password.Domain (PlainPassword (..))
import Shomei.Account.Result
import Shomei.Account.User.Domain (User (..))
import Shomei.Account.User.Dto
import Shomei.Account.User.Store
  ( UserCursor (..),
    UserListQuery (..),
    clampUserLimit,
    emptyUserListQuery,
    findUserById,
  )
import Shomei.Account.User.Store qualified as UserStore
import Shomei.Authorization.Role.Workflow qualified as Roles
import Shomei.Delegation.Handler (denyUnderDelegation)
import Shomei.Error (AuthError (UserHasNoEmail, UserNotFound))
import Shomei.Id (UserId)
import Shomei.Prelude
import Shomei.Servant.Application (ApplicationHandler, port, rejectAuth, rejectProblem, runApplicationHandler, workflow)
import Shomei.Servant.Auth (AuthUser (..))
import Shomei.Servant.Cookie (tokenCookies)
import Shomei.Servant.Error (noProblemOccurrence, pcSelfTargetForbidden)
import Shomei.Servant.Result (cookieResponse)
import Shomei.Servant.Seam (Env (..))
import Shomei.Session.Authentication.Workflow qualified as Authentication
import Shomei.Session.Command (SignupCommand (..))
import Shomei.Session.Dto (tokenPairToResponse)

accountServer :: Env -> AccountApi (AsServerT Handler)
accountServer env =
  AccountApi
    { signup = signupH env,
      verifyEmailRequest = verifyEmailRequestH env,
      verifyEmailConfirm = verifyEmailConfirmH env,
      passwordResetRequest = passwordResetRequestH env,
      passwordResetConfirm = passwordResetConfirmH env,
      passwordChange = passwordChangeH env,
      me = meH env
    }

adminAccountServer :: Env -> AdminAccountApi (AsServerT Handler)
adminAccountServer env =
  AdminAccountApi
    { listUsers = adminListUsersH env,
      getUser = adminGetUserH env,
      suspendUser = adminSuspendUserH env,
      reinstateUser = adminReinstateUserH env,
      deleteUser = adminDeleteUserH env,
      passwordReset = adminPasswordResetH env
    }

signupH :: Env -> SignupRequest -> Handler SignupResult
signupH env request = runApplicationHandler do
  loginId <- either rejectAuth pure (mkLoginId request.loginId)
  email <- traverse (either rejectAuth pure . mkEmail) request.email
  let command =
        SignupCommand
          { loginId,
            email,
            password = PlainPassword request.password,
            displayName = nonEmpty request.displayName
          }
  (user, tokens) <- workflow env (Authentication.signup env.config command)
  pure $
    cookieResponse env.config (tokenCookies env.config tokens) $
      SignupResponse
        { user = userToResponse user,
          token = tokenPairToResponse env.config tokens
        }

verifyEmailRequestH :: Env -> VerifyEmailRequest -> Handler VerifyEmailRequestResult
verifyEmailRequestH env request = runApplicationHandler do
  email <- either rejectAuth pure (mkEmail request.email)
  workflow env (Account.requestEmailVerification env.config (Account.RequestEmailVerification email))

verifyEmailConfirmH :: Env -> ConfirmEmailVerificationRequest -> Handler VerifyEmailConfirmResult
verifyEmailConfirmH env request = runApplicationHandler do
  workflow env (Account.confirmEmailVerification env.config (Account.ConfirmEmailVerification (OneTimeToken request.token)))

passwordResetRequestH :: Env -> PasswordResetRequest -> Handler PasswordResetRequestResult
passwordResetRequestH env request = runApplicationHandler do
  email <- either rejectAuth pure (mkEmail request.email)
  workflow env (Account.requestPasswordReset env.config (Account.RequestPasswordReset email))

passwordResetConfirmH :: Env -> ConfirmPasswordResetRequest -> Handler PasswordResetConfirmResult
passwordResetConfirmH env request = runApplicationHandler do
  workflow env $
    Account.confirmPasswordReset
      env.config
      (Account.ConfirmPasswordReset (OneTimeToken request.token) (PlainPassword request.newPassword))

passwordChangeH :: Env -> AuthUser -> ChangePasswordRequest -> Handler PasswordChangeResult
passwordChangeH env user request = runApplicationHandler do
  denyUnderDelegation env "password_change" user
  workflow env $
    Account.changePassword
      env.config
      (Account.ChangePassword user.authUserId (PlainPassword request.currentPassword) (PlainPassword request.newPassword))

meH :: Env -> AuthUser -> Handler MeResult
meH env user = runApplicationHandler (userToResponse <$> loadUser env user)

loadUser :: Env -> AuthUser -> ApplicationHandler User
loadUser env user = do
  found <- port env (findUserById user.authUserId)
  maybe (rejectAuth UserNotFound) pure found

adminListUsersH :: Env -> AuthUser -> Maybe AdminStatusFilter -> Maybe Int -> Maybe UserPageCursor -> Handler ListUsersResult
adminListUsersH env _ status limit cursor = runApplicationHandler do
  let query =
        emptyUserListQuery
          { queryStatus = (.userStatus) <$> status,
            queryLimit = fromMaybe 50 limit,
            queryBefore = (.userCursor) <$> cursor
          }
  users <- port env (UserStore.listUsers query)
  let full = length users == clampUserLimit query.queryLimit
      nextCursor = if full then encodeUserCursor . cursorOf <$> lastMay users else Nothing
  pure AdminUsersPage {users = map userToResponse users, nextCursor}
  where
    cursorOf user = UserCursor {cursorCreatedAt = user.createdAt, cursorUserId = user.userId}

adminGetUserH :: Env -> AuthUser -> UserId -> Handler GetUserResult
adminGetUserH env _ target = runApplicationHandler do
  user <- requireExistingUser env target
  roles <- workflow env (Roles.rolesOf target)
  pure (adminUserToResponse user roles)

adminSuspendUserH :: Env -> AuthUser -> UserId -> Handler SuspendUserResult
adminSuspendUserH env actor target = runApplicationHandler do
  denyUnderDelegation env "admin_suspend" actor
  denySelfTarget actor target
  workflow env (Admin.suspendUser actor.authUserId target)

adminReinstateUserH :: Env -> AuthUser -> UserId -> Handler ReinstateUserResult
adminReinstateUserH env actor target = runApplicationHandler do
  denyUnderDelegation env "admin_reinstate" actor
  workflow env (Admin.reinstateUser actor.authUserId target)

adminDeleteUserH :: Env -> AuthUser -> UserId -> Handler DeleteUserResult
adminDeleteUserH env actor target = runApplicationHandler do
  denyUnderDelegation env "admin_delete" actor
  denySelfTarget actor target
  workflow env (Admin.deleteUser actor.authUserId target)

adminPasswordResetH :: Env -> AuthUser -> UserId -> Handler AdminPasswordResetResult
adminPasswordResetH env actor target = runApplicationHandler do
  denyUnderDelegation env "admin_password_reset" actor
  user <- requireExistingUser env target
  email <- maybe (rejectAuth UserHasNoEmail) pure user.email
  workflow env (Account.requestPasswordReset env.config (Account.RequestPasswordReset email))

requireExistingUser :: Env -> UserId -> ApplicationHandler User
requireExistingUser env target = do
  found <- port env (findUserById target)
  maybe (rejectAuth UserNotFound) pure found

denySelfTarget :: AuthUser -> UserId -> ApplicationHandler ()
denySelfTarget actor target =
  when (target == actor.authUserId) $
    rejectProblem pcSelfTargetForbidden noProblemOccurrence

lastMay :: [a] -> Maybe a
lastMay = \case
  [] -> Nothing
  values -> Just (last values)

nonEmpty :: Text -> Maybe Text
nonEmpty value
  | Text.null value = Nothing
  | otherwise = Just value
