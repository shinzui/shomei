---
id: 75
slug: align-the-public-error-catalog-with-served-oauth-responses
title: "Align the public error catalog with served OAuth responses"
kind: exec-plan
created_at: 2026-11-16T21:31:44Z
intention: "intention_01m7k4bchze6eayb21maev6pmn"
provenance:
  created_by:
    model: "gpt-6-astra"
    harness: "codex-cli"
    at: 2026-11-16T21:31:44Z
---

# Align the public error catalog with served OAuth responses

This ExecPlan is a living document. Keep Progress, Surprises & Discoveries, Decision Log, and Outcomes & Retrospective current during implementation. Follow `agents/skills/exec-plan/FRICTION.md` for implementation friction and `agents/skills/exec-plan/ADR.md` for durable decisions.

## Purpose / Big Picture

Resolve [issue #6](https://github.com/shinzui/shomei/issues/6): clients reading the error catalog should know the actual status, body format, and retry headers they receive when machine or delegated sessions reach their limit or impersonation is refused. The current catalog advertises application problem codes for failures served through OAuth instead. Correct the documentation and prove the existing HTTP behavior with regression tests. Preserve the current public runtime contract.

After implementation, a reader can distinguish a quota refusal (`503 temporarily_unavailable`, without `Retry-After`) from request throttling (`429 temporarily_unavailable`, with `Retry-After: 60` in the OAuth namespace). They can also see that impersonation refusals deliberately use a generic `400 invalid_grant` and that built-in application responses currently omit the optional `instance` member.

## Progress

- [ ] Correct the public catalog and related OAuth guidance, preserving all existing problem-type anchors and documenting which mappings are library-only.
- [ ] Verify the documented distinctions with HTTP and catalog regression coverage; pass the focused test suites and formatting checks.

Planning completed on 2026-11-16. Implementation has not begun.

## Surprises & Discoveries


## Decision Log

- Decision: Fix the documentation to describe the existing OAuth behavior instead of changing token endpoints to emit problem documents or adding a fabricated retry interval. Rationale: issue #6 permits this resolution, and ADR-27 requires OAuth-format errors throughout OAuth routes. A session quota has no known fixed recovery interval. Date: 2026-11-16.
- Decision: Preserve the exported problem specifications, generic AuthError mappings, optional occurrence fields, and public anchors. Separate library-only mappings from the built-in route catalog. Rationale: embedding applications can use these APIs and existing type URIs must continue to resolve; availability in the library does not prove reachability from a built-in route. Date: 2026-11-16.

## Outcomes & Retrospective


## Context and Orientation

Shōmei exposes ordinary application routes under `/v1` and OAuth token operations at `POST /oauth/token`. An application problem document uses `application/problem+json` and fields such as `type`, `code`, and `retryable`. An OAuth error uses JSON with `error` and `error_description`. A problem catalog entry is a reusable library specification, not evidence that a built-in route emits that entry.

`docs/user/problem-details.md` currently places `session_limit_reached`, `impersonation_forbidden`, and `impersonation_target_invalid` in the main table without qualifying their reachability. Its session-limit row incorrectly promises `Retry-After` always. Its introduction describes optional occurrence fields without explaining that stock responses do not populate `instance`.

`shomei-servant/src/Shomei/Servant/Error.hs` exports `ProblemSpec`, `ProblemOccurrence`, `problemCatalog`, `problemDetails`, `toProblemError`, and `authErrorToServerError`. The generic mapping retains `SessionLimitReached` as a retryable 429 problem, `ImpersonationForbidden` as 403, and `ImpersonationTargetInvalid` as 400. These use an empty occurrence: no retry header or instance URI. `ProblemOccurrence.instanceUri` allows an embedding application to supply an instance reference; all built-in occurrence constructors currently leave it absent. `retryable` expresses whether retry can make sense, not whether a delay is known or automatically supplied.

`shomei-servant/src/Shomei/OAuth/Handler.hs` contains `oauthErrorFor` for client credentials and `exchangeErrorFor` for token exchange. Both map session-limit exhaustion to 503 `temporarily_unavailable`, with description `active session limit reached`. Token exchange maps both impersonation errors to 400 `invalid_grant` with the identical description `the subject or actor token is invalid`. This hides policy and target details. The shared OAuth renderer supplies JSON and cache-prevention headers, without adding a challenge for these failures.

`shomei-servant/test/Main.hs` runs real HTTP requests through the Servant application with in-memory storage. It already contains the test named “OAuth machine quota returns a retryable OAuth error after its last slot”, the `freshOAuthEnv` and `freshExchangeEnv` fixtures, `scenarioTokenExchange`, and `scenarioProblemEnvelope`. `maxActiveNonInteractiveSessions = 1` makes quota exhaustion deterministic. `shomei-servant/test-openapi/Main.hs` loads the Markdown catalog and already requires an explicit anchor for every `problemCatalog` entry, but does not check that catalog reachability or retry guidance is truthful.

Relevant durable context is [ADR-27](../adr/0027-oauth-namespaces-own-errors-through-the-http-boundary.md) (`docs/adr/0027-oauth-namespaces-own-errors-through-the-http-boundary.md`): OAuth namespaces own their error format through handlers and middleware; 429 throttling retains a 60-second retry header; authentication challenges depend on the failure rather than merely on its status. This plan preserves that decision. Related client guidance is in `docs/user/oidc.md`, `docs/user/machine-tokens.md`, and `docs/user/problem-details.md`. Existing packaged throttling coverage is in `integration-tests/oauth/throttling.hurl`.

## Plan of Work

### Milestone 1: Publish an accurate error contract

Edit `docs/user/problem-details.md` so the main table describes built-in application errors. Move the three unserved problem entries to a clearly titled library-only mappings section on the same page. Preserve their exact HTML anchors, titles, generic statuses and retryability values. Explain that built-in routes currently do not emit these problem documents, while an embedding application can explicitly render them. For the library session-limit mapping, state that the generic mapping supplies no `Retry-After`; a caller may supply an honest interval through `ProblemOccurrence`, but the specification itself supplies none.

Add a compact served-OAuth mapping table for machine-session quota, delegated-session quota, impersonation authority refusal, and invalid impersonation target. State the endpoint, HTTP status, OAuth error, and absence of `Retry-After` and `WWW-Authenticate` for these failures. Explain quota recovery by revoking an unused session or waiting for expiry, without promising a fixed delay or exposing the concealed impersonation reason. Distinguish this from rate limiting. Clarify in the introduction that `instance` is supported for embedders but omitted by built-in handlers; do not fabricate IDs or introduce request tracking.

Update the error-contract sections of `docs/user/oidc.md` and `docs/user/machine-tokens.md` to summarize quota behavior and link to the authoritative mapping. Correct misleading source comments in `shomei-servant/src/Shomei/Servant/Error.hs` if they imply every 429 always carries a retry interval. Retain the runtime mappings and exports. Acceptance is a reader being able to predict the four observed cases and distinguish the generic library mapping from served behavior, with all old anchors intact. The existing OpenAPI catalog-anchor test must still pass.

### Milestone 2: Keep the documentation tied to observable responses

Extend `shomei-servant/test/Main.hs` using the existing fixtures and HTTP request helpers. Strengthen the existing machine-quota case with header and body assertions. Add a fresh delegated-session quota case through token exchange with a one-session limit: a valid first exchange succeeds, then the next valid exchange in the same quota bucket fails. Construct this using the valid exchange requests in `scenarioTokenExchange`; use isolated fixture state so unrelated sessions cannot consume the quota first. Exercise impersonation authority and target refusals with otherwise valid requests that reach those workflow guards, rather than failing token parsing or client authentication earlier. Both responses must have the same safe description.

Assert JSON media type, cache prevention, expected status/error, absent problem fields, absent retry header, and absent authentication challenge in these cases. Extend an existing ordinary application problem HTTP case to assert that `instance` is absent. Add focused library serialization coverage in `shomei-servant/test-openapi/Main.hs`: the generic session-limit mapping has no retry header, an explicitly supplied safe instance URI is serialized, and an empty occurrence omits `instance`. Validate that populated occurrence against the published schema as well.

Extend the existing catalog-document checks to inspect the library-only table: all three codes must occur there with their generic statuses, and none may occur as an entry in the built-in application table. Preserve the all-anchors check. Check the served mapping table against the expected OAuth statuses/codes and retry-header absence, using a small table reader scoped to these sections rather than snapshotting the entire prose document. This makes reintroducing the original misleading table classification fail a test. Do not require literal wording of explanatory paragraphs.

Acceptance is that HTTP tests demonstrate every mapping above and the document checks fail if the original misleading classification or always-retry promise is restored. Review the Decision Log against ADR-27 at completion; update that ADR only if implementation introduces durable context not already captured there.

## Concrete Steps

Run commands from the repository root. The Nix development shell supplies the project toolchain. No running production server or database is required for these in-memory and schema suites.

```bash
cd /Users/shinzui/Keikaku/bokuno/shomei
nix develop --command cabal test shomei-servant:shomei-servant-test shomei-servant:shomei-servant-openapi-test --test-show-details=direct
```

Run this once as a baseline and again after the cohesive edits. Expect both suites to pass, including the new HTTP cases and documentation checks. Record actual counts and any failures in the living sections rather than inventing results. To prove the document guard, temporarily restore the old session-limit table classification and retry claim, run the OpenAPI test suite and observe its targeted failure, then restore the corrected document and rerun that suite.

```bash
nix develop --command cabal test shomei-servant:shomei-servant-openapi-test --test-show-details=direct
nix fmt -- --fail-on-change
git diff --check
```

If formatting fails, format the changed files using the configured formatter and rerun the check, retaining unrelated working-tree changes. No OpenAPI schema change is intended. If an implementation edit affects schema descriptions, regenerate using the existing generator and inspect the diff:

```bash
nix develop --command cabal run -v0 shomei-openapi > docs/api/openapi.json
```

Do not broaden into package releases, dependency updates, database migrations, or changes to OAuth status codes. Commits during implementation use Conventional Commits and these trailers:

```text
ExecPlan: docs/plans/75-align-the-public-error-catalog-with-served-oauth-responses.md
Intention: intention_01m7k4bchze6eayb21maev6pmn
```

## Validation and Acceptance

Machine and delegated quota tests each show an initial successful token issuance followed by HTTP 503 with `error=temporarily_unavailable`. Neither quota failure has `Retry-After`, `WWW-Authenticate`, or problem-document fields. Impersonation authority and target refusals each show HTTP 400 with `error=invalid_grant` and the same generic description, without disclosing the underlying guard. All four responses are JSON and include `Cache-Control: no-store` and `Pragma: no-cache`.

An ordinary built-in application error remains a problem document and omits `instance`. An embedding caller supplying a safe `instanceUri` still receives that value in serialization. All existing problem type anchors resolve within the catalog, and the three library-only mappings are explicitly outside the built-in application table. The documentation distinguishes quota exhaustion from the existing OAuth throttle response of 429 with `Retry-After: 60`; existing throttling coverage remains intact.

The documentation guard must detect the original catalog error, while the HTTP assertions protect compatibility. Passing compilation alone is insufficient. Record focused test and formatting results before marking the milestones complete.

## Idempotence and Recovery

The test suites use fresh in-memory state and can be rerun. These changes require no data migration. Restore only the deliberate temporary documentation mutation after the negative test, preserving other edits. Avoid broad resets and do not stop processes owned by other work. If the baseline fails for an unrelated reason, record the exact failure separately from this plan's acceptance evidence and address only prerequisites needed for the focused checks.

## Interfaces and Dependencies

Keep `ProblemSpec`, `ProblemOccurrence`, `problemCatalog`, and `authErrorToServerError` in `Shomei.Servant.Error` source-compatible. Keep `oauthErrorFor` and `exchangeErrorFor` in `Shomei.OAuth.Handler` behavior-compatible. Reuse the existing test fixtures, request helpers, and schema validator; no new dependencies or version choices are required. If implementation needs an unfamiliar dependency API, locate its source and documentation with Mori before using it. This is a standalone plan with no parent MasterPlan or prerequisite implementation milestone.
