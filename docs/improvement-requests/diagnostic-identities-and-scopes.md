---
type: Improvement Request
title: Add diagnostic broker and probe identities and coarse scopes to Shomei
description: Authenticate diagnostic protocol participants and bound broker and per-cluster probe capabilities.
timestamp: "2026-07-30T01:01:00Z"
generated:
  by: human:nadeem
  at: "2026-07-30T01:01:00Z"
requestId: IR-2
status: proposed
origin: mori://shinzui/kikan
---

# Improvement Request: add diagnostic broker/probe identities and coarse scopes to Shomei

**Authored by:** `shinzui/kikan` agents while validating
`mori://shinzui/kikan/okf/use-cases/concepts/UC-5`.
**Addressed to:** `shinzui/shomei` agents and Kikan's C11 trust-boundary owners.
**Status:** proposed; required before the broker accepts requests or a probe session.
**Contracts:** C11, C13, and the proposed cross-cluster diagnostics contract.
**Created:** 2026-07-24.


## Why

C11 currently names the Shikigami runtime and declared agents and closes its worked coarse-scope
vocabulary around `kawa:ingest` and `signal:raise`. Use case 005 introduces two new verification
boundaries:

- a Shikigami agent asks the diagnostic broker to send a read request to production;
- a production probe connects to the broker and returns evidence for one registered cluster.

Kikan-En decides whether an agent may read one exact observability target. Shomei still needs to
authenticate every service hop and answer whether a principal may participate in the diagnostic
protocol at all. The design must not reuse a human browser session, a generic Shikigami service
token, or one indistinguishable probe identity for every cluster.


## Requested identities

Adopt stable login ids:

```text
service:shinzui/shikigami-diagnostic-broker
service:shinzui/shikigami-diagnostic-probe/<cluster-id>
agent:<declared-agent-name>
```

Each probe deployment gets a distinct Shomei subject and login id bound to one registered cluster id.
Moving a credential to another cluster must not silently change that binding. The broker records both
the verified Shomei subject and resolved login id.

If C11 prefers another deployment-instance identity form, ratify it once and use it consistently in
the diagnostic contract, Nagare profile, audit records, and Kikan-En decision-proof audiences.


## Requested coarse scopes

Add:

| Scope | Bearer may |
|---|---|
| `diagnostics:read` | ask Shikigami to authorize and enqueue a typed read-only diagnostic operation |
| `diagnostics:broker` | serve the diagnostic request/result protocol as the one trusted Kikan broker |
| `diagnostics:probe` | establish a probe session and retrieve/return requests for the token's bound cluster |

These scopes admit the principal to a class of action. They do not select a cluster, namespace,
service, operation, incident, or query bound. Kikan-En and the forwarded decision proof provide that
object-level authority.

A token with `diagnostics:probe` cannot enqueue requests, and a token with `diagnostics:read` cannot
register as a probe or submit a result.


## Issuance and lifecycle

Use Shomei's scoped service-token issuance seam with:

- short token lifetime and automated rotation;
- exact audience for the Shikigami or broker endpoint;
- issuer, audience, expiry, and subject verification at every hop;
- no token material in Dhall, Kubernetes manifests, logs, evidence bundles, or workflow journals;
- a bootstrap mechanism that exchanges a one-time or externally provisioned credential for the
  first short-lived probe token;
- immediate disable/revocation procedure for a compromised probe identity;
- separate credentials and subjects for broker and each probe deployment.

Kubernetes projected ServiceAccount tokens authenticate the probe to the local Kubernetes API only.
They are not Shomei identities and must never be forwarded to Kikan.


## Verification behavior

The broker must verify:

1. its own serving identity/configuration at startup;
2. `diagnostics:read` on the authenticated Shikigami/agent request path before accepting an En proof;
3. `diagnostics:probe` and the expected cluster-bound probe login id before opening a probe session;
4. audience, issuer, signature, subject, and expiry for every new or resumed session.

The probe authenticates the broker endpoint through TLS and verifies any application-level broker
identity required by the final protocol. A probe must not send an evidence bundle to an endpoint
whose broker identity or audience does not match its configuration.


## Conformance request

Extend the C11 proof with:

- valid broker, one probe, and one declared-agent identity;
- verified identity with an empty scope denied from the diagnostic path;
- agent token with `diagnostics:read` admitted to the coarse gate but still denied by Kikan-En for an
  ungranted target;
- probe token admitted only for its bound cluster;
- a second cluster's probe token denied on the first cluster's session;
- `diagnostics:read` denied from probe registration and result submission;
- `diagnostics:probe` denied from request enqueue;
- expired, wrong-audience, wrong-issuer, and disabled identities rejected;
- token and credential strings absent from captured audit and evidence fixtures.


## Acceptance

The end-to-end fixture can attribute an allowed operation to:

```text
agent:checkout-api-steward
service:shinzui/shikigami-diagnostic-broker
service:shinzui/shikigami-diagnostic-probe/prod-us-west1
```

Changing the probe to another cluster identity, removing any required scope, or expiring a token
prevents execution before a local backend is called. Passing the Shomei gate alone never bypasses the
Kikan-En object check.


## Non-goals

This request does not put target-level permissions in Shomei, turn an alert label into identity, use
Kubernetes tokens outside the cluster, or define the En Biscuit contents. It supplies identity and
coarse protocol admission; C13 remains the exact-action gate.
