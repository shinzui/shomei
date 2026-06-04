let Schema =
      https://raw.githubusercontent.com/shinzui/mori-schema/026ae74331e5c516542af1dd96f041c658ed4621/package.dhall
        sha256:18258ef583580a897f4af3e7c86db0342afb42fb40efc535b217ba1089230141

in  Schema.Project::{
    , project = Schema.ProjectIdentity::{
      , name = "shomei"
      , namespace = "shinzui"
      , type = Schema.PackageType.Library
      , language = Schema.Language.Haskell
      , lifecycle = Schema.Lifecycle.Experimental
      , description = Some
          "Haskell authentication toolkit — standalone auth service or embedded Servant library (password login, sessions, refresh-token rotation, JWT/JWKS, PostgreSQL)"
      , domains = [ "Backend", "Security" ]
      , owners = [ "shinzui" ]
      }
    , repos = [ Schema.Repo::{ name = "shomei", github = Some "shinzui/shomei" } ]
    , packages =
      [ Schema.Package::{
        , name = "shomei-core"
        , type = Schema.PackageType.Library
        , language = Schema.Language.Haskell
        , path = Some "packages/shomei-core"
        , description = Some
            "Transport-agnostic domain: types, commands, events, errors, and ports (no Servant/WAI/PostgreSQL/JWT/HTTP deps)"
        }
      , Schema.Package::{
        , name = "shomei-jwt"
        , type = Schema.PackageType.Library
        , language = Schema.Language.Haskell
        , path = Some "packages/shomei-jwt"
        , description = Some
            "JWT access-token signing/verification and JWKS publishing"
        , dependencies = [ Schema.Dependency.ByName "shomei-core" ]
        }
      , Schema.Package::{
        , name = "shomei-migrations"
        , type = Schema.PackageType.Library
        , language = Schema.Language.Haskell
        , path = Some "packages/shomei-migrations"
        , description = Some
            "codd-managed PostgreSQL schema migrations (embedded SQL) plus a public test-support sublibrary (ephemeral-pg)"
        , dependencies = [ Schema.Dependency.ByName "shomei-core" ]
        }
      , Schema.Package::{
        , name = "shomei-postgres"
        , type = Schema.PackageType.Library
        , language = Schema.Language.Haskell
        , path = Some "packages/shomei-postgres"
        , description = Some
            "PostgreSQL implementations of the core store ports plus the audit-event publisher"
        , dependencies =
          [ Schema.Dependency.ByName "shomei-core"
          , Schema.Dependency.ByName "shomei-migrations"
          ]
        }
      , Schema.Package::{
        , name = "shomei-servant"
        , type = Schema.PackageType.Library
        , language = Schema.Language.Haskell
        , path = Some "packages/shomei-servant"
        , description = Some
            "Servant combinators and handlers: Authenticated, RequireRole/RequireScope, ShomeiAPI"
        , dependencies =
          [ Schema.Dependency.ByName "shomei-core"
          , Schema.Dependency.ByName "shomei-jwt"
          ]
        }
      , Schema.Package::{
        , name = "shomei-server"
        , type = Schema.PackageType.Application
        , language = Schema.Language.Haskell
        , path = Some "packages/shomei-server"
        , description = Some
            "Standalone authentication service — thin application layer over the libraries"
        , runtime = Schema.Runtime::{ deployable = True, exposesApi = True }
        , dependencies =
          [ Schema.Dependency.ByName "shomei-core"
          , Schema.Dependency.ByName "shomei-jwt"
          , Schema.Dependency.ByName "shomei-postgres"
          , Schema.Dependency.ByName "shomei-migrations"
          , Schema.Dependency.ByName "shomei-servant"
          ]
        }
      , Schema.Package::{
        , name = "shomei-client"
        , type = Schema.PackageType.Client
        , language = Schema.Language.Haskell
        , path = Some "packages/shomei-client"
        , description = Some
            "Haskell client for the standalone Shōmei auth service"
        , dependencies =
          [ Schema.Dependency.ByName "shomei-core"
          , Schema.Dependency.ByName "shomei-servant"
          ]
        }
      , Schema.Package::{
        , name = "embedded-servant-app"
        , type = Schema.PackageType.Application
        , language = Schema.Language.Haskell
        , path = Some "examples/embedded-servant-app"
        , description = Some
            "Demo: Shōmei auth routes embedded inside a host Servant app, guarding /projects"
        , runtime = Schema.Runtime::{ deployable = True, exposesApi = True }
        , dependencies =
          [ Schema.Dependency.ByName "shomei-servant"
          , Schema.Dependency.ByName "shomei-server"
          ]
        }
      , Schema.Package::{
        , name = "microservice-auth-stack"
        , type = Schema.PackageType.Application
        , language = Schema.Language.Haskell
        , path = Some "examples/microservice-auth-stack"
        , description = Some
            "Demo: downstream service verifying Shōmei JWTs locally via a fetched, TTL-cached JWKS"
        , runtime = Schema.Runtime::{ deployable = True, exposesApi = True }
        , dependencies =
          [ Schema.Dependency.ByName "shomei-core"
          , Schema.Dependency.ByName "shomei-jwt"
          ]
        }
      ]
    , dependencies =
      [ "haskell-servant/servant"
      , "hasql/hasql"
      , "mzabani/codd"
      , "haskell-hvr/uuid"
      , "haskell/time"
      , "kazu-yamamoto/crypton"
      , "system-f/validation"
      , "MMZK1526/mmzk-typeid"
      , "frasertweedale/hs-jose"
      , "jappeace/ram"
      ]
    }
