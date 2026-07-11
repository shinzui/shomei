# microservice-auth-stack — offline JWT verification, and adding en authorization

The **microservice deployment model**: a standalone `shomei-server` mints JWTs, and a
downstream business service verifies them **offline** against Shōmei's published JWKS — it
never calls the auth service per request. This directory ships that two-service stack; the
second half of this README is a recipe for adding **fine-grained authorization** with **en**
(<https://github.com/shinzui/en>) to the downstream service.

## Running the base stack

From the repository dev shell (`nix develop`), with the dev database created
(`just create-database`):

```bash
process-compose -f examples/microservice-auth-stack/process-compose.yaml up
```

This starts `shomei-server` on `:8080`, waits until it is healthy, then starts the
downstream `example-project-service` on `:8090` pointed at the auth service's JWKS document.
Then, from another shell:

```bash
# 1. signup + login against the auth service
curl -s -X POST localhost:8080/v1/auth/signup -H 'content-type: application/json' \
  -d '{"email":"ms@example.com","password":"correct horse battery staple","displayName":"MS"}'
TOKEN=$(curl -s -X POST localhost:8080/v1/auth/login -H 'content-type: application/json' \
  -d '{"email":"ms@example.com","password":"correct horse battery staple"}' \
  | python3 -c 'import sys,json;print(json.load(sys.stdin)["token"]["accessToken"])')

# 2. the downstream verifies the token locally against the JWKS — no call back to :8080
curl -i localhost:8090/projects -H "Authorization: Bearer $TOKEN"      # 200 (verified locally)
curl -i localhost:8090/projects -H "Authorization: Bearer ${TOKEN%?}X" # 401 (tampered)
```

The downstream service (`src/Downstream/Service.hs`) is the recommended template for a
resource server: a lock-free, refresh-ahead, stale-on-error, fail-closed JWKS cache, and a
local `AuthProtect` handler that verifies each Bearer token with `shomei-jwt`'s `verifyToken`.
It already reads the verified `AuthClaims` — `sub` (the user the request acts for) and `act`
(the acting party on a delegated token). Today it does nothing authorization-specific with
them. **That is the perfect "before" state for the recipe below.**

## Adding en for fine-grained authorization

Shōmei establishes *who is calling*. It does **not** answer resource-scoped questions like
"is this user an **editor** of **this** project?" — that is authorization, and the paved-road
answer is **en**, a Zanzibar-style ReBAC toolkit. The two-tier story and the conventions used
below are documented in [`docs/user/authorization.md`](../../docs/user/authorization.md);
this section is the microservice-shaped recipe.

The downstream already holds a verified `AuthClaims` in every handler. The recipe adds one
step: derive the en subject from `sub`, ask a standalone `en-server` for the decision via
`en-client`, and fail closed. **These are reader-applied snippets** — this package does not
depend on `en-client` (adding an `en-build-depends` here would drag en into the root
`cabal build all`, which the embedded example's `cabal.project` deliberately avoids; see its
Decision Log). Apply the diff to your own copy of the service.

### 1. Topology

```text
  client ──► shomei-server  :8080   (authentication: mints JWTs, publishes JWKS)
        └──► downstream      :8090   (business: verifies JWTs offline, checks en)
                    └──────► en-server :8081  (authorization: relation tuples + checks)
                                          │
                                          └── EN_DATABASE_URL → en's OWN database
```

`en-server` runs against **its own database** (`EN_DATABASE_URL`), with its schema file
carrying the `project` viewer/editor model and en's codd migrations
(`en-migrations/db/migrations/`) applied first. One database per system — see the topology
section of `docs/user/authorization.md`.

Add to *your* downstream service's `build-depends`: `en-client`, `servant-client`.

### 2. Derive the en subject from the verified claims

The identity-mapping convention is **TypeID text, never the bare UUID** — the exact string
Shōmei signs into `sub`. The downstream already holds the claims, so no lookup is needed:

```haskell
import En.Tuple (ObjectRef (..), Subject (..))
import En.Schema (ObjectType (..))
import Shomei.Domain.Claims (AuthClaims (..))
import Shomei.Id (idText)

-- | THE convention: user:<TypeID text>, the string in the JWT `sub` claim. NEVER the bare
-- UUID (Shōmei's audit output renders bare UUIDs — en compares object ids by string
-- equality, so a mismatched form silently denies).
subjectFromClaims :: AuthClaims -> Subject
subjectFromClaims claims =
  SubjectId (ObjectRef {objectType = ObjectType "user", objectId = idText claims.subject})
```

`idText claims.subject` and the raw `sub` string are identical by construction — `shomei-jwt`
signs `idText`.

### 3. Call en, and fail closed

Build a `ClientEnv` against `EN_SERVER_URL` once at startup, then replace the ignored-claims
body with an `en-client` `check`. The wire types come from `En.Client` (which re-exports
`En.Servant.API`):

```haskell
import En.Client (EnClient (..), enClient)
import En.Check.Api (CheckRequestWire (..), CheckResponseWire (..))
import En.Servant.Wire
  ( CaveatContextWire (..), CheckDecisionWire (..), ConsistencyWire (..),
    ObjectRefWire (..), SubjectWire (..) )
import En.Servant.Response (EnResult (..))
import Servant.Client (ClientEnv, runClientM)
import qualified Data.Map.Strict as Map

-- Map a Shōmei Subject to the wire shape en-client speaks. ObjectType and RelationName are
-- newtypes over Text, so unwrap by constructor.
subjectWire :: Subject -> SubjectWire
subjectWire = \case
  SubjectId (ObjectRef (ObjectType oty) oid)                    -> SubjectIdWire (ObjectRefWire oty oid)
  SubjectSet (ObjectRef (ObjectType oty) oid) (RelationName rn) -> SubjectSetWire (ObjectRefWire oty oid) rn
  SubjectWildcard (ObjectType oty)                              -> SubjectWildcardWire oty

-- Ask en: may this subject `edit` this project? Fail closed on deny, on a conditional
-- decision (unresolved caveat), AND on any transport error (an unreachable en-server is a
-- 503, never a pass).
authorize :: ClientEnv -> AuthClaims -> Text -> Handler ()
authorize enEnv claims projectId = do
  let request =
        CheckRequestWire
          { consistency = MinimizeLatencyWire,
            context = CaveatContextWire Map.empty,
            subject = subjectWire (subjectFromClaims claims),
            permission = "edit",
            object = ObjectRefWire "project" projectId
          }
  result <- liftIO (runClientM (enClient.check request) enEnv)
  case result of
    Right (EnOk resp) | AllowedWire <- resp.decision -> pure ()          -- proceed
    Right (EnOk _)                                    -> throwError err403 -- denied / conditional
    Right _                                           -> throwError err503 -- en client/precondition/unavailable
    Left _                                            -> throwError err503 -- en-server unreachable
```

`MinimizeLatency` is the default; after a host performs a **grant-changing en write**, carry
the returned `checkedAt` token into an `AtLeastAsFreshWire` check for read-your-writes. See
the consistency section of `docs/user/authorization.md`.

### 4. Security posture — en-server has no caller authentication yet

> **⚠️ `en-server` authenticates nobody.** As of 2026-07-10, en's
> `docs/plans/33-add-caller-authentication-and-rate-limiting-to-en-server.md` (in the en
> repository) is **unimplemented**. Anyone who can reach the port can rewrite the entire
> authorization graph — write tuples, delete tuples, grant themselves any permission.
>
> Until that plan lands (it names bearer API keys first, with **Shōmei-JWT verification** as
> the intended credential checker behind the same seam), `en-server` must sit on a **private
> network segment reachable only by trusted services** — same host, a private Docker/K8s
> network, or a service mesh with mTLS — and must **never** be exposed alongside `:8080`/
> `:8090`. When en plan 33 ships, this recipe gets a follow-up: the downstream forwards its
> Shōmei-verified identity (or a service token) as the `en-server` credential.

### When to prefer decision tokens over per-request checks

For fan-out topologies, a gateway can check **once** and mint an **en-biscuit decision
token** (which embeds the consistency token) that downstream services verify **offline** —
the same offline-verification posture the JWT itself enjoys, now for the authorization
decision. See en's `docs/user/biscuit-decision-tokens.md`. The full two-tier guide, identity
conventions, consistency rules, and database topology live in
[`docs/user/authorization.md`](../../docs/user/authorization.md).
