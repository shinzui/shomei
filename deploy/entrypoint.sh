#!/usr/bin/env sh
# Container entrypoint (EP-5): run migrations and ensure an active signing key via the
# shomei-admin CLI (the EP-5 -> EP-4 hard dependency), then exec the server so SIGTERM from
# `docker stop` reaches it for graceful shutdown.
set -eu

echo "[entrypoint] applying migrations"
shomei-admin migrate

if shomei-admin keys list | grep -q KeyActive; then
  echo "[entrypoint] an active signing key already exists"
else
  echo "[entrypoint] no active key; generating and activating one"
  kid="$(shomei-admin keys generate | sed 's/.*key: //')"
  shomei-admin keys activate "$kid"
fi

# Container-aware GHC RTS defaults (EP-3 of the operational-hardening MasterPlan).
#
# GHC's -N sizes the capability count from the processor count / CPU affinity mask. An affinity
# mask reflects cpuset pinning but NOT CFS bandwidth quotas -- and `docker --cpus` and
# Kubernetes CPU *limits* are CFS quotas. So a container limited to 2 CPUs on a 32-core node
# would otherwise run 32 capabilities and thrash in GC. Compute the quota ourselves.
#
# SHOMEI_CGROUP_ROOT exists so this arithmetic can be tested against fixtures (see
# deploy/entrypoint-test.sh) and to support unusual cgroup mount points. Leave it unset in
# production.
cgroup_root="${SHOMEI_CGROUP_ROOT:-/sys/fs/cgroup}"
cpus=""

if [ -f "$cgroup_root/cpu.max" ]; then
  # cgroup v2: "<quota> <period>" in microseconds, or "max <period>" when unlimited.
  read -r quota period <"$cgroup_root/cpu.max" || true
  if [ "${quota:-max}" != "max" ] && [ "${period:-0}" -gt 0 ]; then
    # Round up: a 1.5-CPU quota deserves 2 capabilities, not 1.
    cpus=$(((quota + period - 1) / period))
  fi
elif [ -f "$cgroup_root/cpu/cpu.cfs_quota_us" ] && [ -f "$cgroup_root/cpu/cpu.cfs_period_us" ]; then
  # cgroup v1: quota is -1 when unlimited.
  quota="$(cat "$cgroup_root/cpu/cpu.cfs_quota_us")"
  period="$(cat "$cgroup_root/cpu/cpu.cfs_period_us")"
  if [ "$quota" -gt 0 ] && [ "$period" -gt 0 ]; then
    cpus=$(((quota + period - 1) / period))
  fi
fi

# `-A` is a per-capability nursery, so its memory cost is (nursery x capabilities). Under a
# quota, capabilities are few and 64 MiB each is a good trade. With no quota we fall back to the
# host's processor count, where 64 MiB x N gets expensive fast -- measured at 230 MB -> 956 MB of
# resident memory on a 10-core host, with no reproducible latency benefit. So the nursery is only
# enlarged when a quota actually bounded the capability count.
nursery=""
if [ -n "$cpus" ]; then
  nursery=" -A64m"
else
  cpus="$(nproc 2>/dev/null || echo 1)"
fi
[ "$cpus" -ge 1 ] 2>/dev/null || cpus=1

# The options, passed to the server on its own command line:
#   -N$cpus         capabilities sized to the quota, not to the host
#   -A64m           (only under a quota, see above) a larger per-capability nursery means fewer
#                   young-generation collections, each of which is a stop-the-world sync that can
#                   queue behind an Argon2 hash pinned in an unsafe foreign call.
#   --nonmoving-gc  old-generation collection runs concurrently with the mutator, so the long
#                   global pauses -- the ones a pinned capability turns into p99 latency --
#                   largely disappear.
#
# Set SHOMEI_RTS_OPTS to override, or to the empty string to pass nothing at all.
#
# These go through `+RTS ... -RTS`, NOT through the GHCRTS environment variable, even though
# GHCRTS looks like the natural fit. GHCRTS is inherited by *every* GHC-compiled program in the
# environment, and shomei-server shells out to `dhall-to-json` to render $SHOMEI_CONFIG.
# dhall-to-json is built without -threaded and without -rtsopts, so it dies on `-N4`:
#
#     dhall-to-json: the flag -N4 requires the program to be built with -threaded
#     dhall-to-json: Most RTS options are disabled. Link with -rtsopts to enable them.
#
# which makes the server fail to boot with a Dhall config. `+RTS` is consumed by the server's
# own runtime and never reaches a child process. (The RTS rejects unknown options and exits, so
# a typo here still fails the container at boot rather than silently reverting to defaults.)
rts_opts="${SHOMEI_RTS_OPTS--N$cpus$nursery --nonmoving-gc}"

if [ -n "$rts_opts" ]; then
  echo "[entrypoint] starting shomei-server (+RTS $rts_opts -RTS)"
  # Deliberately unquoted: $rts_opts is a list of flags, not one argument.
  # shellcheck disable=SC2086
  exec shomei-server +RTS $rts_opts -RTS
else
  echo "[entrypoint] starting shomei-server (no RTS options)"
  exec shomei-server
fi
