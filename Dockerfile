# Plain Dockerfile — the SECONDARY, non-reproducible path (the reproducible image is built from
# the Nix flake: `nix build .#dockerImage`; see flake.module.nix). This runtime-only image
# expects the `shomei-server` and `shomei-admin` binaries plus `dhall-to-json` to be provided
# by a build stage or bind-mount; building the Haskell workspace here would not reproduce the
# flake's pinned source-repository-packages (jose PR, codd, ephemeral-pg).
#
# GHC runtime tuning is NOT set here. `deploy/entrypoint.sh` computes it at start-up, because
# the right value depends on the cgroup CPU quota the container is actually given, which is
# unknowable at build time. It exports:
#
#     GHCRTS="-N<cpu-quota> -A64m --nonmoving-gc"
#
# GHC's -N sizes capabilities from the CPU affinity mask, which does not reflect CFS bandwidth
# quotas (`docker --cpus`, Kubernetes CPU limits), so without this a 2-CPU container on a
# 32-core host runs 32 capabilities and thrashes in GC. Set GHCRTS yourself to override the
# whole thing; note the RTS rejects unknown options and exits, so a typo fails the container at
# boot rather than silently reverting to defaults. `coreutils` supplies the `nproc` the
# entrypoint falls back to when there is no quota.
FROM debian:stable-slim
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates coreutils wget libgmp10 && rm -rf /var/lib/apt/lists/*
COPY deploy/entrypoint.sh /usr/local/bin/entrypoint.sh
# Place the binaries here (e.g. via a multi-stage GHC build or `cabal install --installdir`):
#   COPY --from=build /out/bin/shomei-server /usr/local/bin/
#   COPY --from=build /out/bin/shomei-admin  /usr/local/bin/
#   COPY --from=build /usr/bin/dhall-to-json /usr/local/bin/
EXPOSE 8080
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
