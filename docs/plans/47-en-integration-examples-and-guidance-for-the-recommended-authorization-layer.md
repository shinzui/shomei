---
id: 47
slug: en-integration-examples-and-guidance-for-the-recommended-authorization-layer
title: "En Integration: Examples and Guidance for the Recommended Authorization Layer"
kind: exec-plan
created_at: 2026-07-07T19:30:02Z
intention: "intention_01kx254gy7e429sh8erv1hee3n"
master_plan: "docs/masterplans/7-interop-wave-standards-based-auth-surface.md"
---

# En Integration: Examples and Guidance for the Recommended Authorization Layer

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.

This is **EP-10** of MasterPlan 7
(`docs/masterplans/7-interop-wave-standards-based-auth-surface.md`). It has **no hard
dependencies**: everything here works against today's Shōmei working tree (the example
authenticates with plain Shōmei JWTs; it does not need plan 38's roles). Soft
dependencies: plan 38
(`docs/plans/38-persistent-roles-and-scopes-with-a-granting-path-and-claims-enrichment.md`)
and plan 46 (`docs/plans/46-role-definitions-permissions-and-time-bound-grants.md`)
create the docs sections this plan cross-links (the "two-tier" story reads best when both
tiers exist in the docs); plan 41
(`docs/plans/41-database-backed-service-accounts-with-oauth2-client-credentials-grant.md`)
introduces the `client_id` that one identity-mapping note refers to. Where those plans
have not landed, this plan links to the plan documents instead of the finished docs, and
nothing else changes. **All work in this plan happens in the shomei repository.** Work
that belongs in the en repository is listed under External Companion Work and is
explicitly not a milestone here.


## Purpose / Big Picture

Shōmei is a Haskell **authentication** toolkit: it establishes *who is calling*
(passwords, passkeys, MFA, sessions, JWTs) and, per the two-tier decision recorded in
plan 38's Decision Log, ships only a deliberately coarse built-in authorization tier
(flat roles/scopes, growing permissions and time-bound grants in plan 46). The
recommended answer to *what may they do*, at fine granularity — "is this user an editor
of **this** project?", access derived from relationships, revocation that takes effect
immediately, conditional access — is the author's sibling project **en**: a
Zanzibar-style relationship-based access control (ReBAC) toolkit living at
`/Users/shinzui/Keikaku/bokuno/en` (GitHub: `https://github.com/shinzui/en`), with its
own docs site repo at `/Users/shinzui/Keikaku/bokuno/en-docs`.

Today that recommendation exists only as an idea. There is no runnable code showing the
two projects composed, no stated convention for how a Shōmei identity becomes an en
subject (get it wrong and en silently denies everything), and no written guidance on
consistency, database topology, service accounts, or impersonation across the boundary.
This plan makes "Shōmei for authentication + en for authorization" the **paved road, in
executable form**:

1. A new runnable example, `examples/embedded-with-en`: one Servant process that mounts
   the full Shōmei auth API (reusing the existing `examples/embedded-servant-app` wiring)
   plus a small business route `/projects/:id` (GET/PUT) whose handlers map the
   authenticated Shōmei user to an en subject and call en's fail-closed guard. Its README
   walks a copy-pasteable transcript: signup → login → PUT is 403 → grant an `editor`
   relationship tuple → PUT is 200.
2. A written microservice recipe extending `examples/microservice-auth-stack`: the
   downstream service already verifies Shōmei JWTs offline against a JWKS; the recipe
   shows the next step — derive the en subject from the verified `sub` claim and ask a
   standalone `en-server` for the decision via `en-client` — including a prominent
   warning that en-server currently has **no caller authentication** (en's own plan 33 is
   unimplemented) and what deployment posture that demands today.
3. A new user-docs page, `docs/user/authorization.md`, linked from the README and
   `docs/user/index.md`: the two-tier story, the identity-mapping conventions (the single
   most bug-prone seam), consistency-token guidance, and database-topology guidance.

After this plan, a developer who has never seen en can go from `git clone` to a working
"Shōmei login gates an en-checked route" demo in minutes, and every cross-project
question this integration raises has one documented answer.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

Milestone 1 — Dependency wiring spike (en as a source dependency of one example):

- [ ] `examples/embedded-with-en/` package skeleton (cabal file, `src/`, `app/`, `README.md` stub) — **not** added to the root `cabal.project` `packages:` list.
- [ ] `examples/embedded-with-en/cabal.project` importing the root project file and adding the en `source-repository-package` (pinned tag, `subdir: en-core en-servant`).
- [ ] Spike verified: `cabal build` inside the example directory produces a plan containing shomei-server, en-core, and en-servant; documented fallback (duplicate the root pins) if `import:` relative-path semantics misbehave.
- [ ] Toolchain notes confirmed in the README: both repos pin `with-compiler: ghc-9.12.4`; ephemeral-pg posture recorded (en constrains `ephemeral-pg ==0.2.1.0` for its *tests* only — not in this build plan; shomei's fork pin governs if it ever enters).
- [ ] Root `cabal build all && cabal test all` still green and en-free.

Milestone 2 — The embedded example app and its transcript:

- [ ] `EmbeddedEn.Authz`: the pinned subject mapping (`subjectForUser`), the demo schema (project viewer/editor → view/edit), the IORef-backed en `TupleStore` interpreter (write-supporting), the local `ConsistencyStore` interpreter, and `mkEnEnv`.
- [ ] `EmbeddedEn.App`: mounts `NamedRoutes ShomeiAPI` via `seamEnv`/`authContext`/`shomeiServer` (the `examples/embedded-servant-app/src/Embedded/App.hs` pattern), adds `GET/PUT /projects/:id` guarded by `En.Servant.Authorize.requirePermission`, and the demo tuple-granting route `POST /demo/grants`.
- [ ] `app/Main.hs` boots exactly like the embedded example's executable (config + pool + keys), plus the en env.
- [ ] README transcript recorded from a real run: signup → login → GET 403 → PUT 403 → grant `editor` → PUT 200 → GET 200 (editor implies view).
- [ ] Consistency shown honestly in the README: the grant response returns en's consistency token; the follow-up check narrative explains `MinimizeLatency` vs `AtLeastAsFresh`.

Milestone 3 — The microservice recipe:

- [ ] `examples/microservice-auth-stack/README.md` created (the stack has none today; its runbook lives in comments atop `process-compose.yaml` — lift those into the README first).
- [ ] "Adding en to the downstream service" recipe section: JWKS-verified `AuthClaims` → subject via `idText claims.subject` → `en-client` `check` against `en-server`; full code snippets, no compiled dependency (Decision Log).
- [ ] Prominent security note: en-server has no caller authentication today (en plan 33, unimplemented; names Shōmei-JWT verification as the intended fix); stated posture: private network / service mesh mTLS; never expose en-server publicly.
- [ ] The recipe's environment/topology sketch (shomei-server :8080, downstream :8090, en-server :8081 with `EN_DATABASE_URL` pointing at en's **own** database).

Milestone 4 — The authorization docs page:

- [ ] `docs/user/authorization.md` written: two-tier story; identity-mapping conventions (users, service accounts, impersonation); consistency guidance; database topology; the bootstrap-circularity note (Shōmei's own role grants stay in Shōmei).
- [ ] Linked from `README.md`'s Documentation list and `docs/user/index.md`'s Feature Guides; cross-links added from `docs/user/security.md`'s roles section (if plan 38's rewrite has landed) and `docs/user/client-and-examples.md` (both examples).
- [ ] External Companion Work section of this plan reviewed against the en repo one final time (paths still accurate) and mirrored as a short "current en-side gaps" admonition in the docs page.
- [ ] CHANGELOG entry; MasterPlan 7 registry row updated.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- Pre-implementation (2026-07-07, while planning): en's only reusable in-memory
  `TupleStore` interpreter, `En.Conformance.Kikan.runTupleStoreInMemory`
  (`en-core/src/En/Conformance/Kikan.hs` line 145), serves reads from a **fixed seed
  list and ignores writes** (`WriteTuples _ -> pure (ConsistencyToken
  "in-memory-write")`). The demo's "grant a tuple at runtime, watch 403 become 200" story
  therefore needs the example to ship its own small IORef-backed interpreter (Milestone
  2) rather than reusing Kikan's.


## Decision Log

Record every decision made while working on the plan.

- Decision: en is consumed as a **git source dependency of the example only**. The new
  example gets its own `examples/embedded-with-en/cabal.project` (importing the root
  project file for the shomei package list and shomei's existing source pins, then adding
  a `source-repository-package` for `https://github.com/shinzui/en.git` pinned to a
  commit, `subdir: en-core en-servant`), and the example is **not** added to the root
  `cabal.project`'s `packages:` list. For local co-development against uncommitted en
  changes, a developer overrides with relative `packages:` entries in an untracked
  `cabal.project.local` (documented in the example README).
  Rationale: the root `cabal build all` must not acquire en's whole dependency closure —
  shomei must stay buildable by people who will never use en, and CI must not fetch a
  second repository for the core packages. A pinned tag keeps the example reproducible
  for anyone cloning shomei alone (the en repo is public), unlike a
  `packages: ../../../en/...` relative path that only works in the author's directory
  layout. Both repos pin the same toolchain (`with-compiler: ghc-9.12.4`, first line of
  each `cabal.project`; matching nixpkgs pins), so the shomei dev shell builds en
  sources unmodified. The ephemeral-pg wrinkle is real but inert: shomei pins a thin
  fork (`https://github.com/shinzui/ephemeral-pg.git`, root `cabal.project` lines
  ~22-25) while en constrains `ephemeral-pg ==0.2.1.0` (en `cabal.project` line 18) —
  but en's constraint lives in en's *project file*, which is never consulted when en
  packages are consumed as source dependencies, and ephemeral-pg is test-only for en;
  building en-core/en-servant *libraries* never puts it in the plan. If a future change
  drags it in, one `constraints:` line in the example's project file reconciles it —
  record that here if it happens.
  Date: 2026-07-07

- Decision: The identity-mapping convention is **TypeID text, not bare UUID**: a Shōmei
  user becomes the en subject
  `SubjectId (ObjectRef (ObjectType "user") (idText authUser.authUserId))` — e.g.
  `user:user_01ABC…`, exactly the string Shōmei signs into the JWT `sub` claim
  (`shomei-jwt/src/Shomei/Jwt/Sign.hs` line ~91-92 uses `idText ac.subject`;
  `Shomei.Id.idText`, `shomei-core/src/Shomei/Id.hs` line ~103, renders the
  `KindID "user"` as `user_…` text). Every artifact of this plan (example, recipe, docs)
  uses this form and states it as *the* convention.
  Rationale: en's `ObjectRef.objectId` is untyped `Text`
  (`en-core/src/En/Tuple.hs` lines ~23-36) and en compares subjects by **string
  equality** — a tuple written for `user:user_01ABC…` will never match a check for
  `user:0198a3bc-…` even though both name the same user. Mixing forms does not error; it
  silently denies. The trap is sharpened by Shōmei itself: the denormalized audit
  columns and `shomei-admin audit` output render **bare UUIDs**, so an operator
  copy-pasting from the audit trail into a tuple write gets the wrong form. Pinning the
  TypeID text (the `sub` claim, `AuthUser.authUserId` via `idText`) means the value every
  service actually holds after verification is the value en stores, and it keeps the
  subject namespace self-describing (`user_…`/`svcacct_…` prefixes survive in en tuples).
  The docs page carries this warning verbatim.
  Date: 2026-07-07

- Decision: en guards Shōmei-authenticated routes at the **handler level**, via
  `En.Servant.Authorize.requirePermission` after Shōmei's `Authenticated` combinator has
  produced the `AuthUser` — not via a new type-level combinator.
  Rationale: an en check needs the `ObjectRef` of the *resource*, which comes from path
  captures (`/projects/:id`), and a Servant combinator cannot observe values captured by
  other combinators (the same constraint that shaped plan 38's `RequireRole` design —
  there the role name is a type-level constant, so a combinator works; here the object is
  per-request data, so it cannot). en-servant agrees: it deliberately exports only the
  term-level guard (`en-servant/src/En/Servant/Authorize.hs` lines 14-37) and has no
  `AuthProtect`/`HasServer`/`Context` machinery at all — verified, which also means no
  name or instance collision with shomei-servant's combinators is possible.
  Date: 2026-07-07

- Decision: The embedded example runs en **in-memory** (an IORef-backed `TupleStore`
  interpreter written in the example, modeled on `En.Conformance.Kikan`'s but supporting
  writes, plus a trivial local `ConsistencyStore`), not against en's PostgreSQL backend.
  Rationale: the example's job is to teach the seam (subject mapping, `requirePermission`
  call shape, fail-closed 403), not en operations. Wiring `en-postgres` would force a
  second database and expose an en-side gap irrelevant to the lesson:
  `En.Postgres.Database` offers only `runDatabaseConnection` over a single
  `Hasql.Connection` (`en-postgres/src/En/Postgres/Database.hs` lines ~29-33) — no pool —
  which is fine for en-server's single process but wrong to copy into a
  concurrent host handler path. Pooled embedding is en-repo work (External Companion
  Work); the example README says exactly that so nobody productionizes the IORef.
  Date: 2026-07-07

- Decision: The microservice recipe is **documentation with complete code snippets**
  (a new `examples/microservice-auth-stack/README.md` section plus the docs page), not a
  compiled change to the `microservice-auth-stack` package.
  Rationale: that package *is* in the root `cabal.project` `packages:` list, so adding an
  `en-client` build-depends would drag en into every `cabal build all` — exactly what the
  first decision exists to prevent. The downstream service today verifies the JWT and
  ignores the claims (`examples/microservice-auth-stack/src/Downstream/Service.hs`,
  `projectsHandler _claims = …`), which is the perfect "before" state: the recipe shows
  the handler diff a reader applies themselves. If a compiled variant is ever wanted, it
  should be a sibling example following the embedded-with-en wiring pattern.
  Date: 2026-07-07

- Decision: Service-account guidance: service principals map to **`user:` subjects by
  default** — today's service tokens set `sub` to the backing service *user*'s `UserId`
  (`shomei-core/src/Shomei/Workflow/ServiceToken.hs` line ~88 builds claims for
  `serviceUser`'s id), and plan 41 keeps a backing user even after introducing
  `svcacct_…` client ids. Hosts whose en schema distinguishes machines *may* adopt
  `ObjectType "service"` keyed by plan 41's `client_id` once it exists, as a
  deliberate, documented schema choice. The recommendation stays: keep `user:` unless
  your en schema actually branches on machine-ness.
  Rationale: with `user:` subjects, one tuple vocabulary covers humans and machines, and
  the `sub`-claim-is-the-subject rule holds uniformly (the verifying service needs no
  lookup to build the subject). Splitting the namespace prematurely doubles every
  group/role tuple for no decision the schema makes. The `svcacct_…` TypeID prefix keeps
  machine subjects visually distinct inside the `user:` namespace anyway.
  Date: 2026-07-07

- Decision: Impersonation guidance: en is checked against the **subject** (the
  impersonated user, the JWT's `sub`); the operator in the `act` claim is **audited** by
  the host alongside the en decision; an optional **second** en check against the actor
  (e.g. an `operator` permission on the same object) is the pattern for
  "impersonation must not exceed the operator's own access"; caveat contexts are where
  actor facts go if the en schema wants conditional rules about them. en itself has no
  actor notion — verified: `Subject` is `SubjectId | SubjectSet | SubjectWildcard`
  (`en-core/src/En/Tuple.hs`), nothing carries a delegation chain.
  Rationale: impersonation exists so the operator sees exactly what the user can see —
  checking the subject preserves that; checking only the actor would leak the operator's
  broader access into the user's view. The audit obligation transfers to the host because
  the only place `act` exists is the verified Shōmei claims.
  Date: 2026-07-07

- Decision: Consistency guidance: default to `MinimizeLatency`; after a host performs a
  grant-changing en write, use the returned token with `AtLeastAsFresh` (or
  `FullyConsistent` where a token is unavailable) for the next check; and **Shōmei JWTs
  never carry en consistency tokens or en decisions**. Where a *decision* must travel
  between services, en's own decision-token mechanism (en-biscuit grants, which embed the
  consistency token) is the transport.
  Rationale: the `Consistency` vocabulary is en's own
  (`en-core/src/En/Revision.hs` line 44: `MinimizeLatency | AtLeastAsFresh … |
  AtExactSnapshot … | FullyConsistent`), and read-your-writes after grants is the
  documented en pattern. A Shōmei JWT lives for its TTL and is minted *before* the writes
  a request will cause — a consistency token frozen into it is stale by construction,
  and an authorization decision frozen into it recreates the exact live-revocation
  failure the two-tier split exists to avoid (plan 38's `ClaimsEnricher` haddock carries
  the same warning from the other side).
  Date: 2026-07-07

- Decision: Database topology guidance: **one database per system** — Shōmei owns its
  database (its codd migrations create everything inside the `shomei` schema), en owns
  its own (its codd migrations create `relation_tuple`/`en_transaction` in the *public*
  schema — `en-migrations/db/migrations/`). The docs present this as the default and the
  only documented arrangement.
  Rationale: although the two schemas do not collide by name, running **two codd
  migration ledgers against one database is unverified** — codd tracks applied
  migrations in its own bookkeeping, and neither project has tested cohabitation; and
  en's revision machinery is inherently **per-database** (`pg_current_snapshot()` /
  `pg_current_xact_id()` xid8 arithmetic,
  `en-postgres/src/En/Postgres/TupleStore.hs` lines ~267-294), so sharing a database
  buys nothing en can use — there is no cross-system transactional consistency to be
  had. Separate databases also keep backup/retention/scaling decisions independent,
  which matches the trust boundary. en-side schema namespacing is listed as optional
  companion work for operators who *must* consolidate.
  Date: 2026-07-07


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

(To be filled during and after implementation.)


## Context and Orientation

This section assumes no prior knowledge of either repository. Everything below was
verified against both working trees on 2026-07-07.

### Shōmei, as this plan touches it

Shōmei is a multi-package Cabal project at `/Users/shinzui/Keikaku/bokuno/shomei`, built
inside `nix develop` with GHC 9.12.4 (`cabal.project` line 1: `with-compiler:
ghc-9.12.4`). Its root `cabal.project` lists the core packages plus two example packages
(`examples/embedded-servant-app`, `examples/microservice-auth-stack`) and pins several
git dependencies (`source-repository-package` blocks), including a thin fork of
`ephemeral-pg` (lines ~22-25) used by tests.

The two existing examples are the deployment models this plan extends:

- **Embedded** (`examples/embedded-servant-app/src/Embedded/App.hs`): a host Servant app
  whose `AppAPI` is `NamedRoutes ShomeiAPI :<|> Authenticated :> "projects" :> …` — it
  reuses the *real* server assembly (`Shomei.Server.App.Env`, `seamEnv`, `authContext`,
  `shomeiServer` from `Shomei.Servant.Handlers`) so the mounted auth routes and the
  host's own guard share one signing key and verifier; `serveWithContext (Proxy @AppAPI)
  (authContext senv) (shomeiServer senv :<|> projectsHandler :<|> …)`. `Authenticated` is
  Servant generalized auth (`AuthProtect "shomei-jwt"`); the handler receives an
  `AuthUser` (`shomei-servant/src/Shomei/Servant/Auth.hs` line ~46: `authUserId ::
  UserId`, `authSessionId`, `authRoles`, `authScopes`, `authClaims`). The new
  `embedded-with-en` example copies this wiring wholesale and adds en.
- **Microservice** (`examples/microservice-auth-stack/`): `process-compose.yaml` starts
  the standalone `shomei-server` on :8080 and a downstream `example-project-service` on
  :8090 whose only Shōmei coupling is offline JWT verification —
  `src/Downstream/Service.hs` keeps a TTL-cached JWKS (`newJwksCache`, fetched from
  `SHOMEI_JWKS_URL`) and a local `AuthProtect "downstream-jwt"` handler calling
  `Shomei.Jwt.Verify.verifyToken`; on success the handler holds a verified `AuthClaims`
  and today ignores it. The stack has no README; its runbook lives in comments at the top
  of `process-compose.yaml`.

Identity: every Shōmei id is an `mmzk-typeid` `KindID` — a UUIDv7 with a type-level
prefix. `UserId = KindID "user"`. `Shomei.Id.idText` (`shomei-core/src/Shomei/Id.hs`
line ~103) renders it as TypeID text, e.g. `user_01ABCXYZ…`, and that exact text is what
`shomei-jwt` signs into the JWT `sub` claim (`shomei-jwt/src/Shomei/Jwt/Sign.hs`,
`claimSub ?~ sou (idText ac.subject)`, line ~91-92). Service tokens
(`shomei-core/src/Shomei/Workflow/ServiceToken.hs`) also set `sub` to a *user* id — the
backing service user's (line ~88). Beware: Shōmei's audit tables denormalize ids as bare
**UUIDs**, so audit output shows `0198a3bc-…` where the JWT shows `user_01ABC…` — same
identity, different rendering.

User docs live under `docs/user/` with an index (`docs/user/index.md`, "Feature Guides"
list) and are also linked from the repository `README.md`'s "Documentation" section
(lines ~70-80). This plan adds `docs/user/authorization.md` to both lists.

### en, as this plan consumes it

en (`/Users/shinzui/Keikaku/bokuno/en`, same `with-compiler: ghc-9.12.4`, matching
nixpkgs pins, so shomei's dev shell builds it) is a Zanzibar-style ReBAC toolkit.
"Zanzibar-style ReBAC" means: authorization data is a set of **relation tuples** — facts
of the form *subject has relation on object*, e.g. `user:user_01ABC… is editor of
project:roadmap` — and a **schema** declares object types, relations, and how
*permissions* rewrite into relations (e.g. `view = viewer ∪ editor`). A **check** asks
"does subject S have permission P on object O?" and walks the tuple graph. Packages:

- `en-core` — the engine: `En.Tuple` (`en-core/src/En/Tuple.hs` lines ~23-36:
  `ObjectRef { objectType :: ObjectType, objectId :: Text }`; `Subject = SubjectId
  ObjectRef | SubjectSet ObjectRef RelationName | SubjectWildcard ObjectType` — note the
  **untyped `Text` object id**, hence the string-equality trap in the Decision Log),
  `En.Schema.Builder` (typed schema construction: `object`, `relation`, `permission`,
  `subject`, `computed`, `anyOf`, `build`), `En.Reachability.compileSchema`,
  `En.Check.check` (returns `CheckDecision = Allowed | Denied | Conditional …`),
  `En.Revision` (`Consistency`, line 44: `MinimizeLatency` — cached, may be stale;
  `AtLeastAsFresh token` — read-your-writes; `AtExactSnapshot token`; `FullyConsistent`),
  the `TupleStore`/`ConsistencyStore` effects (`En.Effect.*`), and
  `En.Conformance.Kikan.runTupleStoreInMemory :: [Tuple] -> Eff (TupleStore : es) a ->
  Eff es a` (line 145) — a fixed-seed read-only in-memory store (writes are no-ops; see
  Surprises).
- `en-servant` — the HTTP surface *and* the embedding seam: `En.Servant.Seam.Env es`
  (fields `runPorts :: forall a. Eff es a -> IO (Either EnError a)`, `graph ::
  ReachabilityGraph`, `checkOperation`, `lookupWithDeadlineOperation`, `maxBatchSize`)
  and the fail-closed guard this plan is built around
  (`en-servant/src/En/Servant/Authorize.hs` lines 14-37):

  ```haskell
  requirePermission ::
      Env es -> Consistency -> CaveatContext -> Subject -> RelationName -> ObjectRef ->
      Handler ()
  ```

  `Allowed` returns `()`; `Denied` **and** `Conditional` throw 403 (fail-closed —
  unresolved caveats deny). There is no `AuthProtect`, no `HasServer` combinator, no
  Servant `Context` entry anywhere in en-servant — the term-level guard is the entire
  authorization API, so there is nothing to collide with shomei-servant's
  `RequireRole`/`RequireScope`/`RequirePermission` combinators.
- `en-postgres` — hasql persistence. `En.Postgres.Database` exposes only
  `runDatabaseConnection :: Connection -> …` over a **single** connection (lines ~29-33;
  no pool — see External Companion Work). `En.Postgres.TupleStore` implements revisions
  with `pg_current_xact_id()`/`pg_current_snapshot()` xid8 arithmetic (lines ~267-294) —
  per-database machinery, which drives the topology decision.
- `en-server` — the standalone service (`en-server/app/Main.hs`): env-configured
  (`EN_DATABASE_URL`, `EN_PORT` default 8080, schema from a file), routes
  `POST/DELETE /tuples`, `POST /check`, `/batch-check`, `/lookup`, `/expand`
  (`en-servant/src/En/Servant/API.hs` lines ~93-95). **It authenticates nobody**: en's
  `docs/plans/33-add-caller-authentication-and-rate-limiting-to-en-server.md` (in the en
  repo) is unimplemented as of 2026-07-07 and explicitly names Shōmei-JWT verification
  as a future credential-checker behind its API-key seam. Anyone with network reach can
  write tuples. This fact appears, prominently, in every artifact of this plan.
- `en-client` — typed client (`en-client/src/En/Client.hs`): `EnClient { writeTuples,
  deleteTuples, check :: CheckRequestWire -> ClientM CheckResponseWire, batchCheck,
  lookup, expand }`, `enClient`. `CheckRequestWire` carries `consistency`, `context`,
  `subject`, `permission :: Text`, `object` wire shapes
  (`en-servant/src/En/Servant/API.hs` line ~175).
- `en-biscuit` — decision tokens: an `Allowed` check can be minted into an attenuable
  token (embedding the consistency token) that downstream services verify offline. The
  helper `subjectFromUserId :: Text -> Subject` — the exact Shōmei mapping — exists
  today only in en's docs page (`en/docs/user/biscuit-decision-tokens.md`) and its test
  suite (`en-biscuit/test/Main.hs` lines ~592-647, which literally stages a "verified
  Shomei principal" flow); promoting it into `En.Servant.Authorize` is en-repo work
  (External Companion Work), so this plan's example defines its own copy.
- `en-example` — en's own host demo (`en-example/src/En/Example/Host.hs`): the pattern
  this plan's example follows — `exampleSchema` built with `En.Schema.Builder` (line
  ~80), `mkEnv` threading interpreters into `Env` (line ~110), handlers calling
  `requirePermission env MinimizeLatency emptyContext subject (RelationName "view") ref`.
  Its `runConsistencyStoreInMemory` (line ~162: `ResolveConsistency c -> pure
  ResolvedConsistency{consistency = c, revision = testRevision}` etc.) is the model for
  this plan's local consistency interpreter.

en migrations are plain codd SQL files under `en-migrations/db/migrations/` (two files
today: relation tuples + historical-read indexes), applied with the codd CLI against
`EN_DATABASE_URL` (en-server's startup error message points at
`En.Migrations.migrationsDir`); they create tables in the **public** schema, unlike
Shōmei's, which live in the `shomei` schema — no name collisions, but see the topology
decision for why they still should not share a database.

Per the repository's dependency-lookup convention, when an exact library API is needed,
run `mori registry list` / `mori registry show <project> --full` and read sources on
disk; en and en-docs are expected to be registered. Never search `/nix/store`.


## Plan of Work

Four milestones. Each is independently verifiable; commit at each boundary. Milestone 1
is explicitly a spike (the cabal `import:` mechanics are the only real unknown); 2–4 are
straight construction.

### Milestone 1 — Dependency wiring spike: en as a source dependency of one example

Scope: at the end, `examples/embedded-with-en` exists as a compilable (if empty-ish)
package whose build plan includes en-core and en-servant, the root workspace build is
provably unaffected, and the wiring decisions are written down where the next person
will look (the example README).

Create the package skeleton:

```text
examples/embedded-with-en/
  cabal.project
  embedded-with-en.cabal
  README.md
  app/Main.hs
  src/EmbeddedEn/App.hs
  src/EmbeddedEn/Authz.hs
```

`embedded-with-en.cabal` mirrors `examples/embedded-servant-app/embedded-servant-app.cabal`
(same `common` stanza style, GHC2024) with a library (`EmbeddedEn.App`, `EmbeddedEn.Authz`)
and an executable; `build-depends` adds `en-core` and `en-servant` alongside the shomei
packages the embedded example already uses (`shomei-core`, `shomei-servant`,
`shomei-server`, `servant`, `servant-server`, `warp`, `aeson`, `effectful`, …).

`examples/embedded-with-en/cabal.project`:

```text
-- This example is NOT part of the root workspace: it adds the en toolkit as a source
-- dependency, and the root `cabal build all` must stay en-free. Build it from this
-- directory. See README.md for local-co-development overrides.
import: ../../cabal.project

packages: .

source-repository-package
  type: git
  location: https://github.com/shinzui/en.git
  tag: 6b6c0838b710be81aa6b50a64a6b87c5b9d4b910
  subdir: en-core en-servant
```

(The tag is en's HEAD at planning time; bump deliberately, recording the bump in this
plan's Decision Log.) The `import:` line is the spike: it should bring in the root's
`packages:` (the shomei packages, resolved relative to the *root* file) and all the root
`source-repository-package` pins shomei-core needs (codd, hs-jose, webauthn,
ephemeral-pg forks). Verify with the installed cabal:

```bash
cd examples/embedded-with-en
cabal build --dry-run 2>&1 | head -40   # plan must include shomei-server, en-core, en-servant
```

If the installed cabal resolves imported relative `packages:` against the *importing*
file (older cabals did; the behavior stabilized in recent releases), the fallback is
mechanical and must then be committed instead: drop `import:`, list the shomei packages
with `../..`-relative paths, and copy the root's `source-repository-package` blocks in
(with a loud comment naming the root file as the source of truth). Record which branch
was taken in Surprises & Discoveries. Also confirm the ephemeral-pg posture from the
Decision Log: `cabal build --dry-run` should show ephemeral-pg only if test suites of en
packages sneak into the plan (they must not; `tests: False` is cabal's default for
non-local packages, and en packages arriving via `source-repository-package` count as
local-ish — if their tests appear, pin `tests: False` for them in the example project
file and note it).

Acceptance: `cabal build` in the example directory succeeds (the skeleton app can be a
one-line Warp hello using `EmbeddedEn.App` compiled against both projects' modules —
e.g. import `En.Tuple` and `Shomei.Servant.API` to prove both resolve); from the repo
root, `cabal build all && cabal test all` still succeeds and `cabal build all --dry-run`
mentions no en package.

### Milestone 2 — The embedded example: one process, Shōmei login, en-gated routes

Scope: the example does something real. A user signs up and logs in through the mounted
Shōmei API; `GET/PUT /projects/:id` answer 403 until a relationship tuple grants access;
a demo route writes that tuple at runtime. The README carries the live transcript.

**2.1 `EmbeddedEn.Authz`** — everything en-specific, so `App.hs` reads like the existing
embedded example plus three guard lines. Contents, in order:

The subject mapping — the whole coupling between the projects, with the convention
warning in its haddock:

```haskell
-- | THE identity-mapping convention: an en subject is the TypeID text of the Shōmei
-- user id — the same string Shōmei signs into the JWT @sub@ claim — NEVER the bare
-- UUID. en compares object ids by string equality; mixing forms silently denies.
-- (Shōmei's audit output shows bare UUIDs — do not paste those into tuples.)
subjectForUser :: AuthUser -> Subject
subjectForUser u = SubjectId (ObjectRef (ObjectType "user") (idText u.authUserId))
```

The demo schema, built with `En.Schema.Builder` exactly as en-example's `exampleSchema`
(`en-example/src/En/Example/Host.hs` line ~80) builds its document/secret schema:
object `user` (no relations); object `project` with relations `viewer` and `editor`
(both `[Schema.subject "user"]`, rewrite `Schema.this`), permission `view` =
`Schema.anyOf (Schema.computed "viewer") [Schema.computed "editor"]` (an editor can
read), permission `edit` = `Schema.computed "editor"`; `Schema.build [user, project]`,
compiled once with `En.Reachability.compileSchema` (crash at boot on `Left` — a
malformed fixture schema is a programming error, en-example does the same).

The IORef tuple store (see Surprises for why Kikan's cannot be reused):

```haskell
-- | A write-supporting in-memory TupleStore for the demo, modeled on
-- En.Conformance.Kikan.runTupleStoreInMemory (which serves a fixed seed and ignores
-- writes). Reads filter the IORef; WriteTuples appends (dedup), DeleteTuples removes;
-- both return a fresh ConsistencyToken. NOT for production — embed en-postgres (once
-- it grows a pooled runner) or call en-server instead; see the README.
runTupleStoreIORef :: (IOE :> es) => IORef [Tuple] -> Eff (TupleStore : es) a -> Eff es a
```

Implement the read operations by copying Kikan's list-comprehension + `pageTuples`
logic over the IORef contents, and the revision/reap operations as Kikan does (fixed
test revision, zeros). The local consistency store is a copy of en-example's
`runConsistencyStoreInMemory` (line ~162). Then:

```haskell
mkEnEnv :: IORef [Tuple] -> Env '[ConsistencyStore, TupleStore, Error EnError, IOE]
mkEnEnv tuples =
  Env
    { runPorts = runEff . runErrorNoCallStack . runTupleStoreIORef tuples . runConsistencyStoreLocal,
      graph = compiledProjectSchema,
      checkOperation = En.Check.check,
      lookupWithDeadlineOperation = En.Lookup.lookupWithDeadline,
      maxBatchSize = 100
    }
```

(field shapes verified against `En.Servant.Seam.Env` and en-example's `mkEnv`, line
~110; re-check field names against the pinned en tag when implementing).

**2.2 `EmbeddedEn.App`** — start from a copy of
`examples/embedded-servant-app/src/Embedded/App.hs` and extend the API:

```haskell
type AppAPI =
  NamedRoutes ShomeiAPI
    :<|> Authenticated :> "projects" :> Capture "id" Text :> Get '[JSON] Project
    :<|> Authenticated :> "projects" :> Capture "id" Text
           :> ReqBody '[JSON] ProjectUpdate :> Put '[JSON] Project
    :<|> Authenticated :> "demo" :> "grants" :> ReqBody '[JSON] GrantRequest
           :> Post '[JSON] GrantResponse
```

The handlers are the lesson:

```haskell
getProject :: Env EnEffects -> AuthUser -> Text -> Handler Project
getProject env user pid = do
  requirePermission env MinimizeLatency emptyContext
    (subjectForUser user) (RelationName "view") (projectRef pid)
  pure (demoProject pid)

putProject :: Env EnEffects -> AuthUser -> Text -> ProjectUpdate -> Handler Project
putProject env user pid upd = do
  requirePermission env MinimizeLatency emptyContext
    (subjectForUser user) (RelationName "edit") (projectRef pid)
  pure (applyUpdate pid upd)
```

`POST /demo/grants` takes `{"projectId": "...", "relation": "viewer" | "editor"}` and
writes the tuple **for the calling user's own subject** through en's real write path
(`runEngine`-style: run `En.Effect.TupleStore.writeTuples [tuple]` via `env.runPorts`),
returning the `ConsistencyToken` text in the response. A comment and the README both
say what this route stands in for: in production, tuple writes are the host's (or
en-server's) job at its own trust boundary — a route letting callers grant *themselves*
`editor` exists here only so the transcript can flip 403→200 in one process; and the
returned token is what a real host would feed into `AtLeastAsFresh` for its next check
(the demo's very next `PUT` uses `MinimizeLatency` and still sees the write because the
IORef store has a single trivial revision — say so, honestly, rather than implying
`MinimizeLatency` guarantees read-your-writes in general).

`app/Main.hs`: copy the embedded example's executable boot (config, pool, keys →
`Shomei.Server.App.Env`), add `newIORef []` + `mkEnEnv`, serve on the configured port.

**2.3 The README** (`examples/embedded-with-en/README.md`): what the example is (one
paragraph: Shōmei authenticates, en authorizes, handler-level guard, the subject
convention in bold); how to run it (dev shell, `just create-database`, `cabal run` from
the example directory with the same `PG_CONNECTION_STRING` the other examples use); the
transcript (Validation section below, pasted from a real run); the production-notes
section (IORef store is a teaching stand-in; en-postgres single-connection caveat;
pointer to `docs/user/authorization.md` and to en's own docs for running en-server); the
local-co-development note (`cabal.project.local` with relative `packages:` paths into a
sibling en checkout).

Acceptance: the transcript below reproduces against a fresh dev database.

### Milestone 3 — The microservice recipe

Scope: the reader of the microservice example learns, from its README, exactly how to
add a live en check to the downstream service — including why they must not expose
en-server naked.

Create `examples/microservice-auth-stack/README.md`. First section: lift the existing
runbook out of the `process-compose.yaml` header comments (start the stack, signup,
login, curl :8090 with and without the token) so the example finally has a front door;
keep the yaml comments, pointing at the README.

Second section, "Adding en for fine-grained authorization": the recipe. It shows, as
complete copy-pasteable snippets (not compiled into the package — Decision Log):

1. Topology: shomei-server :8080 (auth), downstream :8090 (business), en-server :8081
   (authorization; `EN_DATABASE_URL` pointing at **en's own database**, schema file with
   the project viewer/editor schema, codd migrations from `en-migrations/db/migrations/`
   applied first), and the added `build-depends: en-client, servant-client` the reader
   adds to *their* service.
2. The subject derivation — the same pinned convention, now from the verified claims the
   downstream already holds (its auth handler produces `AuthClaims`):

   ```haskell
   subjectFromClaims :: AuthClaims -> Subject
   subjectFromClaims claims =
     SubjectId (ObjectRef (ObjectType "user") (idText claims.subject))
   ```

   with the same never-the-bare-UUID warning, and a note that the `sub` claim string and
   `idText claims.subject` are identical by construction (`shomei-jwt` signs `idText`).
3. The check call: build a `ClientEnv` against `EN_SERVER_URL`, and in the handler
   replace the ignored-claims body with an `enClient.check` call
   (`En.Client.EnClient`, `CheckRequestWire { consistency, context, subject, permission,
   object }` — wire constructors per `En.Servant.API`; consult the en source pinned in
   the embedded example for exact field spellings), mapping `AllowedWire → proceed`,
   everything else → 403. Fail closed on transport errors too: an unreachable en-server
   is a 503, never a pass.
4. **The security posture, in a warning block the reader cannot miss**: as of 2026-07-07
   en-server has **no caller authentication** — en's
   `docs/plans/33-add-caller-authentication-and-rate-limiting-to-en-server.md` (in the en
   repository) is unimplemented; anyone who can reach the port can rewrite the
   authorization graph. Until that plan lands (it names bearer API keys first, with
   Shōmei-JWT verification as the intended credential checker behind the same seam),
   en-server must sit on a private network segment reachable only by trusted services —
   in practice: same host, private Docker/K8s network, or mesh mTLS — and must never be
   exposed alongside :8080/:8090. When en plan 33 ships, this recipe gets a follow-up:
   the downstream forwards its Shōmei-verified identity (or a service token from plan
   41) as the en-server credential.

Third section: when to prefer en-biscuit decision tokens over per-request checks (the
gateway checks once and mints a decision token the fan-out verifies offline — link en's
`docs/user/biscuit-decision-tokens.md`), and a link to `docs/user/authorization.md`.

Acceptance: README review against a running three-process stack is ideal but manual
(en-server is another repo's binary); minimum bar is that every snippet type-checks when
pasted into a scratch module of the embedded-with-en example (same pinned en sources),
recorded in Surprises & Discoveries.

### Milestone 4 — `docs/user/authorization.md` and the links

Scope: the one page that answers every cross-project question, written for a reader who
knows Shōmei but has never heard of en.

Write `docs/user/authorization.md` with this structure (prose, one section each):

1. **The two tiers.** Shōmei's built-in tier: flat roles + scopes (plan 38), permissions
   and time-bound grants (plan 46) — self-contained, zero extra infrastructure, gates
   Shōmei's own `/admin` surface, staleness bounded by token TTL. When it stops fitting —
   resource-scoped permissions, relationship-derived access, sub-TTL revocation,
   conditional access — graduate the *fine-grained* decisions to en; keep Shōmei's tier
   for bootstrap and coarse gates. Link the runnable example and the recipe. State
   plainly: the built-in tier is never removed in favor of en, and Shōmei's **own role
   grants always stay in Shōmei** — en-server's future caller authentication will itself
   verify Shōmei JWTs (en plan 33), so gating Shōmei's admin surface through en would be
   circular at bootstrap.
2. **Identity mapping.** The convention table (this is the one table the page needs;
   everything around it is prose):

   ```text
   Shōmei principal      en subject                                  Notes
   ------------------    ----------------------------------------    ---------------------------------
   User                  user:<TypeID text>  e.g. user:user_01A…     idText of authUserId / the sub claim; NEVER the bare UUID
   Service account       user:<TypeID text of the backing user>      default; ObjectType "service" keyed by client_id (plan 41) only as a deliberate schema choice
   Impersonation         check the SUBJECT (sub, the impersonated    audit the act operator; optional 2nd check on the actor;
                         user)                                       caveat context carries actor facts if the schema needs them
   ```

   plus the string-equality trap and the audit-columns-show-UUIDs warning, verbatim from
   the Decision Log.
3. **Consistency.** `MinimizeLatency` by default; capture the token en returns from
   writes and use `AtLeastAsFresh` for the next check after a grant-changing write
   (`FullyConsistent` when no token is at hand); decisions travel via en-biscuit grants
   (which embed the token) — **never put en consistency tokens or en decisions into
   Shōmei JWTs**, and why (minted-then-static vs. live; the mirror-image warning sits on
   `ClaimsEnricher`'s haddock after plan 38).
4. **Database topology.** One database per system, as the default and only documented
   arrangement; the two reasons (two codd ledgers in one database is unverified; en's
   revisions are per-database `pg_current_snapshot()` machinery, so cohabitation buys no
   consistency); en tables live in `public` today (schema namespacing is en-side
   optional work).
5. **Current en-side gaps** (a short admonition mirroring External Companion Work, so
   the docs stay honest when read without this plan): no en-server caller auth yet; no
   pooled embedding runner; `subjectFromUserId` not yet exported from en; no mutable
   in-memory tuple store (en's only in-memory interpreter is a read-only conformance
   fixture, so databaseless demos ship their own).

Then link it: `README.md` Documentation list (after security.md), `docs/user/index.md`
Feature Guides (after Security Model), a "Fine-grained authorization" pointer from
`docs/user/security.md`'s roles section (if plan 38's rewrite exists; otherwise from the
current "Known limitation" paragraph), and a sentence in
`docs/user/client-and-examples.md` introducing the third example. Add the CHANGELOG
entry and update MasterPlan 7's registry row for this plan.

Acceptance: `docs/user/index.md` and `README.md` render with working relative links
(spot-check with a Markdown previewer or the docs toolchain if one exists); a reader
following only the docs page can state the subject convention and the topology default
without opening either plan.


## External Companion Work

Work this plan deliberately does **not** do, because it belongs in the en repository.
Listed so the boundary is explicit and so the docs page's "current gaps" admonition has a
source of truth. None of these block any milestone above.

- **Pooled database runner for embedding en**: `en-postgres` exposes only
  `runDatabaseConnection` over a single `Hasql.Connection`
  (`en-postgres/src/En/Postgres/Database.hs` lines ~29-33). A host embedding en-postgres
  inside a concurrent Servant app needs a `runDatabasePool` over `Hasql.Pool` (shomei's
  `Shomei.Postgres.Database.runDatabasePool` is the model). Belongs in
  `en-postgres/src/En/Postgres/Database.hs`.
- **en-server caller authentication (with a Shōmei-JWT verifier)**: en's
  `docs/plans/33-add-caller-authentication-and-rate-limiting-to-en-server.md` — bearer
  API keys in two tiers behind a credential-checking seam, explicitly designed so a
  Shōmei-JWT/mTLS checker can replace the key lookup later. Until it lands, the
  microservice recipe's network-trust warning stands.
- **Promote `subjectFromUserId` into en's public API**: today it exists only in en's
  docs (`en/docs/user/biscuit-decision-tokens.md`) and tests (`en-biscuit/test/Main.hs`
  lines ~592-647). Exporting `subjectFromUserId :: Text -> Subject` from
  `En.Servant.Authorize` (or a small `En.Servant.Subject` module) would let shomei-side
  examples and hosts stop copying the two-liner. Belongs in
  `en-servant/src/En/Servant/Authorize.hs`.
- **Optional PostgreSQL schema namespacing for en**: en's migrations
  (`en-migrations/db/migrations/`) create `relation_tuple`/`en_transaction` in the
  `public` schema; moving them into an `en` schema would make cohabitation with other
  tools tidier for operators who must consolidate databases (still not the documented
  default — see the topology decision). Belongs in `en-migrations/db/migrations/`.
- **A mutable in-memory `TupleStore` interpreter in en-core, for tests and demos only**:
  the only in-memory interpreter en ships is
  `En.Conformance.Kikan.runTupleStoreInMemory`, which interprets reads over a *fixed
  pure list* and deliberately ignores writes — `WriteTuples _ ->
  pure (ConsistencyToken "in-memory-write")` (`en-core/src/En/Conformance/Kikan.hs`,
  `WriteTuples`/`DeleteTuples` cases). That is correct for its purpose (a read-only
  conformance fixture) but it means every embedder who wants to unit-test their
  authorization wiring or run a databaseless demo writes their own mutable store, as
  this plan's example does (the `IORef`-backed interpreter in Milestone 1). Shōmei's own
  `Shomei.Effect.InMemory` — shipped explicitly for pure test suites and hybrid test
  stacks, never production — is the model. This is emphatically **not** a production
  store and its haddock should say so: authorization data must survive restarts and
  agree across instances, and en's consistency guarantees (tokens, snapshot reads,
  new-enemy protection) are grounded in PostgreSQL's `pg_current_snapshot()`/xid8
  machinery that a process-local `IORef` revision counter only pretends to satisfy.
  Now scheduled: en's
  `docs/plans/58-add-a-mutable-in-memory-tuple-store-for-tests-and-demos.md` (created
  2026-07-07 after this gap was found) delivers `En.Store.InMemory` with exactly this
  posture. Once it lands, this plan's example should drop its bespoke interpreter and
  consume en's.


## Concrete Steps

All shomei commands run from the repository root
`/Users/shinzui/Keikaku/bokuno/shomei`, inside the dev shell (`nix develop`), except the
example builds, which run from the example directory (stated per command). The dev
PostgreSQL comes from the dev shell / `process-compose.yaml`; `just create-database` is
idempotent.

```bash
nix develop
just create-database

# Milestone 1 — skeleton + spike
mkdir -p examples/embedded-with-en/{app,src/EmbeddedEn}
# … create the files per Milestone 1 …
cd examples/embedded-with-en
cabal build --dry-run 2>&1 | grep -E 'en-core|en-servant|shomei-server'
# → en-core-<ver> (lib), en-servant-<ver> (lib), shomei-server-<ver> (lib) … all present
cabal build
cd ../..
cabal build all --dry-run 2>&1 | grep -c 'en-core'
# → 0   (the root workspace stays en-free)

# Milestone 2 — run the example (dev database must exist)
cd examples/embedded-with-en
PG_CONNECTION_STRING="host=localhost port=5432 dbname=shomei user=shomei" \
  SHOMEI_PORT=8080 cabal run embedded-with-en
# → [embedded-with-en] shomei mounted at /auth; en schema compiled; listening on :8080
```

Expected git status shape when the plan completes (no root `cabal.project` diff):

```text
new:      examples/embedded-with-en/…            (project file, cabal, src, app, README)
new:      examples/microservice-auth-stack/README.md
new:      docs/user/authorization.md
modified: README.md docs/user/index.md docs/user/client-and-examples.md
modified: docs/user/security.md                  (one pointer paragraph)
modified: CHANGELOG.md docs/masterplans/7-…md docs/plans/47-…md
```

Commit at each milestone boundary with conventional-commit messages, e.g.:

```text
feat(examples): scaffold embedded-with-en with en as a pinned source dependency (EP-10 M1)
feat(examples): shomei-authenticated, en-authorized /projects routes with live transcript (EP-10 M2)
docs(examples): microservice recipe for en-client checks behind shomei JWTs (EP-10 M3)
docs(user): authorization.md — the two-tier story and en integration conventions (EP-10 M4)
```


## Validation and Acceptance

The Milestone 2 transcript, run against a fresh dev database (paste real output into the
example README and into this plan when recorded). Working directory
`examples/embedded-with-en`, server running per Concrete Steps:

```bash
# 1. signup + login through the MOUNTED shomei API (same process)
curl -s -XPOST localhost:8080/auth/signup -H 'Content-Type: application/json' \
  -d '{"email":"ann@example.com","password":"Str0ng-Pass-123!","displayName":"Ann"}' >/dev/null
TOK=$(curl -s -XPOST localhost:8080/auth/login -H 'Content-Type: application/json' \
  -d '{"email":"ann@example.com","password":"Str0ng-Pass-123!"}' | jq -r .token.accessToken)

# 2. no tuples yet: en fails closed on both routes
curl -s -o /dev/null -w '%{http_code}\n' localhost:8080/projects/roadmap \
  -H "Authorization: Bearer $TOK"
# → 403
curl -s -o /dev/null -w '%{http_code}\n' -XPUT localhost:8080/projects/roadmap \
  -H "Authorization: Bearer $TOK" -H 'Content-Type: application/json' \
  -d '{"projectName":"Roadmap v2"}'
# → 403

# 3. grant the caller editor on project:roadmap (demo route writes the relation tuple
#    for the caller's own subject — user:user_01…, the TypeID text, never the UUID)
curl -s -XPOST localhost:8080/demo/grants -H "Authorization: Bearer $TOK" \
  -H 'Content-Type: application/json' -d '{"projectId":"roadmap","relation":"editor"}'
# → {"granted":"editor","object":"project:roadmap","consistencyToken":"…"}

# 4. editor implies edit AND view (the schema's anyOf)
curl -s -o /dev/null -w '%{http_code}\n' -XPUT localhost:8080/projects/roadmap \
  -H "Authorization: Bearer $TOK" -H 'Content-Type: application/json' \
  -d '{"projectName":"Roadmap v2"}'
# → 200
curl -s localhost:8080/projects/roadmap -H "Authorization: Bearer $TOK" | jq .projectName
# → "Roadmap v2"

# 5. authentication still owned by shomei: no/garbage token never reaches en
curl -s -o /dev/null -w '%{http_code}\n' localhost:8080/projects/roadmap
# → 401
```

Acceptance criteria, phrased as observable behavior:

- The transcript above reproduces end-to-end: 401 with no token (Shōmei's guard), 403
  with a valid token and no tuple (en fail-closed), 200 after the tuple write, with the
  `view`-via-`editor` union observable in step 4.
- `cabal build` succeeds inside `examples/embedded-with-en`; `cabal build all` and
  `cabal test all` at the root succeed with no en package in the plan.
- `examples/microservice-auth-stack/README.md` exists, contains the runnable base-stack
  runbook, the en recipe with the subject-derivation and fail-closed snippets, and the
  en-server no-caller-auth warning naming en's plan 33.
- `docs/user/authorization.md` exists and is reachable from `README.md` and
  `docs/user/index.md`; it contains the identity-mapping conventions (TypeID text; the
  service-account default; the impersonation pattern), the consistency guidance
  including the "never in Shōmei JWTs" rule, the one-database-per-system default with
  both reasons, and the bootstrap-circularity note.
- Grepping the new artifacts for the wrong convention finds nothing:
  `grep -rn 'ObjectRef (ObjectType "user")' examples/embedded-with-en docs/user/authorization.md`
  shows only `idText`-derived ids in adjacent code, never a `UUID.toText`.


## Idempotence and Recovery

Everything here is additive: new example directory, new READMEs, one new docs page, link
edits — no migrations, no schema changes, no behavior changes to any existing package.
Re-running any step overwrites files with identical content. The example's dev database
usage goes through the same `just create-database` flow as the existing examples (safe to
re-run; drop and recreate the dev database to reset the demo users). The en pin is the
one piece of state to manage deliberately: it is a plain `tag:` in the example's project
file; bumping it is a one-line change plus a rebuild, and if a bump breaks the example,
reverting the line restores the previous working build (record bumps and breakages in
the Decision Log / Surprises). If the Milestone 1 spike's `import:` approach fails after
being committed (e.g. a cabal upgrade changes semantics), the fallback project file in
Milestone 1 is a drop-in replacement — nothing else in the plan depends on which variant
is in place. The demo grant route mutates only an in-process IORef; restarting the
example resets all en state (say so in the README so nobody is surprised that grants do
not survive restarts).


## Interfaces and Dependencies

New external dependency, scoped to the example only: the **en** toolkit
(`https://github.com/shinzui/en.git`, pinned by tag; packages `en-core` and
`en-servant`), consumed via `source-repository-package` in
`examples/embedded-with-en/cabal.project`. The microservice *recipe* additionally names
`en-client` and `servant-client`, but as reader-applied snippets, not as build-depends of
anything in this repository. No changes to the root `cabal.project`, no new dependencies
for any shipped shomei package. Toolchain: both repos pin GHC 9.12.4 and matching
nixpkgs, so `nix develop` in shomei suffices for every step.

Must exist at the end (full paths; signatures where code is involved):

- `examples/embedded-with-en/cabal.project` — root import (or documented fallback) + en
  source pin (`subdir: en-core en-servant`).
- `examples/embedded-with-en/src/EmbeddedEn/Authz.hs`:
  `subjectForUser :: AuthUser -> Subject` (the pinned convention),
  `projectSchema :: Schema` / `compiledProjectSchema :: ReachabilityGraph`,
  `runTupleStoreIORef :: (IOE :> es) => IORef [Tuple] -> Eff (TupleStore : es) a -> Eff es a`,
  `runConsistencyStoreLocal`, and
  `mkEnEnv :: IORef [Tuple] -> Env '[ConsistencyStore, TupleStore, Error EnError, IOE]`.
- `examples/embedded-with-en/src/EmbeddedEn/App.hs`: `AppAPI` mounting
  `NamedRoutes ShomeiAPI` plus the two `requirePermission`-guarded project routes and
  `POST /demo/grants`; `embeddedEnApplication :: Shomei.Server.App.Env -> IORef [Tuple] -> Application`.
- `examples/embedded-with-en/app/Main.hs` and `examples/embedded-with-en/README.md`
  (with the recorded transcript and the production notes).
- `examples/microservice-auth-stack/README.md` — base runbook + the en recipe
  (subject derivation `subjectFromClaims :: AuthClaims -> Subject`, `enClient.check`
  handling, fail-closed transport errors, the en-server exposure warning).
- `docs/user/authorization.md`, linked from `README.md`, `docs/user/index.md`,
  `docs/user/security.md`, and `docs/user/client-and-examples.md`.

Key upstream interfaces this plan consumes (verified 2026-07-07; re-verify against the
pinned en tag when implementing): `En.Servant.Authorize.requirePermission :: Env es ->
Consistency -> CaveatContext -> Subject -> RelationName -> ObjectRef -> Handler ()`;
`En.Servant.Seam.Env (..)`; `En.Tuple.ObjectRef (..)` / `Subject (..)` / `Tuple (..)`;
`En.Schema.Builder` (`object`, `relation`, `permission`, `subject`, `computed`, `anyOf`,
`this`, `build`); `En.Reachability.compileSchema`; `En.Check.check`;
`En.Lookup.lookupWithDeadline`; `En.Effect.TupleStore.TupleStore (..)` /
`writeTuples`; `En.Revision.Consistency (..)`; and on the shomei side
`Shomei.Servant.Auth.AuthUser`, `Shomei.Id.idText`, `Shomei.Server.Boot.seamEnv` /
`authContext`, `Shomei.Servant.Handlers.shomeiServer`.

---

Revision note (2026-07-07): Added a fifth External Companion Work item — a general-purpose
mutable in-memory `TupleStore` interpreter for en-core — and mirrored it in the docs page's
"current en-side gaps" admonition. Reason: a follow-up check confirmed en's only in-memory
interpreter (`En.Conformance.Kikan.runTupleStoreInMemory`) is a deliberately read-only
conformance fixture whose write operations return dummy consistency tokens, and no en plan or
masterplan schedules a mutable replacement — so the bespoke `IORef` interpreter this plan's
example ships is not a temporary workaround for scheduled work but fills a real, unplanned
en-side gap. The example should migrate onto en's interpreter if and when one lands.

Revision note (2026-07-07, follow-up): Sharpened the in-memory-interpreter companion-work item
to say tests-and-demos only, with the reason a production in-memory store is a non-goal
(authorization data needs durability and cross-instance agreement; en's consistency guarantees
are grounded in PostgreSQL snapshot machinery an `IORef` cannot honor). Shōmei's own
`Shomei.Effect.InMemory` test-only posture is cited as the model.

Revision note (2026-07-07, second follow-up): The in-memory-interpreter gap is now scheduled
on the en side as `en/docs/plans/58-add-a-mutable-in-memory-tuple-store-for-tests-and-demos.md`;
the External Companion Work item was updated from "unscheduled" to a pointer at that plan.
This plan's Milestone 1 still ships its own `IORef` interpreter (en plan 58 is unimplemented),
migrating onto `En.Store.InMemory` when it lands.
