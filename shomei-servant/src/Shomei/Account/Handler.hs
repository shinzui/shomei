-- | Account and administrative-account HTTP adapters.
module Shomei.Account.Handler
  ( accountServer,
    adminAccountServer,
    loadUser,
    requireExistingUser,
  )
where

import Data.Text qualified as Text
import Servant (Handler, NoContent (..), throwError)
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
import Shomei.Servant.Auth (AuthUser (..))
import Shomei.Servant.Cookie (WithCookies, applyCookies, tokenCookies)
import Shomei.Servant.Error
  ( authErrorToServerError,
    pcSelfTargetForbidden,
    pcUserNotFound,
    toProblemError,
  )
import Shomei.Servant.Seam (Env (..), runAuth, runPort)
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

signupH :: Env -> SignupRequest -> Handler (WithCookies SignupResponse)
signupH env request = do
  loginId <- either (throwError . authErrorToServerError) pure (mkLoginId request.loginId)
  email <- traverse (either (throwError . authErrorToServerError) pure . mkEmail) request.email
  let command =
        SignupCommand
          { loginId,
            email,
            password = PlainPassword request.password,
            displayName = nonEmpty request.displayName
          }
  (user, tokens) <- runAuth env (Authentication.signup env.config command)
  pure $
    applyCookies env.config (tokenCookies env.config tokens) $
      SignupResponse
        { user = userToResponse user,
          token = tokenPairToResponse env.config tokens
        }

verifyEmailRequestH :: Env -> VerifyEmailRequest -> Handler NoContent
verifyEmailRequestH env request = do
  email <- either (throwError . authErrorToServerError) pure (mkEmail request.email)
  runAuth env (Account.requestEmailVerification env.config (Account.RequestEmailVerification email))
  pure NoContent

verifyEmailConfirmH :: Env -> ConfirmEmailVerificationRequest -> Handler NoContent
verifyEmailConfirmH env request = do
  runAuth env (Account.confirmEmailVerification env.config (Account.ConfirmEmailVerification (OneTimeToken request.token)))
  pure NoContent

passwordResetRequestH :: Env -> PasswordResetRequest -> Handler NoContent
passwordResetRequestH env request = do
  email <- either (throwError . authErrorToServerError) pure (mkEmail request.email)
  runAuth env (Account.requestPasswordReset env.config (Account.RequestPasswordReset email))
  pure NoContent

passwordResetConfirmH :: Env -> ConfirmPasswordResetRequest -> Handler NoContent
passwordResetConfirmH env request = do
  runAuth env $
    Account.confirmPasswordReset
      env.config
      (Account.ConfirmPasswordReset (OneTimeToken request.token) (PlainPassword request.newPassword))
  pure NoContent

passwordChangeH :: Env -> AuthUser -> ChangePasswordRequest -> Handler NoContent
passwordChangeH env user request = do
  denyUnderDelegation env "password_change" user
  runAuth env $
    Account.changePassword
      env.config
      (Account.ChangePassword user.authUserId (PlainPassword request.currentPassword) (PlainPassword request.newPassword))
  pure NoContent

meH :: Env -> AuthUser -> Handler UserResponse
meH env user = userToResponse <$> loadUser env user

loadUser :: Env -> AuthUser -> Handler User
loadUser env user = do
  found <- runPort env (findUserById user.authUserId)
  maybe (throwError (toProblemError pcUserNotFound Nothing)) pure found

adminListUsersH :: Env -> AuthUser -> Maybe AdminStatusFilter -> Maybe Int -> Maybe UserPageCursor -> Handler AdminUsersPage
adminListUsersH env _ status limit cursor = do
  let query =
        emptyUserListQuery
          { queryStatus = (.userStatus) <$> status,
            queryLimit = fromMaybe 50 limit,
            queryBefore = (.userCursor) <$> cursor
          }
  users <- runPort env (UserStore.listUsers query)
  let full = length users == clampUserLimit query.queryLimit
      nextCursor = if full then encodeUserCursor . cursorOf <$> lastMay users else Nothing
  pure AdminUsersPage {users = map userToResponse users, nextCursor}
  where
    cursorOf user = UserCursor {cursorCreatedAt = user.createdAt, cursorUserId = user.userId}

adminGetUserH :: Env -> AuthUser -> UserId -> Handler AdminUserResponse
adminGetUserH env _ target = do
  user <- requireExistingUser env target
  roles <- runAuth env (Roles.rolesOf target)
  pure (adminUserToResponse user roles)

adminSuspendUserH :: Env -> AuthUser -> UserId -> Handler NoContent
adminSuspendUserH env actor target = do
  denyUnderDelegation env "admin_suspend" actor
  denySelfTarget actor target
  runAuth env (Admin.suspendUser actor.authUserId target)
  pure NoContent

adminReinstateUserH :: Env -> AuthUser -> UserId -> Handler NoContent
adminReinstateUserH env actor target = do
  denyUnderDelegation env "admin_reinstate" actor
  runAuth env (Admin.reinstateUser actor.authUserId target)
  pure NoContent

adminDeleteUserH :: Env -> AuthUser -> UserId -> Handler NoContent
adminDeleteUserH env actor target = do
  denyUnderDelegation env "admin_delete" actor
  denySelfTarget actor target
  runAuth env (Admin.deleteUser actor.authUserId target)
  pure NoContent

adminPasswordResetH :: Env -> AuthUser -> UserId -> Handler NoContent
adminPasswordResetH env actor target = do
  denyUnderDelegation env "admin_password_reset" actor
  user <- requireExistingUser env target
  email <- maybe (throwError (authErrorToServerError UserHasNoEmail)) pure user.email
  runAuth env (Account.requestPasswordReset env.config (Account.RequestPasswordReset email))
  pure NoContent

requireExistingUser :: Env -> UserId -> Handler User
requireExistingUser env target = do
  found <- runPort env (findUserById target)
  maybe (throwError (authErrorToServerError UserNotFound)) pure found

denySelfTarget :: AuthUser -> UserId -> Handler ()
denySelfTarget actor target =
  when (target == actor.authUserId) $
    throwError (toProblemError pcSelfTargetForbidden Nothing)

lastMay :: [a] -> Maybe a
lastMay = \case
  [] -> Nothing
  values -> Just (last values)

nonEmpty :: Text -> Maybe Text
nonEmpty value
  | Text.null value = Nothing
  | otherwise = Just value
