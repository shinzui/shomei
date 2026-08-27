# Shōmei problem details

Application errors use RFC 9457 Problem Details and the media type
`application/problem+json`. The `type` member is the primary identifier and is always this
page's public URL followed by one of the anchors below. `code` is the same anchor without the
URL prefix; `retryable` is a Shōmei extension. Clients must ignore unknown extension members.

`detail` and `instance` are optional occurrence data. They never contain tokens, database
identifiers, driver messages, stack traces, or other secrets. A client should branch on `type`
or `code`, not on `title` or `detail`.

| Type anchor | Stable title | Status | Retryable | Safe client behavior | `Retry-After` |
| --- | --- | ---: | :---: | --- | --- |
| <a id="invalid_email"></a>`invalid_email` | Email is not valid | 400 | no | Correct the email field. | never |
| <a id="invalid_login_id"></a>`invalid_login_id` | Login identifier is not valid | 400 | no | Correct the login identifier. | never |
| <a id="weak_password"></a>`weak_password` | Password does not meet policy | 400 | no | Choose a policy-compliant password. | never |
| <a id="email_taken"></a>`email_taken` | Email is already registered | 409 | no | Use another email or recover the existing account. | never |
| <a id="login_id_taken"></a>`login_id_taken` | Login identifier is already registered | 409 | no | Choose another login identifier. | never |
| <a id="invalid_login"></a>`invalid_login` | Invalid login identifier or password | 401 | no | Re-enter credentials without probing account existence. | never |
| <a id="too_many_requests"></a>`too_many_requests` | Too many requests | 429 | yes | Wait before retrying. | always, in seconds |
| <a id="session_not_found"></a>`session_not_found` | Session not found | 404 | no | Refresh local session state. | never |
| <a id="session_expired"></a>`session_expired` | Session expired | 401 | no | Authenticate again. | never |
| <a id="session_revoked"></a>`session_revoked` | Session revoked | 401 | no | Authenticate again. | never |
| <a id="token_invalid"></a>`token_invalid` | Token is invalid | 401 | no | Discard the token and authenticate again. | never |
| <a id="token_expired"></a>`token_expired` | Refresh token expired | 401 | no | Authenticate again. | never |
| <a id="token_reuse"></a>`token_reuse` | Refresh token reuse detected | 401 | no | Discard the token family and authenticate again. | never |
| <a id="verification_token_invalid"></a>`verification_token_invalid` | Verification token is invalid | 400 | no | Request a new verification token. | never |
| <a id="password_reset_token_invalid"></a>`password_reset_token_invalid` | Password reset token is invalid | 400 | no | Request a new password-reset token. | never |
| <a id="email_already_verified"></a>`email_already_verified` | Email is already verified | 409 | no | Refresh account state. | never |
| <a id="email_not_verified"></a>`email_not_verified` | Email address is not verified | 403 | no | Complete email verification. | never |
| <a id="passkey_not_found"></a>`passkey_not_found` | Passkey not found | 404 | no | Refresh the passkey list. | never |
| <a id="ceremony_not_found"></a>`ceremony_not_found` | Registration ceremony not found or expired | 404 | no | Start a new ceremony. | never |
| <a id="webauthn_verification_failed"></a>`webauthn_verification_failed` | Passkey registration could not be verified | 400 | no | Start a new ceremony and retry locally. | never |
| <a id="mfa_failed"></a>`mfa_failed` | Multi-factor authentication failed | 401 | no | Present a fresh valid proof. | never |
| <a id="totp_disabled"></a>`totp_disabled` | TOTP is not enabled | 403 | no | Use an enabled authentication method. | never |
| <a id="totp_already_enrolled"></a>`totp_already_enrolled` | A TOTP credential is already enrolled | 409 | no | Remove the existing credential first. | never |
| <a id="totp_enrollment_not_found"></a>`totp_enrollment_not_found` | No pending TOTP enrollment to verify | 404 | no | Start a new enrollment. | never |
| <a id="totp_code_invalid"></a>`totp_code_invalid` | TOTP code is invalid | 401 | no | Present a new current code. | never |
| <a id="recovery_code_invalid"></a>`recovery_code_invalid` | Recovery code is invalid | 401 | no | Present an unused recovery code. | never |
| <a id="reauthentication_required"></a>`reauthentication_required` | Recent authentication required for this action | 403 | no | Log in again (or complete MFA again); refreshing does not count. | never |
| <a id="impersonation_forbidden"></a>`impersonation_forbidden` | Not allowed to impersonate | 403 | no | Stop; the caller lacks delegation authority. | never |
| <a id="impersonation_target_invalid"></a>`impersonation_target_invalid` | Invalid impersonation target | 400 | no | Correct the delegation target. | never |
| <a id="impersonation_action_blocked"></a>`impersonation_action_blocked` | This action is not permitted while impersonating | 403 | no | Use the actor's own session. | never |
| <a id="user_not_found"></a>`user_not_found` | User not found | 404 | no | Refresh user state. | never |
| <a id="role_not_defined"></a>`role_not_defined` | Role not defined | 422 | no | Choose a role defined by the deployment. | never |
| <a id="dependency_unavailable"></a>`dependency_unavailable` | Required dependency unavailable | 503 | yes | Retry with backoff. | only when an honest interval is known |
| <a id="internal"></a>`internal` | Internal authentication error | 500 | no | Stop automatic retries and report the occurrence. | never |
| <a id="invalid_user_status"></a>`invalid_user_status` | User is not in a state that allows this action | 409 | no | Refresh the user and reconsider the transition. | never |
| <a id="user_has_no_email"></a>`user_has_no_email` | User has no email address | 409 | no | Add an email or choose another recovery path. | never |
| <a id="missing_token"></a>`missing_token` | Authentication required | 401 | no | Present a bearer credential. | never |
| <a id="missing_role"></a>`missing_role` | Missing required role | 403 | no | Stop; the principal lacks the required role. | never |
| <a id="missing_scope"></a>`missing_scope` | Missing required scope | 403 | no | Obtain a token with the required scope. | never |
| <a id="missing_permission"></a>`missing_permission` | Missing required permission | 403 | no | Stop; the principal lacks the required permission. | never |
| <a id="csrf_rejected"></a>`csrf_rejected` | Origin not allowed for cookie-authenticated request | 403 | no | Use an allowed origin or bearer transport. | never |
| <a id="bad_request"></a>`bad_request` | Bad request | 400 | no | Correct the occurrence-specific request detail. | never |
| <a id="payload_too_large"></a>`payload_too_large` | Request body too large | 413 | no | Send a smaller body. | never |
| <a id="body_parse_error"></a>`body_parse_error` | Request body could not be parsed | 400 | no | Send a body matching the published schema. | never |
| <a id="not_found"></a>`not_found` | Resource not found | 404 | no | Correct the request path. | never |
| <a id="method_not_allowed"></a>`method_not_allowed` | Method not allowed | 405 | no | Use a method published for the path. | never |
| <a id="self_target_forbidden"></a>`self_target_forbidden` | An administrator cannot perform this action on their own account | 403 | no | Choose another administrator or target. | never |
| <a id="role_not_granted"></a>`role_not_granted` | User does not hold that role | 404 | no | Refresh the user's grants. | never |

OAuth/OIDC protocol errors are intentionally not listed here: those operations retain the RFC
6749 JSON vocabulary. Health probes retain the package-owned `servant-health` report shape.
