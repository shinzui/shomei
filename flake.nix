{
  description = "Shōmei is a Haskell authentication toolkit for building embedded Servant auth and standalone auth services from the same core primitives.";

  inputs = {
    haskell-nix-dev.url = "github:shinzui/haskell-nix-dev";
    nixpkgs.follows = "haskell-nix-dev/nixpkgs";

    flake-parts.url = "github:hercules-ci/flake-parts";
    flake-parts.inputs.nixpkgs-lib.follows = "nixpkgs";

    treefmt-nix.follows = "haskell-nix-dev/treefmt-nix";

    pre-commit-hooks.url = "github:cachix/git-hooks.nix";
    pre-commit-hooks.inputs.nixpkgs.follows = "nixpkgs";

    # Project-specific source pins (NOT provided by the nix-haskell-flake module).
    # Cabal's source-repository-package pins are invisible to callCabal2nix, so the Nix
    # package set must be kept on the same released/source cohort with locked, non-flake
    # inputs. These are consumed by ./flake.module.nix (packages.default override).
    # Repositories are catalogued by Mori; see the comment block in flake.module.nix.
    #
    # NOTE: flake inputs can only be declared here in the top-level flake.nix, which
    # nix-haskell-flake generates. This is the one seihou-managed edit that has no home in
    # the unmanaged flake.module.nix; re-apply it after any future `seihou run` of this module.
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

  # The haskell-nix-dev base flake's binary cache, so the first `nix develop` downloads
  # prebuilt GHC/HLS/cabal instead of compiling HLS from source. nixConfig is only honored
  # for users who trust this flake; for a guaranteed pull run `cachix use shinzui` once, or
  # add these two lines to your nix.conf.
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
          ./nix/pre-commit.nix
        ]
        # Your project-specific customizations. seihou never generates, touches,
        # or migrates this file, so it is the conflict-free place to extend.
        ++ nixpkgs.lib.optional (builtins.pathExists ./flake.module.nix) ./flake.module.nix;
    };
}
