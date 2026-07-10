module Main (main) where

import Shomei.AccountSpec qualified
import Shomei.BreachSpec qualified
import Shomei.Domain.EventCodecSpec qualified
import Shomei.Domain.PasswordSpec qualified
import Shomei.LockoutSpec qualified
import Shomei.PasskeyStoreSpec qualified
import Shomei.ServiceAccountStoreSpec qualified
import Shomei.WebAuthnCeremonySpec qualified
import Shomei.Workflow.AdminSpec qualified
import Shomei.Workflow.ClientCredentialsSpec qualified
import Shomei.Workflow.ConcurrencySpec qualified
import Shomei.Workflow.EmailVerificationSpec qualified
import Shomei.Workflow.ImpersonationSpec qualified
import Shomei.Workflow.MfaSpec qualified
import Shomei.Workflow.PasskeySpec qualified
import Shomei.Workflow.RolesSpec qualified
import Shomei.Workflow.ServiceTokenSpec qualified
import Shomei.Workflow.TimingSpec qualified
import Shomei.WorkflowSpec qualified
import Test.Tasty (defaultMain, testGroup)

main :: IO ()
main =
  defaultMain
    ( testGroup
        "shomei-core-test"
        [ Shomei.WorkflowSpec.tests,
          Shomei.AccountSpec.tests,
          Shomei.BreachSpec.tests,
          Shomei.Domain.EventCodecSpec.tests,
          Shomei.Domain.PasswordSpec.tests,
          Shomei.LockoutSpec.tests,
          Shomei.PasskeyStoreSpec.tests,
          Shomei.ServiceAccountStoreSpec.tests,
          Shomei.WebAuthnCeremonySpec.tests,
          Shomei.Workflow.MfaSpec.tests,
          Shomei.Workflow.ImpersonationSpec.tests,
          Shomei.Workflow.ServiceTokenSpec.tests,
          Shomei.Workflow.AdminSpec.tests,
          Shomei.Workflow.RolesSpec.tests,
          Shomei.Workflow.TimingSpec.tests,
          Shomei.Workflow.EmailVerificationSpec.tests,
          Shomei.Workflow.PasskeySpec.tests,
          Shomei.Workflow.ClientCredentialsSpec.tests,
          Shomei.Workflow.ConcurrencySpec.tests
        ]
    )
