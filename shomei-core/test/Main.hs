module Main (main) where

import Shomei.Account.Admin.WorkflowSpec qualified
import Shomei.Account.Password.DomainSpec qualified
import Shomei.Account.Verification.WorkflowSpec qualified
import Shomei.AccountSpec qualified
import Shomei.Audit.Event.CodecSpec qualified
import Shomei.Authorization.Role.WorkflowSpec qualified
import Shomei.BreachSpec qualified
import Shomei.Delegation.WorkflowSpec qualified
import Shomei.LockoutSpec qualified
import Shomei.Mfa.Totp.AlgorithmSpec qualified
import Shomei.Mfa.Totp.StoreSpec qualified
import Shomei.Mfa.WorkflowSpec qualified
import Shomei.OAuth.TokenExchange.WorkflowSpec qualified
import Shomei.OAuthClientStoreSpec qualified
import Shomei.OAuthCodeStoreSpec qualified
import Shomei.Passkey.WorkflowSpec qualified
import Shomei.PasskeyStoreSpec qualified
import Shomei.ServiceAccount.ClientCredentials.WorkflowSpec qualified
import Shomei.ServiceAccountStoreSpec qualified
import Shomei.Session.Authentication.ConcurrencySpec qualified
import Shomei.Session.Authentication.TimingSpec qualified
import Shomei.Session.Authentication.WorkflowSpec qualified
import Shomei.WebAuthnCeremonySpec qualified
import Test.Tasty (defaultMain, testGroup)

main :: IO ()
main =
  defaultMain
    ( testGroup
        "shomei-core-test"
        [ Shomei.Session.Authentication.WorkflowSpec.tests,
          Shomei.Mfa.Totp.AlgorithmSpec.tests,
          Shomei.Mfa.Totp.StoreSpec.tests,
          Shomei.AccountSpec.tests,
          Shomei.BreachSpec.tests,
          Shomei.Audit.Event.CodecSpec.tests,
          Shomei.Account.Password.DomainSpec.tests,
          Shomei.LockoutSpec.tests,
          Shomei.PasskeyStoreSpec.tests,
          Shomei.OAuthClientStoreSpec.tests,
          Shomei.OAuthCodeStoreSpec.tests,
          Shomei.ServiceAccountStoreSpec.tests,
          Shomei.WebAuthnCeremonySpec.tests,
          Shomei.Mfa.WorkflowSpec.tests,
          Shomei.Delegation.WorkflowSpec.tests,
          Shomei.Account.Admin.WorkflowSpec.tests,
          Shomei.Authorization.Role.WorkflowSpec.tests,
          Shomei.Session.Authentication.TimingSpec.tests,
          Shomei.Account.Verification.WorkflowSpec.tests,
          Shomei.Passkey.WorkflowSpec.tests,
          Shomei.ServiceAccount.ClientCredentials.WorkflowSpec.tests,
          Shomei.Session.Authentication.ConcurrencySpec.tests,
          Shomei.OAuth.TokenExchange.WorkflowSpec.tests
        ]
    )
