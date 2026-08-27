---
type: Architecture Decision Record
title: Forwarded client identity requires an explicit trusted proxy
description: Shomei trusts forwarded client addresses only from configured proxy CIDRs and selects the rightmost untrusted X-Forwarded-For hop.
docId: ADR-15
status: Accepted
date: 2026-08-27
timestamp: 2026-08-27T22:48:18Z
originatingPlan: docs/plans/58-proxy-aware-wai-edge-trusted-forwarded-headers-metered-bodies-and-bounded-metrics.md
generated:
  by: openai-codex/gpt-5
  at: 2026-08-27T22:48:18Z
---

# Forwarded client identity requires an explicit trusted proxy

## Context

The standalone server normally runs behind a TLS-terminating reverse proxy. Without a forwarding
policy, WAI's `remoteHost` is that proxy for every request, so the request bucket, account-failure
budget, audit events, and request logs collapse every user onto one address. Blindly trusting a
forwarded header is worse: a client that can reach warp directly can choose its own address and
evade or redirect those controls.

An `X-Forwarded-For` chain may also contain attacker-supplied entries to the left of the address
appended by the deployment's first trusted proxy. Correct resolution therefore depends on both
the immediate peer and the direction in which the chain is examined.

## Decision

The trusted-proxy list defaults to empty. Only a socket peer within an explicitly configured IPv4
or IPv6 CIDR may supply client identity through `X-Forwarded-For`. Shōmei walks the chain from the
right and chooses the first address not in the trusted set; if every hop is trusted, it uses the
leftmost origin. It ignores `Forwarded` and `X-Real-IP`, so the accepted input is exactly the header
operators configure their proxies to append.

The outermost WAI middleware rewrites `remoteHost` to that resolved address. Existing logging,
rate-limiting, audit, and Servant `RemoteHost` consumers consequently share one canonical identity
without a second request-vault lookup. The rewritten source port is zero because no policy may key
on an ephemeral client port.

Warp's PROXY protocol v1 is separately available in `required` mode. Optional mode is deliberately
excluded because accepting direct HTTP and a claimed PROXY header on the same listener enables
address spoofing.

## Consequences

Deployments behind a reverse proxy must list its exact addresses or networks; the fail-closed
default preserves the socket peer and makes a missing setting operationally visible as a shared
bucket. A mistakenly broad trusted range can make an untrusted neighbor authoritative, so the
deployment guide recommends the narrowest CIDRs.

Every downstream consumer reads the same dotted-quad or RFC 5952 address. New WAI middleware that
uses client identity must run inside the trusted-proxy rewrite or use the already rewritten
`remoteHost`. A PROXY-protocol listener requires every connection, including probes, to speak v1.

## Alternatives rejected

Trusting private ranges by default was rejected because container neighbors are not inherently
trusted. A request-vault value was rejected because all existing Servant and WAI readers would need
parallel lookup rules. Leftmost-header selection was rejected because a client can prepend values.
Supporting several forwarding headers was rejected because unset headers remain attacker input.
