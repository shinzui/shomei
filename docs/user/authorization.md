# Authorization: the two-tier story and the en integration

Shōmei is an **authentication** toolkit: it establishes *who is calling* (passwords, passkeys,
MFA, sessions, JWTs). This page answers the next question — *what may they do?* — and the
cross-project conventions that make "**Shōmei for authentication, en for authorization**" the
paved road.

If you have never heard of **en**: it is the author's sibling
[project](mori://shinzui/en) (<https://github.com/shinzui/en>), a **Zanzibar-style ReBAC** (relationship-based access
control) toolkit. Authorization data is a set of **relation tuples** — facts of the form
*subject has relation on object*, e.g. `user:user_01ABC… is editor of project:roadmap` — and a
**schema** declares how *permissions* rewrite into relations (e.g. `view = viewer ∪ editor`). A
**check** asks "does subject S have permission P on object O?" and walks the tuple graph.

## The two tiers

Authorization in a Shōmei deployment is **two tiers**, and it matters which one you are in.

**Tier 1 — Shōmei's built-in RBAC.** Flat `(user, role)` grants stored in Shōmei's own
database and copied into the `roles` claim of every access token; roles imply **permissions**
(verb-noun capability strings in a parallel `permissions` claim), and grants may be
**time-bound**. This tier needs **zero extra infrastructure**, it is what gates Shōmei's own
`/admin` surface, and it is the right tool for coarse questions: *is this principal an
administrator? a support agent? a paying member?* Its staleness is bounded by the access
token's TTL. See [Roles and authorization](security.md#roles-and-authorization).

**Tier 2 — fine-grained authorization, with en.** Questions of the form *is this user an editor
**of this project**?* — resource-scoped permissions, access derived from relationships,
revocation that takes effect immediately (sub-TTL), conditional access. Shōmei deliberately does
**not** grow into this: a JWT claim is minted once and frozen for its lifetime, which is the
wrong transport for a decision that must be live. Graduate the *fine-grained* decisions to en;
keep Shōmei's tier for bootstrap and coarse gates.

**The built-in tier is never removed in favor of en, and Shōmei's own role grants always stay
in Shōmei.** en-server authenticates its callers with static API keys and deliberately does not
verify Shōmei JWTs ([the en project](mori://shinzui/en),
`docs/plans/33-add-caller-authentication-and-rate-limiting-to-en-server.md`; the artifact-level URI
is pending), so it has no notion of a Shōmei user's roles: en could only answer "is this user an
administrator?" if something already authorized to write tuples had said so first. Three things
follow. Shōmei's `/v1/admin` surface must work on a fresh database with no en deployed, because en
is optional and the standalone server has no en dependency. The first administrator is granted
from the box (`shomei-admin roles grant`), outside both HTTP surfaces, and an en deployment would
copy *from* that grant, never the other way round. And a live authorization decision must not be
frozen into a JWT claim (see [Consistency](#consistency)), so Shōmei's coarse gate and en's live
check are different tiers by construction. The two tiers compose rather than compete.

**The graduation boundary.** Reach for en when — and only when — you need one of: a permission
scoped to a specific resource instance; access that follows a relationship (`editor of the
parent folder ⇒ editor of the child`); revocation that must take effect before the current
token expires; or access conditioned on request attributes (caveats). Everything coarser is
tier 1's job.

See it working:

- [`examples/embedded-with-en`](../../examples/embedded-with-en/README.md) — one Servant
  process: Shōmei authenticates, en authorizes `GET/PUT /projects/:id`, with a copy-pasteable
  `403 → grant → 200` transcript.
- [`examples/microservice-auth-stack`](../../examples/microservice-auth-stack/README.md) — the
  recipe for a downstream service that verifies Shōmei JWTs offline and asks a standalone
  `en-server` for the fine-grained decision.

## Identity mapping — the single most bug-prone seam

en compares object ids by **string equality**. A tuple written for one rendering of a user id
will never match a check for another rendering of the *same* user — and it does **not** error;
it silently denies. So the mapping from a Shōmei principal to an en subject must be pinned, and
it is:

```text
Shōmei principal      en subject                                  Notes
------------------    ----------------------------------------    -------------------------------------------------
User                  user:<TypeID text>                          idText of authUserId / the JWT `sub` claim;
                      e.g. user:user_01ABC…                       NEVER the bare UUID.
Service account       user:<TypeID text of the backing user>      default; ObjectType "service" keyed by client_id
                      e.g. user:svcacct_01…                        (svcacct_… TypeID) only as a deliberate schema choice.
Impersonation         check the SUBJECT (the `sub`, i.e. the      audit the `act` operator alongside the decision;
                      impersonated user)                          optional 2nd check on the actor; caveat context
                                                                  carries actor facts if the schema needs them.
```

**Use TypeID text, never the bare UUID.** The convention is
`SubjectId (ObjectRef (ObjectType "user") (idText authUser.authUserId))` — the exact string
Shōmei signs into the JWT `sub` claim. The trap is sharpened by Shōmei itself: its denormalized
**audit** columns and `shomei-admin audit` output render **bare UUIDs** (`0198a3bc-…`), so an
operator copy-pasting a user id from the audit trail into a tuple write gets the wrong form and
en silently denies. Pin the TypeID text — the value every service actually holds after JWT
verification — and the subject namespace stays self-describing (`user_…` / `svcacct_…` prefixes
survive into en tuples).

**Service accounts** map to `user:` subjects by default: Shōmei's service tokens set `sub` to
the backing service *user*'s id, so one tuple vocabulary covers humans and machines and the
"`sub`-claim-is-the-subject" rule holds uniformly (the verifying service needs no lookup). A
host whose en schema genuinely branches on machine-ness *may* adopt `ObjectType "service"` keyed
by the `client_id`, as a deliberate, documented schema choice — but the recommendation is to
keep `user:` unless the schema actually decides on it.

**Impersonation and delegated tokens** (RFC 8693 token exchange, `/auth/impersonate`) carry the
impersonated user in `sub` and the operator in `act`. Check en against the **subject** — that is
the whole point of impersonation: the operator should see exactly what the user can see.
Checking only the actor would leak the operator's broader access into the user's view. **Audit
the `act` operator** alongside the en decision — the host must do this, because `act` exists only
in the verified Shōmei claims, and en has no actor notion of its own. If a policy requires
"impersonation must not exceed the operator's own access," add a **second** en check against the
actor (e.g. an `operator` permission on the same object); if the schema wants conditional rules
about actor facts, those go in the **caveat context**.

## Consistency

en owns a `Consistency` vocabulary. Use it like this:

- **Default to `MinimizeLatency`.** It may serve a slightly stale (cached) answer, which is the
  right trade for the vast majority of reads.
- **After a grant-changing en write, read your writes.** en returns a **consistency token** from
  every write and from every check (`checkedAt`). Carry it into the next check as
  `AtLeastAsFresh <token>` so that check observes at least everything the write did. Where no
  token is at hand, `FullyConsistent` is the (more expensive) fallback.
- **Where a *decision* must travel between services**, use en's own **en-biscuit decision
  tokens** (which embed the consistency token) as the transport — a gateway checks once and
  mints a token the fan-out verifies offline.

**Never put en consistency tokens or en decisions into Shōmei JWTs.** A Shōmei JWT is minted
once, *before* the writes a request will cause, and lives for its whole TTL — a consistency
token frozen into it is stale by construction, and an authorization *decision* frozen into it
recreates exactly the live-revocation failure the two-tier split exists to avoid. (Shōmei's
`ClaimsEnricher` Haddock carries the mirror-image of this warning from the other side: enrich
claims with *identity* facts, not live authorization decisions.)

## Database topology — one database per system

**Shōmei owns its database; en owns its own.** This is the default and the only documented
arrangement. Shōmei's migrations create everything in the `shomei` schema; en's migrations
create `relation_tuple`/`en_transaction` in the `public` schema. They do not collide by name —
but they still should not share a database, for two reasons:

1. **Both projects now run on `pg-migrate`, so one ledger is possible — but still not the
   default.** `shomei-migrations` exports `shomeiMigrationComponent`; en's `en-migrations`
   ([the en project](mori://shinzui/en), `en-migrations/`; the artifact-level URI is pending) has
   used `pg-migrate` since 2026-08-24, with one bootstrap migration plus a manifest applied by
   `cabal run en-migrate -- up`. A host can compose both components into one ordered
   `MigrationPlan`. Composition is supported, not verified here, and reason 2 is the stronger
   argument.
2. **en's consistency machinery is inherently per-database.** en's revisions are built on
   PostgreSQL's `pg_current_snapshot()` / `pg_current_xact_id()` (xid8) arithmetic, so sharing a
   database with Shōmei buys **no** cross-system transactional consistency — there is none to be
   had. Separate databases also keep backup, retention, and scaling decisions independent, which
   matches the trust boundary between authentication and authorization.

(en-side schema namespacing — moving en's tables into an `en` schema — is optional companion
work for operators who *must* consolidate; it is still not the documented default.)

## Current en-side facts (as of en bf8ffa2, 2026-08-26)

en-server authenticates callers with static bearer API keys in two tiers:
`EN_API_KEYS_READ_WRITE` may call every endpoint, while `EN_API_KEYS_READ_ONLY` may call query
endpoints only and receives `403` on tuple writes. Keys are compared in constant time. A per-key
token bucket uses `EN_RATE_LIMIT_RPS` and `EN_RATE_LIMIT_BURST`, returning `429` with
`Retry-After` when exhausted. Startup fails closed when no key is configured unless an operator
sets `EN_AUTH_DISABLED=true`; that local-development escape is ignored when any key exists. These
rules landed in the [en project](mori://shinzui/en) plan at
`docs/plans/33-add-caller-authentication-and-rate-limiting-to-en-server.md` (the artifact-level URI
is pending) on 2026-07-08. en-client still adds no authorization header, so a downstream must send
`Authorization: Bearer <en key>` itself, as the microservice example does. en deliberately does
not verify Shōmei JWTs: Shōmei remains an extension point rather than an en dependency, and the
downstream calls en under its own service identity after verifying the user's token.

en-postgres exports the pooled interpreter `runDatabasePool`, including at the older `d3209cb`
revision against which this page was first written. The `embedded-with-en` example remains
in-memory to keep its build light — en-postgres brings the hasql and biscuit dependency families —
not because a concurrent pooled runner is missing. EP-9 has updated the example's en-core pin to
the verified `bf8ffa24` revision and implemented its current `TupleStore` vocabulary.

en's `en-migrations` has used `pg-migrate ^>=1.1.0.0` since 2026-08-24. Its
`en-migrations/migrations/` directory in the [en project](mori://shinzui/en) (artifact-level URI
pending) contains `0001-en-bootstrap.sql` and a manifest; `cabal run en-migrate -- up` applies the
component, whose tables remain in `public`.

One integration helper is still absent: en does not export `subjectFromUserId`. Its two-line
definition appears only in the [en project](mori://shinzui/en) at
`en-biscuit/test/Main.hs` and `docs/user/biscuit-decision-tokens.md` (artifact-level URIs pending),
so Shōmei-side examples define the mapping themselves.

en-side follow-ups are not edited here: export `subjectFromUserId`, and update the old Shōmei
module name in en's `docs/user/biscuit-decision-tokens.md` (same project URI; artifact-level URI
pending). The Shōmei-side companion work was tracked in the External Companion Work section of
[plan 47](../plans/47-en-integration-examples-and-guidance-for-the-recommended-authorization-layer.md).
