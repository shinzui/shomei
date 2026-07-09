#!/usr/bin/env sh
# Tests deploy/entrypoint.sh's container-aware GHCRTS defaulting, without Docker.
#
# The entrypoint's CPU detection is the part that can silently be wrong: cgroup v1 and v2 spell
# the quota differently, "unlimited" has two spellings, and the quota-to-capability conversion
# must round UP (a 1.5-CPU quota deserves 2 capabilities, not 1). All of that is arithmetic over
# two files, so it is testable by pointing SHOMEI_CGROUP_ROOT at fixtures and stubbing the
# binaries the entrypoint execs.
#
# Run:  sh deploy/entrypoint-test.sh
# Exits non-zero on the first failure.
set -eu

here="$(cd "$(dirname "$0")" && pwd)"
entrypoint="$here/entrypoint.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# Stubs for everything the entrypoint calls. `shomei-server` prints the GHCRTS it inherited,
# which is what we assert on.
mkdir -p "$tmp/bin"
cat >"$tmp/bin/shomei-admin" <<'STUB'
#!/usr/bin/env sh
case "$1 ${2:-}" in
  "keys list") echo "kid=abc KeyActive" ;;
  *) : ;;
esac
STUB
# Prints the RTS arguments it was exec'd with, and whether GHCRTS leaked into its environment.
# GHCRTS must stay unset: it would be inherited by dhall-to-json, which the server shells out to
# and which is built without -threaded/-rtsopts, so `-N4` kills it and the server cannot boot.
cat >"$tmp/bin/shomei-server" <<'STUB'
#!/usr/bin/env sh
echo "args=[$*] GHCRTS=${GHCRTS:-<unset>}"
STUB
chmod +x "$tmp/bin/shomei-admin" "$tmp/bin/shomei-server"

# nproc may not exist (macOS); the entrypoint falls back through it, so give it a known answer.
cat >"$tmp/bin/nproc" <<'STUB'
#!/usr/bin/env sh
echo 7
STUB
chmod +x "$tmp/bin/nproc"

failures=0

expect() {
  name="$1"
  want="$2"
  got="$3"
  if [ "$got" = "$want" ]; then
    echo "ok   - $name"
  else
    echo "FAIL - $name"
    echo "         want: $want"
    echo "         got:  $got"
    failures=$((failures + 1))
  fi
}

# quota_case <name> <cgroup-root> <expected -N value>
# A quota was found: capabilities are bounded, so the enlarged nursery is affordable.
quota_case() {
  got="$(PATH="$tmp/bin:$PATH" SHOMEI_CGROUP_ROOT="$2" sh "$entrypoint" | tail -1)"
  expect "$1" "args=[+RTS -N$3 -A64m --nonmoving-gc -RTS] GHCRTS=<unset>" "$got"
}

# no_quota_case <name> <cgroup-root> <expected -N value>
# No quota: -N follows the host's processor count, so a 64 MiB per-capability nursery would cost
# 64 MiB x N. Measured at 230 MB -> 956 MB RSS on a 10-core host for no reproducible latency win.
no_quota_case() {
  got="$(PATH="$tmp/bin:$PATH" SHOMEI_CGROUP_ROOT="$2" sh "$entrypoint" | tail -1)"
  expect "$1" "args=[+RTS -N$3 --nonmoving-gc -RTS] GHCRTS=<unset>" "$got"
}

# cgroup v2, 2-CPU quota: docker run --cpus=2 writes "200000 100000".
v2="$tmp/v2"
mkdir -p "$v2"
echo "200000 100000" >"$v2/cpu.max"
quota_case "cgroup v2, --cpus=2" "$v2" 2

# cgroup v2, fractional quota must round up (1.5 CPUs -> 2 capabilities).
v2f="$tmp/v2f"
mkdir -p "$v2f"
echo "150000 100000" >"$v2f/cpu.max"
quota_case "cgroup v2, --cpus=1.5 rounds up" "$v2f" 2

# cgroup v2, sub-1 quota must still yield at least one capability.
v2s="$tmp/v2s"
mkdir -p "$v2s"
echo "50000 100000" >"$v2s/cpu.max"
quota_case "cgroup v2, --cpus=0.5 floors at 1" "$v2s" 1

# cgroup v2, unlimited: fall back to the visible processor count (our nproc stub says 7).
v2m="$tmp/v2max"
mkdir -p "$v2m"
echo "max 100000" >"$v2m/cpu.max"
no_quota_case "cgroup v2, unlimited falls back to nproc, no -A" "$v2m" 7

# cgroup v1, 3-CPU quota.
v1="$tmp/v1"
mkdir -p "$v1/cpu"
echo "300000" >"$v1/cpu/cpu.cfs_quota_us"
echo "100000" >"$v1/cpu/cpu.cfs_period_us"
quota_case "cgroup v1, 3-CPU quota" "$v1" 3

# cgroup v1, unlimited is spelled -1.
v1u="$tmp/v1u"
mkdir -p "$v1u/cpu"
echo "-1" >"$v1u/cpu/cpu.cfs_quota_us"
echo "100000" >"$v1u/cpu/cpu.cfs_period_us"
no_quota_case "cgroup v1, unlimited (-1) falls back to nproc, no -A" "$v1u" 7

# No cgroup files at all (bare metal).
bare="$tmp/bare"
mkdir -p "$bare"
no_quota_case "no cgroup falls back to nproc, no -A" "$bare" 7

# THE REGRESSION THIS GUARDS: the RTS options must never be exported as GHCRTS. GHCRTS is
# inherited by every GHC program, and shomei-server shells out to dhall-to-json, which is built
# without -threaded/-rtsopts and exits 1 on `-N4`. The server would then fail to boot with a
# Dhall config. Asserting GHCRTS=<unset> above and here is what keeps that from coming back.
got="$(PATH="$tmp/bin:$PATH" SHOMEI_CGROUP_ROOT="$v2" sh "$entrypoint" | tail -1)"
case "$got" in
  *"GHCRTS=<unset>"*) echo "ok   - RTS options are not exported into the environment" ;;
  *)
    echo "FAIL - RTS options leaked into GHCRTS (would break dhall-to-json)"
    echo "         got:  $got"
    failures=$((failures + 1))
    ;;
esac

# An operator-supplied SHOMEI_RTS_OPTS wins.
got="$(PATH="$tmp/bin:$PATH" SHOMEI_CGROUP_ROOT="$v2" SHOMEI_RTS_OPTS="-N8 -s" sh "$entrypoint" | tail -1)"
expect "operator-supplied SHOMEI_RTS_OPTS wins" "args=[+RTS -N8 -s -RTS] GHCRTS=<unset>" "$got"

# ...and setting it empty passes no RTS options at all.
got="$(PATH="$tmp/bin:$PATH" SHOMEI_CGROUP_ROOT="$v2" SHOMEI_RTS_OPTS="" sh "$entrypoint" | tail -1)"
expect "empty SHOMEI_RTS_OPTS disables the flags" "args=[] GHCRTS=<unset>" "$got"

if [ "$failures" -eq 0 ]; then
  echo "all entrypoint tests passed"
else
  echo "$failures entrypoint test(s) failed"
  exit 1
fi
