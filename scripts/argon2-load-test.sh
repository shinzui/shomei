#!/usr/bin/env sh
# Measure what concurrent logins do to the latency of the authenticated hot path.
#
# WHAT THIS MEASURES
#   Verifying a JWT is pure in-memory work: `GET /auth/me` never touches the database and never
#   hashes anything. Logging in costs one Argon2id verification (~100 ms at the default
#   parameters), reached through an *unsafe* foreign call that pins its capability with no
#   garbage-collection safepoint. GHC's stop-the-world collector must synchronize every
#   capability, so a hash can stall requests that have nothing to do with passwords.
#
#   So: measure `GET /auth/me` latency while idle, then again while N clients hammer
#   `POST /auth/login`, and report the ratio. The ratio is the acceptance criterion, not the
#   absolute milliseconds -- those vary wildly by machine.
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
# THE SERVER MUST HAVE RATE LIMITING DISABLED, or the per-IP limiter (60 req/min by default)
# throttles the load generator and the numbers are meaningless. There is no environment variable
# for this, so use a Dhall file:
#
#     printf '{ rateLimitEnabled = False }\n' > /tmp/loadtest.dhall
#     SHOMEI_CONFIG=/tmp/loadtest.dhall \
#     PG_CONNECTION_STRING="host=$PGHOST dbname=$PGDATABASE user=$(id -un)" \
#       cabal run shomei-server:exe:shomei-server
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
#     SERVER_PID=        if set, peak RSS of that process is sampled once a second
set -eu

BASE="${1:-http://localhost:8080}"
LOAD_USERS="${LOAD_USERS:-20}"
PROBE_COUNT="${PROBE_COUNT:-200}"
LOAD_SECONDS="${LOAD_SECONDS:-20}"
SERVER_PID="${SERVER_PID:-}"

# Long, unique, and not in the common-password dictionary; signup rejects weak passwords.
PASSWORD='Tr0ub4dor-Zx9-Quibble-Vex'
RUN="lt$(date +%s)$$"

work="$(mktemp -d)"
# Track only the children this script forks. `kill 0` would signal the whole process group,
# which includes whatever invoked this script.
children=""
# shellcheck disable=SC2064
trap 'rm -rf "$work"; [ -n "$children" ] && kill $children 2>/dev/null; true' EXIT

say() { printf '%s\n' "$*" >&2; }

# --- preflight ---------------------------------------------------------------

curl -sf -o /dev/null "$BASE/health" ||
  { say "error: no server answering at $BASE/health"; exit 1; }

# The limiter's burst is 60 by default, so 70 rapid requests will trip it if it is enabled.
throttled=0
i=0
while [ "$i" -lt 70 ]; do
  code="$(curl -s -o /dev/null -w '%{http_code}' "$BASE/health")"
  [ "$code" = "429" ] && throttled=1 && break
  i=$((i + 1))
done
if [ "$throttled" -eq 1 ]; then
  say "error: the server is rate limiting this client (HTTP 429)."
  say "       Restart it with rate limiting disabled; see the header of this script."
  exit 1
fi

# --- helpers -----------------------------------------------------------------

signup() {
  curl -sf -o /dev/null -X POST "$BASE/auth/signup" \
    -H 'Content-Type: application/json' \
    -d "{\"email\":\"$1\",\"password\":\"$PASSWORD\",\"displayName\":\"loadtest\"}"
}

# Print the accessToken from a login response.
login_token() {
  curl -sf -X POST "$BASE/auth/login" \
    -H 'Content-Type: application/json' \
    -d "{\"email\":\"$1\",\"password\":\"$PASSWORD\"}" |
    sed -n 's/.*"accessToken":"\([^"]*\)".*/\1/p'
}

# PROBE_COUNT sequential hot-path requests; one `time_total` (seconds) per line into $1.
probe() {
  out="$1"
  : >"$out"
  n=0
  while [ "$n" -lt "$PROBE_COUNT" ]; do
    curl -s -o /dev/null -w '%{time_total}\n' \
      -H "Authorization: Bearer $TOKEN" "$BASE/auth/me" >>"$out"
    n=$((n + 1))
  done
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

say "creating 1 probe user and $LOAD_USERS load users..."
signup "probe-$RUN@example.test"
u=0
while [ "$u" -lt "$LOAD_USERS" ]; do
  signup "load-$u-$RUN@example.test"
  u=$((u + 1))
done

TOKEN="$(login_token "probe-$RUN@example.test")"
[ -n "$TOKEN" ] || { say "error: could not obtain an access token"; exit 1; }
curl -sf -o /dev/null -H "Authorization: Bearer $TOKEN" "$BASE/auth/me" ||
  { say "error: the access token does not authenticate against /auth/me"; exit 1; }

# --- idle phase --------------------------------------------------------------

say "idle phase: $PROBE_COUNT hot-path requests, no load..."
probe "$work/idle"

# --- load phase --------------------------------------------------------------

say "load phase: $LOAD_USERS login loops for ${LOAD_SECONDS}s, measuring the hot path..."

deadline=$(($(date +%s) + LOAD_SECONDS))
u=0
while [ "$u" -lt "$LOAD_USERS" ]; do
  (
    count=0
    while [ "$(date +%s)" -lt "$deadline" ]; do
      curl -s -o /dev/null -X POST "$BASE/auth/login" \
        -H 'Content-Type: application/json' \
        -d "{\"email\":\"load-$u-$RUN@example.test\",\"password\":\"$PASSWORD\"}" || true
      count=$((count + 1))
    done
    printf '%s\n' "$count" >"$work/logins.$u"
  ) &
  children="$children $!"
  u=$((u + 1))
done

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

logins=0
for f in "$work"/logins.*; do
  [ -f "$f" ] && logins=$((logins + $(cat "$f")))
done
throughput="$(awk -v n="$logins" -v s="$LOAD_SECONDS" 'BEGIN { printf "%.1f", n / s }')"

peak_rss="n/a"
if [ -f "$work/rss" ]; then
  peak_rss="$(awk '{ printf "%.0fMB", $1 / 1024 }' "$work/rss")"
fi

# --- report ------------------------------------------------------------------

i50="$(pctile "$work/idle" 50)"; i95="$(pctile "$work/idle" 95)"; i99="$(pctile "$work/idle" 99)"
l50="$(pctile "$work/loaded" 50)"; l95="$(pctile "$work/loaded" 95)"; l99="$(pctile "$work/loaded" 99)"

printf 'idle    p50=%sms  p95=%sms  p99=%sms\n' "$i50" "$i95" "$i99"
printf 'loaded  p50=%sms  p95=%sms  p99=%sms\n' "$l50" "$l95" "$l99"
printf 'degradation p50=%s p95=%s p99=%s   logins/s=%s   peak_rss=%s\n' \
  "$(ratio "$l50" "$i50")" "$(ratio "$l95" "$i95")" "$(ratio "$l99" "$i99")" \
  "$throughput" "$peak_rss"
