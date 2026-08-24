{
  description = "Shōmei is a Haskell authentication toolkit for building embedded Servant auth and standalone auth services from the same core primitives.";

  inputs = {
    haskell-nix-dev.url = "github:shinzui/haskell-nix-dev";
    nixpkgs.url = "github:nixos/nixpkgs/nixpkgs-unstable";

    flake-parts.url = "github:hercules-ci/flake-parts";
    flake-parts.inputs.nixpkgs-lib.follows = "nixpkgs";

    # Wires `nix fmt` (the flake `formatter`) and the `treefmt` check via
    # ./nix/treefmt.nix.
    treefmt-nix.url = "github:numtide/treefmt-nix";
    treefmt-nix.inputs.nixpkgs.follows = "nixpkgs";

    # Cabal's source-repository-package pins are not visible to callCabal2nix. Keep the Nix
    # package on the same released/source cohort with locked, non-flake inputs. The repositories
    # are catalogued by Mori as documented in flake.module.nix.
    codd-src = {
      url = "github:mzabani/codd/c32d365b56a7da482647410e68ed763e73fe4442";
      flake = false;
    };
    ephemeral-pg-src = {
      url = "github:shinzui/ephemeral-pg/304c160f25570ea5e225baf5024778c93f434b56";
      flake = false;
    };
    jose-src = {
      url = "github:sumo/hs-jose/4726d077a13b24cd1d78fb94b2db5a86c79e3f0f";
      flake = false;
    };
    openapi-hs-src = {
      url = "github:shinzui/openapi-hs/06fc11713094bf39ac00353b052f4ded5a534567";
      flake = false;
    };
    servant-health-src = {
      url = "github:shinzui/servant-health/c70bffdd59e9336700dde304dac1328d3cb62f6a";
      flake = false;
    };
    servant-openapi-hs-src = {
      url = "github:shinzui/servant-openapi-hs/181ca609688af3cad994a73988492605c71bc2d0";
      flake = false;
    };
    webauthn-src = {
      url = "github:shinzui/webauthn/c274e23a5e31aac8932bac6398b65e8bca584a99";
      flake = false;
    };
  };

  # The shinzui Cachix cache carries the prebuilt haskell-nix-dev toolchain
  # (GHC/HLS/cabal), so the first `nix develop` downloads them instead of
  # compiling HLS from source. Local users must trust this config (run with
  # `--accept-flake-config`, or add yourself to nix's trusted-users); CI sets
  # the same substituter as trusted install-time config in .github/workflows/ci.yaml.
  nixConfig = {
    extra-substituters = [ "https://shinzui.cachix.org" ];
    extra-trusted-public-keys = [ "shinzui.cachix.org-1:QEmAoJrA9WwLP0uxfDgktLi2BRrcvQQWdz8NzcMg4/E=" ];
  };

  # This flake is a thin, seihou-managed shell. All project wiring lives in the
  # imported modules under ./nix, and your own customizations belong in an
  # (optional, unmanaged) ./flake.module.nix — see flake.module.nix.example.
  outputs = inputs@{ flake-parts, nixpkgs, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = nixpkgs.lib.systems.flakeExposed;

      imports =
        [
          ./nix/haskell.nix
          ./nix/treefmt.nix
        ]
        # Your project-specific customizations. seihou never generates, touches,
        # or migrates this file, so it is the conflict-free place to extend.
        ++ nixpkgs.lib.optional (builtins.pathExists ./flake.module.nix) ./flake.module.nix;
    };
}
