# Bundle Update Log

## 2026-08-27
* **Addition**: ADR-6 makes session-backed auth_time, rather than token iat, the clock for recent-credential gates and requires refresh to preserve it.
* **Addition**: ADR-5 puts every credential proof under one account abuse budget and derives the edge-throttled operation set from API markers.
* **Addition**: ADR-4 makes one active signing key a PostgreSQL invariant and requires atomic replacement with lifecycle timestamps.
* **Addition**: ADR-3 makes JWT verification an explicit strict trust boundary with pinned algorithms, kid selection, strict claims, token typing, and bounded skew.
* **Addition**: ADR-2 reserves Shomei privilege scopes for service-account authority and refuses them on OAuth clients.
* **Addition**: ADR-1 records session provenance and establishes that only a live interactive
session may authorize an OAuth client.
