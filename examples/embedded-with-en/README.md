# embedded-with-en — Shōmei authentication + en authorization in one process

This example mounts the **whole Shōmei auth API** inside a host Servant app (exactly as
`../embedded-servant-app` does) and adds business routes `GET/PUT /projects/:id` guarded by
**en**, the author's Zanzibar-style ReBAC toolkit (<https://github.com/shinzui/en>).

Shōmei answers *who is calling* (the `Authenticated` combinator produces the `AuthUser`); en
answers *what they may do* (a relationship check against a small `project` schema). The
handler-level guard `requireProjectPermission` fails **closed**: no relation tuple ⇒ `403`.

**The one coupling between the two projects is the subject mapping.** A Shōmei user becomes
the en subject `user:<TypeID text>` — the exact string Shōmei signs into the JWT `sub` claim
(`idText authUser.authUserId`), **never the bare UUID** Shōmei's audit output shows. en
compares object ids by string equality, so a mismatched form silently denies everything. See
`src/EmbeddedEn/Authz.hs` (`subjectForUser`).

## What this example depends on

Only **`en-core`**, pinned as a git source dependency in this directory's `cabal.project`
(not the root — the root `cabal build all` stays en-free). `en-core` has no en-package
dependencies and no openapi/biscuit/hasql dependencies, so it drops into Shōmei's existing
build plan with zero new external pins. The fail-closed guard is a faithful ~20-line copy of
`En.Servant.Authorize.requirePermission` built directly over `En.Check.check`; a production
host whose build does not hit the openapi pin conflict should prefer en-servant's guard. See
`docs/user/authorization.md` and `src/EmbeddedEn/Authz.hs` for the full rationale.

## Running it

From the repository dev shell (`nix develop`), with the dev database created
(`just create-database`). The dev shell already exports `PG_CONNECTION_STRING` (a unix-socket
connection to the local dev cluster), so you only choose a port:

```bash
cd examples/embedded-with-en
SHOMEI_PORT=8085 cabal run embedded-with-en
# → [embedded-with-en] shomei auth mounted; en project schema compiled; listening on :8085
```

(Outside the dev shell, set `PG_CONNECTION_STRING` yourself, exactly as the other examples do.)

## Transcript

Recorded from a real run against a fresh dev database. Shōmei owns authentication (the `401`);
en owns authorization (the `403`s, and the `403→200` flip after a relation tuple is written):

```console
$ # 1. signup + login through the MOUNTED shomei API (same process)
$ curl -s -XPOST localhost:8085/v1/auth/signup -H 'Content-Type: application/json' \
    -d '{"email":"ann@example.com","password":"Str0ng-Pass-123!","displayName":"Ann"}' -o /dev/null -w '%{http_code}\n'
201
$ TOK=$(curl -s -XPOST localhost:8085/v1/auth/login -H 'Content-Type: application/json' \
    -d '{"email":"ann@example.com","password":"Str0ng-Pass-123!"}' | jq -r .token.accessToken)

$ # 2. no tuples yet: en fails closed on both routes
$ curl -s -o /dev/null -w '%{http_code}\n' localhost:8085/projects/roadmap -H "Authorization: Bearer $TOK"
403
$ curl -s -o /dev/null -w '%{http_code}\n' -XPUT localhost:8085/projects/roadmap \
    -H "Authorization: Bearer $TOK" -H 'Content-Type: application/json' -d '{"projectName":"Roadmap v2"}'
403

$ # 3. grant the caller editor on project:roadmap (writes the relation tuple for the
$ #    caller's own subject — user:user_01…, the TypeID text, never the UUID)
$ curl -s -XPOST localhost:8085/demo/grants -H "Authorization: Bearer $TOK" \
    -H 'Content-Type: application/json' -d '{"projectId":"roadmap","relation":"editor"}'
{"consistencyToken":"embedded-en-write","granted":"editor","object":"project:roadmap"}

$ # 4. editor implies edit AND view (the schema's anyOf)
$ curl -s -o /dev/null -w '%{http_code}\n' -XPUT localhost:8085/projects/roadmap \
    -H "Authorization: Bearer $TOK" -H 'Content-Type: application/json' -d '{"projectName":"Roadmap v2"}'
200
$ curl -s localhost:8085/projects/roadmap -H "Authorization: Bearer $TOK"
{"projectId":"roadmap","projectName":"Project roadmap"}

$ # 5. authentication still owned by shomei: no token never reaches en
$ curl -s -o /dev/null -w '%{http_code}\n' localhost:8085/projects/roadmap
401

$ # 6. authorization is per-object: a project with no grant is still 403
$ curl -s -o /dev/null -w '%{http_code}\n' localhost:8085/projects/secret -H "Authorization: Bearer $TOK"
403
```

Two honest notes on the output:

- The `GET` in step 4 returns `"Project roadmap"`, not `"Roadmap v2"`: this demo owns **no
  project store**, so `PUT` authorizes the edit but persists nothing. The lesson is the status
  code (`403→200`), not the body.
- `consistencyToken` is `"embedded-en-write"` — a placeholder the `IORef` store mints. A real
  en store returns a meaningful token to carry into an `AtLeastAsFresh` follow-up check.

## Production notes

- **The in-memory `IORef` tuple store is a teaching stand-in, not production.** Authorization
  data must survive restarts and agree across instances; en's consistency guarantees are
  grounded in PostgreSQL snapshot machinery an `IORef` only pretends to satisfy. Restarting
  the process resets all en state (grants do not survive a restart). In production, embed
  `en-postgres` or call a standalone `en-server`; see en's own docs.
- **`POST /demo/grants` is not a production shape.** It lets the caller grant *itself*
  `editor` so the transcript can flip `403→200` in one process. Real tuple writes are the
  host's (or en-server's) job at its own trust boundary.
- **Consistency.** The grant response returns en's consistency token. The next check here
  uses `MinimizeLatency` and still observes the write, because the `IORef` store keeps a
  single trivial revision — *not* because `MinimizeLatency` guarantees read-your-writes in
  general. After a grant-changing write against a real en store, carry the returned token
  into an `AtLeastAsFresh` check. See `docs/user/authorization.md`.

## Local co-development against an uncommitted en checkout

The `cabal.project` pins en by commit. To build against a sibling en working tree instead,
drop an untracked `cabal.project.local` in this directory:

```cabal
packages: . ../../../en/en-core
```

(Relative to this directory; adjust to your layout.) This overrides the source pin with your
local `en-core`.
