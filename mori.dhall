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
    , repos =
      [ Schema.Repo::{ name = "shomei", github = Some "shinzui/shomei" } ]
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
            "pg-migrate PostgreSQL schema migrations, embedded from an ordered manifest and exposed as a composable MigrationComponent, plus a public test-support sublibrary (ephemeral-pg)"
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
      [ "haskell-servant/servant:servant"
      , "haskell-servant/servant:servant-server"
      , "haskell-servant/servant:servant-client"
      , "haskell-servant/servant:servant-client-core"
      , "hasql/hasql:hasql"
      , "hasql/hasql:hasql-pool"
      , "hasql/hasql:hasql-transaction"
      , "haskell-hvr/uuid:uuid"
      , "haskell/time:time"
      , "kazu-yamamoto/crypton:crypton"
      , "system-f/validation:validation"
      , "MMZK1526/mmzk-typeid:mmzk-typeid"
      , "frasertweedale/hs-jose:jose"
      , "jappeace/ram:ram"
      , "tweag/webauthn:webauthn"
      , "effectful/effectful:effectful"
      , "effectful/effectful:effectful-core"
      , "shinzui/pg-migrate:pg-migrate"
      , "shinzui/pg-migrate:pg-migrate-embed"
      , "shinzui/pg-migrate:pg-migrate-cli"
      , "shinzui/ephemeral-pg:ephemeral-pg"
      , "shinzui/servant-health:servant-health"
      , "shinzui/openapi-hs:openapi-hs"
      , "shinzui/servant-openapi-hs:servant-openapi-hs"
      ]
    , dependencyRefs =
      [ Schema.MoriRef::{
        , namespace = "haskell-servant"
        , name = "servant"
        , kind = Some Schema.MoriArtifactKind.Package
        , key = Some "servant"
        }
      , Schema.MoriRef::{
        , namespace = "haskell-servant"
        , name = "servant"
        , kind = Some Schema.MoriArtifactKind.Package
        , key = Some "servant-server"
        }
      , Schema.MoriRef::{
        , namespace = "haskell-servant"
        , name = "servant"
        , kind = Some Schema.MoriArtifactKind.Package
        , key = Some "servant-client"
        }
      , Schema.MoriRef::{
        , namespace = "haskell-servant"
        , name = "servant"
        , kind = Some Schema.MoriArtifactKind.Package
        , key = Some "servant-client-core"
        }
      , Schema.MoriRef::{
        , namespace = "hasql"
        , name = "hasql"
        , kind = Some Schema.MoriArtifactKind.Package
        , key = Some "hasql"
        }
      , Schema.MoriRef::{
        , namespace = "hasql"
        , name = "hasql"
        , kind = Some Schema.MoriArtifactKind.Package
        , key = Some "hasql-pool"
        }
      , Schema.MoriRef::{
        , namespace = "hasql"
        , name = "hasql"
        , kind = Some Schema.MoriArtifactKind.Package
        , key = Some "hasql-transaction"
        }
      , Schema.MoriRef::{
        , namespace = "haskell-hvr"
        , name = "uuid"
        , kind = Some Schema.MoriArtifactKind.Package
        , key = Some "uuid"
        }
      , Schema.MoriRef::{
        , namespace = "haskell"
        , name = "time"
        , kind = Some Schema.MoriArtifactKind.Package
        , key = Some "time"
        }
      , Schema.MoriRef::{
        , namespace = "kazu-yamamoto"
        , name = "crypton"
        , kind = Some Schema.MoriArtifactKind.Package
        , key = Some "crypton"
        }
      , Schema.MoriRef::{
        , namespace = "system-f"
        , name = "validation"
        , kind = Some Schema.MoriArtifactKind.Package
        , key = Some "validation"
        }
      , Schema.MoriRef::{
        , namespace = "MMZK1526"
        , name = "mmzk-typeid"
        , kind = Some Schema.MoriArtifactKind.Package
        , key = Some "mmzk-typeid"
        }
      , Schema.MoriRef::{
        , namespace = "frasertweedale"
        , name = "hs-jose"
        , kind = Some Schema.MoriArtifactKind.Package
        , key = Some "jose"
        }
      , Schema.MoriRef::{
        , namespace = "jappeace"
        , name = "ram"
        , kind = Some Schema.MoriArtifactKind.Package
        , key = Some "ram"
        }
      , Schema.MoriRef::{
        , namespace = "tweag"
        , name = "webauthn"
        , kind = Some Schema.MoriArtifactKind.Package
        , key = Some "webauthn"
        }
      , Schema.MoriRef::{
        , namespace = "effectful"
        , name = "effectful"
        , kind = Some Schema.MoriArtifactKind.Package
        , key = Some "effectful"
        }
      , Schema.MoriRef::{
        , namespace = "effectful"
        , name = "effectful"
        , kind = Some Schema.MoriArtifactKind.Package
        , key = Some "effectful-core"
        }
      , Schema.MoriRef::{
        , namespace = "shinzui"
        , name = "pg-migrate"
        , kind = Some Schema.MoriArtifactKind.Package
        , key = Some "pg-migrate"
        }
      , Schema.MoriRef::{
        , namespace = "shinzui"
        , name = "pg-migrate"
        , kind = Some Schema.MoriArtifactKind.Package
        , key = Some "pg-migrate-embed"
        }
      , Schema.MoriRef::{
        , namespace = "shinzui"
        , name = "pg-migrate"
        , kind = Some Schema.MoriArtifactKind.Package
        , key = Some "pg-migrate-cli"
        }
      , Schema.MoriRef::{
        , namespace = "shinzui"
        , name = "ephemeral-pg"
        , kind = Some Schema.MoriArtifactKind.Package
        , key = Some "ephemeral-pg"
        }
      , Schema.MoriRef::{
        , namespace = "shinzui"
        , name = "servant-health"
        , kind = Some Schema.MoriArtifactKind.Package
        , key = Some "servant-health"
        }
      , Schema.MoriRef::{
        , namespace = "shinzui"
        , name = "openapi-hs"
        , kind = Some Schema.MoriArtifactKind.Package
        , key = Some "openapi-hs"
        }
      , Schema.MoriRef::{
        , namespace = "shinzui"
        , name = "servant-openapi-hs"
        , kind = Some Schema.MoriArtifactKind.Package
        , key = Some "servant-openapi-hs"
        }
      ]
    , apis =
      [ Schema.Api::{
        , name = "shomei-auth"
        , type = Schema.ApiType.OpenAPI
        , specPath = "docs/api/openapi.json"
        , owner = "shomei-servant"
        , ownerRef = Some Schema.MoriRef::{
          , namespace = "shinzui"
          , name = "shomei"
          , kind = Some Schema.MoriArtifactKind.Package
          , key = Some "shomei-servant"
          }
        , dependencies =
          [ Schema.ApiDependency::{
            , package = "shomei-client"
            , packageRef = Some Schema.MoriRef::{
              , namespace = "shinzui"
              , name = "shomei"
              , kind = Some Schema.MoriArtifactKind.Package
              , key = Some "shomei-client"
              }
            , role = Schema.ApiDependencyRole.Client
            }
          , Schema.ApiDependency::{
            , package = "microservice-auth-stack"
            , packageRef = Some Schema.MoriRef::{
              , namespace = "shinzui"
              , name = "shomei"
              , kind = Some Schema.MoriArtifactKind.Package
              , key = Some "microservice-auth-stack"
              }
            , role = Schema.ApiDependencyRole.Consumer
            }
          ]
        , updatePolicy = Some Schema.ApiUpdatePolicy::{
          , strategy = Schema.ApiUpdateStrategy.ClientFirst
          , consumerBatching = Schema.ConsumerBatching.Sequential
          }
        }
      ]
    , okfBundles =
      [ Schema.OkfBundle::{
        , name = "improvement-requests"
        , path = "docs/improvement-requests"
        , profile = Some "docs/improvement-requests/profile.dhall"
        , okfVersion = "0.1"
        , description = Some "Shomei-owned improvement requests"
        }
      , Schema.OkfBundle::{
        , name = "capabilities"
        , path = "docs/capabilities"
        , profile = Some "docs/capabilities/profile.dhall"
        , okfVersion = "0.2"
        , description = Some
            "What Shomei provides today, one concept per capability, with evidence"
        }
      , Schema.OkfBundle::{
        , name = "reviews"
        , path = "docs/reviews"
        , profile = Some "docs/reviews/profile.dhall"
        , okfVersion = "0.2"
        , description = Some
            "Commit-pinned records of reviews of Shomei artifacts"
        }
      , Schema.OkfBundle::{
        , name = "adrs"
        , path = "docs/adr"
        , profile = Some "docs/adr/profile.dhall"
        , okfVersion = "0.2"
        , description = Some "Shomei architecture decision records"
        }
      ]
    }
