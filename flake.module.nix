# Project-specific flake customizations (seihou never touches this file).
# EP-5: a reproducible OCI image built from the same pinned dependency closure as the dev
# shell, via dockerTools.buildLayeredImage (no Docker daemon needed to build).
#
#   nix build .#dockerImage          # produces ./result, a loadable image tarball
#   docker load < result             # loads shomei-server:latest
#   docker compose up                # see docker-compose.yaml
#
# NOTE: authored for the deployment story; not built in the development sandbox where this
# landed. Verify with `nix build .#dockerImage` in an environment with the flake's substituters.
{ ... }:
{
  perSystem = { pkgs, config, ... }: {
    packages.dockerImage = pkgs.dockerTools.buildLayeredImage {
      name = "shomei-server";
      tag = "latest";
      contents = [
        config.packages.default     # provides /bin/shomei-server and /bin/shomei-admin
        pkgs.dhall-json             # dhall-to-json, used by the config loader
        pkgs.busybox                # sh + wget for the entrypoint and healthcheck
        pkgs.cacert
      ];
      config = {
        Entrypoint = [ "/bin/sh" "${./deploy/entrypoint.sh}" ];
        ExposedPorts = { "8080/tcp" = { }; };
        Env = [ "SHOMEI_PORT=8080" ];
      };
    };
  };
}
