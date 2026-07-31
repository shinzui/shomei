let Schema =
      https://raw.githubusercontent.com/shinzui/mori-schema/b85081a0e935a976202fd7a1227f8b93e2cbeb23/package.dhall
        sha256:1501e5c3e55e78d2a58774e2f8aefda20e32b948fa7caf639473fce90929464b

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
        , path = Some "shomei-core"
        , description = Some
            "Transport-agnostic domain: types, commands, events, errors, and effect interfaces (no Servant/WAI/PostgreSQL/JWT/HTTP deps)"
        }
      , Schema.Package::{
        , name = "shomei-jwt"
        , type = Schema.PackageType.Library
        , language = Schema.Language.Haskell
        , path = Some "shomei-jwt"
        , description = Some
            "JWT access-token signing/verification and JWKS publishing"
        , dependencies = [ Schema.Dependency.ByName "shomei-core" ]
        }
      , Schema.Package::{
        , name = "shomei-webauthn"
        , type = Schema.PackageType.Library
        , language = Schema.Language.Haskell
        , path = Some "shomei-webauthn"
        , description = Some
            "WebAuthn (passkey) ceremony interpreter over tweag/webauthn"
        , dependencies = [ Schema.Dependency.ByName "shomei-core" ]
        }
      , Schema.Package::{
        , name = "shomei-migrations"
        , type = Schema.PackageType.Library
        , language = Schema.Language.Haskell
        , path = Some "shomei-migrations"
        , description = Some
            "codd-managed PostgreSQL schema migrations (embedded SQL) plus a public test-support sublibrary (ephemeral-pg)"
        , dependencies = [ Schema.Dependency.ByName "shomei-core" ]
        }
      , Schema.Package::{
        , name = "shomei-postgres"
        , type = Schema.PackageType.Library
        , language = Schema.Language.Haskell
        , path = Some "shomei-postgres"
        , description = Some
            "PostgreSQL implementations of the core store effects plus the audit-event publisher"
        , dependencies =
          [ Schema.Dependency.ByName "shomei-core"
          , Schema.Dependency.ByName "shomei-migrations"
          ]
        }
      , Schema.Package::{
        , name = "shomei-servant"
        , type = Schema.PackageType.Library
        , language = Schema.Language.Haskell
        , path = Some "shomei-servant"
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
        , path = Some "shomei-server"
        , description = Some
            "Standalone authentication service — thin application layer over the libraries"
        , runtime = Schema.Runtime::{ deployable = True, exposesApi = True }
        , dependencies =
          [ Schema.Dependency.ByName "shomei-core"
          , Schema.Dependency.ByName "shomei-jwt"
          , Schema.Dependency.ByName "shomei-webauthn"
          , Schema.Dependency.ByName "shomei-postgres"
          , Schema.Dependency.ByName "shomei-migrations"
          , Schema.Dependency.ByName "shomei-servant"
          ]
        }
      , Schema.Package::{
        , name = "shomei-client"
        , type = Schema.PackageType.Client
        , language = Schema.Language.Haskell
        , path = Some "shomei-client"
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
      , "tweag/webauthn"
      ]
    , okfBundles =
      [ Schema.OkfBundle::{
        , name = "improvement-requests"
        , path = "docs/improvement-requests"
        , profile = Some "docs/improvement-requests/profile.dhall"
        , okfVersion = "0.1"
        , description = Some "Shomei-owned improvement requests"
        }
      ]
    }
