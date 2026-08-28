# Bundle Update Log

## 2026-08-28
* **Addition**: ADR-18 makes downstream JWKS transport, cache freshness, and unknown-key refresh a bounded local policy.
* **Addition**: ADR-17 requires embedded hosts to install the complete background-service and whole-application middleware contract, including bounded cleanup.

## 2026-08-27
* **Addition**: ADR-16 uses browser-enforced \_\_Host- and \_\_Secure- cookie names for secure transport while preserving bare names when Secure is disabled.
* **Addition**: ADR-15 requires an explicit trusted proxy before forwarded client identity is accepted and selects the rightmost untrusted X-Forwarded-For hop.
* **Addition**: ADR-12 binds every notification webhook signature to a fresh attempt timestamp and documents a five-minute receiver replay window.
* **Addition**: ADR-11 moves notifier credentials out of printable configuration into non-printable runtime types and makes secure transport posture the boot default.
* **Addition**: ADR-10 moves built-in notification delivery behind a bounded in-memory queue with explicit overflow and a timed shutdown drain.
* **Addition**: ADR-9 maps outbound transport failures to a closed reason vocabulary so exception text containing payloads or URLs is never logged or persisted.
* **Addition**: ADR-8 makes runtime configuration extensible through Dhall record completion, rejects unknown keys, and mechanically synchronizes schema fields with the loader.
* **Addition**: ADR-7 makes single-use and monotonic security transitions conditional writes and uses transaction-scoped advisory locks where serialization must enclose a read.
* **Addition**: ADR-6 makes session-backed auth\_time, rather than token iat, the clock for recent-credential gates and requires refresh to preserve it.
* **Addition**: ADR-5 puts every credential proof under one account abuse budget and derives the edge-throttled operation set from API markers.
* **Addition**: ADR-4 makes one active signing key a PostgreSQL invariant and requires atomic replacement with lifecycle timestamps.
* **Addition**: ADR-3 makes JWT verification an explicit strict trust boundary with pinned algorithms, kid selection, strict claims, token typing, and bounded skew.
* **Addition**: ADR-2 reserves Shomei privilege scopes for service-account authority and refuses them on OAuth clients.
* **Addition**: ADR-1 records session provenance and establishes that only a live interactive
session may authorize an OAuth client.
