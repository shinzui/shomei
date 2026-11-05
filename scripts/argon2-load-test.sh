#!/usr/bin/env sh
# Measure what concurrent logins do to the latency of the authenticated hot path.
#
# WHAT THIS MEASURES
#   Verifying a JWT is pure in-memory work: `GET /v1/auth/me` never touches the database and never
#   hashes anything. Logging in costs one Argon2id verification (~100 ms at the default
#   parameters), reached through an *unsafe* foreign call that pins its capability with no
#   garbage-collection safepoint. GHC's stop-the-world collector must synchronize every
#   capability, so a hash can stall requests that have nothing to do with passwords.
#
#   Measure `GET /v1/auth/me` while idle and under N login loops, and report the ratio.
#   Ratios/latencies are measurements, not a fixed SLO gate. Workload bounds and zero HTTP
#   errors are stable gates; the PostgreSQL hashing tests prove permit ownership and ceilings.
#
# WHAT THIS CANNOT MEASURE
#   The load generator runs on the same host as the server and forks a curl process per request.
#   On a busy box that contends with the server for cores, so the p95/p99 columns swing wildly
#   run to run (measured p99 degradation for one identical configuration: 20.9x, 34.2x, 62.5x).
#   Treat p50 and peak RSS as signal and the tail as indicative only. Resolving the tail needs a
#   separate load-generation machine and a connection-reusing client.
#
# NEVER POINT THIS AT PRODUCTION. It creates throwaway users and floods the login endpoint.
# `just create-database` re-creates a clean dev database at any time.
#
# THE SERVER MUST HAVE RATE LIMITING DISABLED, or the per-IP limiter throttles this workload.
# Current configuration accepts SHOMEI_RATE_LIMIT_ENABLED=false, or a completed Dhall file
# placed in the repository root:
#
#     let Shomei = ./config/shomei-types.dhall
#     in Shomei::{ rateLimitEnabled = Some False }
#
# Use an isolated database/server. The MasterPlan 9 driver provisions both automatically:
#     scripts/review-remediation-load.sh --scenario all --output /tmp/shomei-review-load.json
#
#   This script refuses to run if it detects throttling.
#
# USAGE
#     scripts/argon2-load-test.sh [BASE_URL]            # default http://localhost:8080
#
#   Environment:
#     LOAD_USERS=20      concurrent login loops
#     PROBE_COUNT=200    hot-path samples per phase
#     LOAD_SECONDS=20    duration of the load phase
#     SIGNUP_LOOPS=0     when positive, run this many concurrent signup loops instead of logins
#     SERVER_PID=        if set, peak RSS of that process is sampled once a second
#     LOAD_JSON_OUTPUT=  optional redacted aggregate JSON report path
set -eu

BASE="${1:-http://localhost:8080}"
LOAD_USERS="${LOAD_USERS:-20}"
PROBE_COUNT="${PROBE_COUNT:-200}"
LOAD_SECONDS="${LOAD_SECONDS:-20}"
SIGNUP_LOOPS="${SIGNUP_LOOPS:-0}"
SERVER_PID="${SERVER_PID:-}"
LOAD_JSON_OUTPUT="${LOAD_JSON_OUTPUT:-}"

# Refuse external targets, URL credentials and paths before making any request.
python3 - "$BASE" "$LOAD_USERS" "$PROBE_COUNT" "$LOAD_SECONDS" "$SIGNUP_LOOPS" <<'PYGUARD'
import sys
from urllib.parse import urlsplit
try:
    u=urlsplit(sys.argv[1])
    assert u.scheme in {"http","https"} and u.hostname in {"127.0.0.1","localhost","::1"}
    assert u.username is None and u.password is None and u.path in {"","/"} and not u.query and not u.fragment
    assert u.port is None or 0 < u.port <= 65535
    for raw,lo,hi in zip(sys.argv[2:],[1,1,1,0],[32,2000,60,16]):
        assert raw.isdecimal() and lo <= int(raw) <= hi
except (AssertionError,ValueError):
    sys.exit("load test requires a loopback origin and finite bounded workload settings")
PYGUARD
BASE="${BASE%/}"
# No inherited outbound proxy, redirect following, or indefinitely blocked curl.
curl() { command curl --noproxy '*' --connect-timeout 2 --max-time 5 "$@"; }


# Long, unique, and not in the common-password dictionary; signup rejects weak passwords.
PASSWORD='Tr0ub4dor-Zx9-Quibble-Vex'
RUN="lt$(date +%s)$$"

work="$(mktemp -d)"
# Track only the children this script forks. `kill 0` would signal the whole process group,
# which includes whatever invoked this script.
children=""
# shellcheck disable=SC2064
trap 'rm -rf "$work"; if [ -n "$children" ]; then kill $children 2>/dev/null || true; fi' EXIT

say() { printf '%s\n' "$*" >&2; }

# --- preflight ---------------------------------------------------------------

curl -sf -o /dev/null "$BASE/health/live" ||
  { say "error: no server answering at $BASE/health/live"; exit 1; }

# The limiter's burst is 60 by default, so 70 rapid requests will trip it if it is enabled.
throttled=0
i=0
while [ "$i" -lt 70 ]; do
  code="$(curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE/v1/auth/login" \
    -H 'Content-Type: application/json' \
    -d '{"loginId":"argon2-rate-limit-probe","password":"invalid-password"}')"
  [ "$code" = "429" ] && throttled=1 && break
  [ "$code" = "401" ] || { say "error: unexpected preflight authentication response"; exit 1; }
  i=$((i + 1))
done
if [ "$throttled" -eq 1 ]; then
  say "error: the server is rate limiting this client (HTTP 429)."
  say "       Restart it with rate limiting disabled; see the header of this script."
  exit 1
fi

# --- helpers -----------------------------------------------------------------

signup() {
  curl -sf -o /dev/null -X POST "$BASE/v1/auth/signup" \
    -H 'Content-Type: application/json' \
    -d "{\"loginId\":\"$1\",\"email\":\"$1\",\"password\":\"$PASSWORD\",\"displayName\":\"loadtest\"}"
}

# Print the accessToken from a login response.
login_token() {
  curl -sf -X POST "$BASE/v1/auth/login" \
    -H 'Content-Type: application/json' \
    -d "{\"loginId\":\"$1\",\"password\":\"$PASSWORD\"}" |
    sed -n 's/.*"accessToken":"\([^"]*\)".*/\1/p'
}

# PROBE_COUNT sequential hot-path requests; one `time_total` (seconds) per line into $1.
probe() {
  out="$1"
  : >"$out"
  errors=0
  n=0
  while [ "$n" -lt "$PROBE_COUNT" ]; do
    measurement="$(curl -s -o /dev/null -w '%{http_code} %{time_total}' \
      -H "Authorization: Bearer $TOKEN" "$BASE/v1/auth/me" || true)"
    code="${measurement%% *}"
    elapsed="${measurement#* }"
    [ "$code" = "200" ] || errors=$((errors + 1))
    printf '%s\n' "$elapsed" >>"$out"
    n=$((n + 1))
  done
  printf '%s\n' "$errors" >"$out.errors"
}

# pctile <file> <percentile> -> milliseconds, 2dp
pctile() {
  sort -n "$1" | awk -v p="$2" '
    { a[n++] = $1 }
    END {
      if (n == 0) { print "n/a"; exit }
      idx = int(p / 100 * n); if (idx >= n) idx = n - 1
      printf "%.2f", a[idx] * 1000
    }'
}

ratio() { awk -v a="$1" -v b="$2" 'BEGIN { if (b == 0) print "n/a"; else printf "%.2fx", a / b }'; }

# --- set up users ------------------------------------------------------------

if [ "$SIGNUP_LOOPS" -gt 0 ]; then
  say "creating 1 probe user; signup load will use $SIGNUP_LOOPS concurrent loops..."
else
  say "creating 1 probe user and $LOAD_USERS load users..."
fi
signup "probe-$RUN@example.test"
if [ "$SIGNUP_LOOPS" -eq 0 ]; then
  u=0
  while [ "$u" -lt "$LOAD_USERS" ]; do
    signup "load-$u-$RUN@example.test"
    u=$((u + 1))
  done
fi

TOKEN="$(login_token "probe-$RUN@example.test")"
[ -n "$TOKEN" ] || { say "error: could not obtain an access token"; exit 1; }
curl -sf -o /dev/null -H "Authorization: Bearer $TOKEN" "$BASE/v1/auth/me" ||
  { say "error: the access token does not authenticate against /v1/auth/me"; exit 1; }

# --- idle phase --------------------------------------------------------------

say "idle phase: $PROBE_COUNT hot-path requests, no load..."
probe "$work/idle"

# --- load phase --------------------------------------------------------------

deadline=$(($(date +%s) + LOAD_SECONDS))
if [ "$SIGNUP_LOOPS" -gt 0 ]; then
  say "load phase: $SIGNUP_LOOPS signup loops for ${LOAD_SECONDS}s, measuring the hot path..."
  u=0
  while [ "$u" -lt "$SIGNUP_LOOPS" ]; do
    (
      count=0
      unavailable=0
      errors=0
      while [ "$(date +%s)" -lt "$deadline" ]; do
        code="$(curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE/v1/auth/signup" \
          -H 'Content-Type: application/json' \
          -d "{\"loginId\":\"signup-$u-$count-$RUN@example.test\",\"email\":\"signup-$u-$count-$RUN@example.test\",\"password\":\"$PASSWORD\",\"displayName\":\"loadtest\"}" || true)"
        [ "$code" = "503" ] && unavailable=$((unavailable + 1))
        [ "$code" = "201" ] || errors=$((errors + 1))
        count=$((count + 1))
      done
      printf '%s\n' "$count" >"$work/signups.$u"
      printf '%s\n' "$unavailable" >"$work/signup-503s.$u"
      printf '%s\n' "$errors" >"$work/signup-errors.$u"
    ) &
    children="$children $!"
    u=$((u + 1))
  done
else
  say "load phase: $LOAD_USERS login loops for ${LOAD_SECONDS}s, measuring the hot path..."
  u=0
  while [ "$u" -lt "$LOAD_USERS" ]; do
    (
      count=0
      errors=0
      while [ "$(date +%s)" -lt "$deadline" ]; do
        code="$(curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE/v1/auth/login" \
          -H 'Content-Type: application/json' \
          -d "{\"loginId\":\"load-$u-$RUN@example.test\",\"password\":\"$PASSWORD\"}" || true)"
        [ "$code" = "200" ] || errors=$((errors + 1))
        count=$((count + 1))
      done
      printf '%s\n' "$count" >"$work/logins.$u"
      printf '%s\n' "$errors" >"$work/login-errors.$u"
    ) &
    children="$children $!"
    u=$((u + 1))
  done
fi

# Sample the server's resident set while it is under load.
if [ -n "$SERVER_PID" ]; then
  (
    peak=0
    while [ "$(date +%s)" -lt "$deadline" ]; do
      rss="$(ps -o rss= -p "$SERVER_PID" 2>/dev/null | tr -d ' ')"
      [ -n "$rss" ] && [ "$rss" -gt "$peak" ] && peak="$rss"
      sleep 1
    done
    printf '%s\n' "$peak" >"$work/rss"
  ) &
  children="$children $!"
fi

probe "$work/loaded"
wait
children=""

logins=0
for f in "$work"/logins.*; do
  [ -f "$f" ] && logins=$((logins + $(sed -n '1p' "$f")))
done
signups=0
for f in "$work"/signups.*; do
  [ -f "$f" ] && signups=$((signups + $(sed -n '1p' "$f")))
done
signup_503s=0
for f in "$work"/signup-503s.*; do
  [ -f "$f" ] && signup_503s=$((signup_503s + $(sed -n '1p' "$f")))
done
login_throughput="$(awk -v n="$logins" -v s="$LOAD_SECONDS" 'BEGIN { printf "%.1f", n / s }')"
signup_throughput="$(awk -v n="$signups" -v s="$LOAD_SECONDS" 'BEGIN { printf "%.1f", n / s }')"

peak_rss="n/a"
if [ -f "$work/rss" ]; then
  peak_rss="$(awk '{ printf "%.0fMB", $1 / 1024 }' "$work/rss")"
fi

# --- report ------------------------------------------------------------------

i50="$(pctile "$work/idle" 50)"; i95="$(pctile "$work/idle" 95)"; i99="$(pctile "$work/idle" 99)"
l50="$(pctile "$work/loaded" 50)"; l95="$(pctile "$work/loaded" 95)"; l99="$(pctile "$work/loaded" 99)"

printf 'idle    p50=%sms  p95=%sms  p99=%sms\n' "$i50" "$i95" "$i99"
printf 'loaded  p50=%sms  p95=%sms  p99=%sms\n' "$l50" "$l95" "$l99"
printf 'degradation p50=%s p95=%s p99=%s   logins/s=%s   signups/s=%s   signup_503s=%s   peak_rss=%s\n' \
  "$(ratio "$l50" "$i50")" "$(ratio "$l95" "$i95")" "$(ratio "$l99" "$i99")" \
  "$login_throughput" "$signup_throughput" "$signup_503s" "$peak_rss"


errors=$(($(cat "$work/idle.errors") + $(cat "$work/loaded.errors")))
for f in "$work"/login-errors.* "$work"/signup-errors.*; do
  [ -f "$f" ] && errors=$((errors + $(cat "$f")))
done
printf 'error_count=%s\n' "$errors"
if [ -n "$LOAD_JSON_OUTPUT" ]; then
  rss_kib=null
  [ ! -f "$work/rss" ] || rss_kib="$(cat "$work/rss")"
  printf '{"expected_preflight_401s":70,"probe_count":%s,"login_workers":%s,"signup_workers":%s,"load_seconds":%s,"login_attempts":%s,"signup_attempts":%s,"error_count":%s,"peak_rss_kib":%s,"idle_p50_ms":%s,"idle_p95_ms":%s,"idle_p99_ms":%s,"loaded_p50_ms":%s,"loaded_p95_ms":%s,"loaded_p99_ms":%s}\n' \
    "$PROBE_COUNT" "$LOAD_USERS" "$SIGNUP_LOOPS" "$LOAD_SECONDS" "$logins" "$signups" "$errors" "$rss_kib" "$i50" "$i95" "$i99" "$l50" "$l95" "$l99" >"$LOAD_JSON_OUTPUT"
fi
[ "$errors" -eq 0 ]
