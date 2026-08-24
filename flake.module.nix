# Project-specific flake customizations (seihou never touches this file).
# EP-5: a reproducible OCI image built from the same pinned dependency closure as the dev
# shell, via dockerTools.buildLayeredImage (no Docker daemon needed to build). This is the
# PRODUCTION deployment artifact (push to a registry / run on k8s).
#
#   nix build .#dockerImage          # produces ./result, a loadable image tarball
#   docker load < result             # loads shomei-server:latest
#
# Local development/testing does NOT use this image or docker compose — it runs the stack
# from the Nix dev shell with a local PostgreSQL on a Unix socket: `process-compose up
# --no-server` (the --no-server flag frees TCP 8080 for shomei-server; see process-compose.yaml).
#
# NOTE: authored for the deployment story; not built in the development sandbox where this
# landed. Verify with `nix build .#dockerImage` in an environment with the flake's substituters.
{ inputs, lib, ... }:
{
  perSystem = { pkgs, config, ... }: {
    # shomei-server renders its Dhall config to JSON by shelling out to the
    # `dhall-to-json` binary (shomei-server/src/Shomei/Server/Config.hs). The
    # production image (below) already bundles it; the dev shell must too, so
    # `cabal test` runs shomei-server-config-test locally and in CI without
    # depending on a globally-installed binary.
    haskellProject.extraDevPackages = [ pkgs.dhall-json ];

    # The repository is a Cabal project containing several local packages, while the generated
    # base module's callCabal2nix target assumes one root .cabal file. Compose the package set
    # explicitly so the default package and OCI image build the same shomei-server closure as
    # cabal.project. Dependency sources and compatibility pins were verified through:
    #
    #   mori://shinzui/haskell-nix/repos/haskell-nix
    #   mori://mzabani/codd/repos/codd
    #   mori://shinzui/ephemeral-pg/repos/ephemeral-pg
    #   mori://frasertweedale/hs-jose/repos/hs-jose
    #   mori://tweag/webauthn/repos/webauthn-shomei-fork
    #   mori://shinzui/openapi-hs/repos/openapi-hs
    #   mori://shinzui/servant-openapi-hs/repos/servant-openapi-hs
    #   mori://shinzui/servant-health/repos/servant-health
    packages.default = lib.mkForce (
      let
        haskellLib = pkgs.haskell.lib.compose;
        upstream = pkgs.haskell.packages.ghc9124;
        haskellPackages = upstream.override {
          overrides = hself: hsuper: {
            crypton = hsuper.crypton_1_1_2;
            crypton-connection = hsuper.crypton-connection_0_4_6;
            crypton-x509 = hsuper.crypton-x509_1_9_0;
            crypton-x509-store = hsuper.crypton-x509-store_1_9_0;
            crypton-x509-system = hsuper.crypton-x509-system_1_9_0;
            crypton-x509-validation = hsuper.crypton-x509-validation_1_9_0;
            hasql = hsuper.hasql_1_10_3;
            hasql-pool = hsuper.hasql-pool_1_4_2;
            hasql-transaction = hsuper.hasql-transaction_1_2_2;
            haxl = haskellLib.dontCheck (haskellLib.doJailbreak hsuper.haxl);
            hpke = haskellLib.dontCheck (haskellLib.doJailbreak hsuper.hpke_0_1_0);
            http-client-tls = hsuper.http-client-tls_0_4_0;
            mlkem = haskellLib.markUnbroken (haskellLib.dontCheck (haskellLib.doJailbreak hsuper.mlkem));
            postgresql-binary = hsuper.postgresql-binary_0_15_0_1;
            # nixpkgs still carries Hackage revision 1 (ram <0.22); revision 2 allows ram <0.23.
            smtp-mail = haskellLib.doJailbreak hsuper.smtp-mail_0_5_0_1;
            tls = haskellLib.dontCheck hsuper.tls_2_4_1;
            validation = haskellLib.dontCheck hsuper.validation_1_2_2;

            codd = haskellLib.dontCheck (haskellLib.doJailbreak (hself.callCabal2nix "codd" inputs.codd-src { }));
            ephemeral-pg = haskellLib.dontCheck (haskellLib.doJailbreak (hself.callCabal2nix "ephemeral-pg" inputs.ephemeral-pg-src { }));
            jose = haskellLib.dontCheck (haskellLib.doJailbreak (hself.callCabal2nix "jose" inputs.jose-src { }));
            openapi-hs = haskellLib.dontCheck (hself.callCabal2nix "openapi-hs" inputs.openapi-hs-src { });
            servant-health = haskellLib.dontCheck (hself.callCabal2nix "servant-health" inputs.servant-health-src { });
            servant-openapi-hs = haskellLib.dontCheck (hself.callCabal2nix "servant-openapi-hs" inputs.servant-openapi-hs-src { });
            webauthn = haskellLib.dontCheck (haskellLib.doJailbreak (hself.callCabal2nix "webauthn" inputs.webauthn-src { }));

            shomei-core = haskellLib.dontCheck (hself.callCabal2nix "shomei-core" (inputs.self + "/shomei-core") { });
            shomei-jwt = haskellLib.dontCheck (hself.callCabal2nix "shomei-jwt" (inputs.self + "/shomei-jwt") { });
            shomei-migrations = haskellLib.dontCheck (hself.callCabal2nix "shomei-migrations" (inputs.self + "/shomei-migrations") { });
            shomei-postgres = haskellLib.dontCheck (hself.callCabal2nix "shomei-postgres" (inputs.self + "/shomei-postgres") { });
            shomei-servant = haskellLib.dontCheck (hself.callCabal2nix "shomei-servant" (inputs.self + "/shomei-servant") { });
            shomei-webauthn = haskellLib.dontCheck (hself.callCabal2nix "shomei-webauthn" (inputs.self + "/shomei-webauthn") { });
            shomei-server = haskellLib.dontCheck (hself.callCabal2nix "shomei-server" (inputs.self + "/shomei-server") { });
          };
        };
      in
      haskellLib.justStaticExecutables haskellPackages.shomei-server
    );

    packages.dockerImage = pkgs.dockerTools.buildLayeredImage {
      name = "shomei-server";
      tag = "latest";
      contents = [
        config.packages.default # provides /bin/shomei-server and /bin/shomei-admin
        pkgs.dhall-json # dhall-to-json, used by the config loader
        pkgs.busybox # sh + wget for the entrypoint and healthcheck
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
