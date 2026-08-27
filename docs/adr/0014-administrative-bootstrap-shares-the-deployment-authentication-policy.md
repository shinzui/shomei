---
type: Architecture Decision Record
title: Administrative bootstrap shares the deployment authentication policy
description: Bootstrap users enter passwords outside argv and pass through the same configured validation and breach checks as HTTP signups.
docId: ADR-14
status: Accepted
date: 2026-08-27
timestamp: 2026-08-27T22:23:41Z
originatingPlan: docs/plans/57-notifier-and-log-hygiene-no-token-or-secret-reaches-a-log-audit-row-or-config-dump.md
generated:
  by: openai-codex/gpt-5
  at: 2026-08-27T22:23:41Z
---

# Administrative bootstrap shares the deployment authentication policy

## Context

The administrative user-creation command previously accepted a plaintext password on the command
line, where process listings and shell history could expose it. It also assembled a partial default
configuration and replaced the password-breach checker with a permissive interpreter. A bootstrap
account could therefore receive a password that the same deployment's HTTP signup path would reject.

Operators also need to seed an administrator whose email address was verified out of band, without
silently granting that status to every user created through the command.

## Decision

`shomei-admin users create` reads its password from standard input or an explicit password file,
never an argument value. Interactive standard input is prompted with echo disabled. The command
removes one trailing line ending and rejects an empty result.

Administrative signup loads the deployment's core Dhall configuration and environment overlays and
runs the same password-policy workflow and HIBP interpreter as the standalone server. Server-only
connection and listen validation remain outside this core loader. The optional `--email-verified`
flag is an explicit assertion that the operator verified the address out of band; without it the
normal unverified state is retained.

## Consequences

Automation must pipe the password or mount a suitably protected one-line file. Existing invocations
using `--password` fail argument parsing and require migration. User creation can now fail closed when
the configured breach service is unavailable, exactly as configured for HTTP signup, and may perform
an outbound HIBP range request.

The CLI and server cannot drift on password length, common or contextual password rejection, breach
behavior, or default roles. Operators remain responsible for protecting password files and for using
`--email-verified` only after an out-of-band proof.

## Alternatives rejected

Reading a password from an environment variable was rejected because process environments are often
captured by diagnostics and orchestration metadata. Keeping a separate CLI policy was rejected because
bootstrap accounts are not exempt from the deployment's authentication boundary. Marking every
bootstrap email verified was rejected because creating an account is not itself proof of address
control.
