# Plain Dockerfile — the SECONDARY, non-reproducible path (the reproducible image is built from
# the Nix flake: `nix build .#dockerImage`; see flake.module.nix). This runtime-only image
# expects the `shomei-server` and `shomei-admin` binaries plus `dhall-to-json` to be provided
# by a build stage or bind-mount; building the Haskell workspace here would not reproduce the
# flake's pinned source-repository-packages (jose PR, codd, ephemeral-pg).
FROM debian:stable-slim
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates wget libgmp10 && rm -rf /var/lib/apt/lists/*
COPY deploy/entrypoint.sh /usr/local/bin/entrypoint.sh
# Place the binaries here (e.g. via a multi-stage GHC build or `cabal install --installdir`):
#   COPY --from=build /out/bin/shomei-server /usr/local/bin/
#   COPY --from=build /out/bin/shomei-admin  /usr/local/bin/
#   COPY --from=build /usr/bin/dhall-to-json /usr/local/bin/
EXPOSE 8080
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
