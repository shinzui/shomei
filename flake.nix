{
  description = "Shōmei is a Haskell authentication toolkit for building embedded Servant auth and standalone auth services from the same core primitives.";

  inputs = {
    haskell-nix-dev.url = "github:shinzui/haskell-nix-dev";
    nixpkgs.follows = "haskell-nix-dev/nixpkgs";

    flake-parts.url = "github:hercules-ci/flake-parts";
    flake-parts.inputs.nixpkgs-lib.follows = "nixpkgs";
  };

  # TODO(haskell-nix-dev EP-2): fill in the Cachix substituter URL and public key once the
  # base flake's binary cache is published, so the first `nix develop` downloads prebuilt
  # GHC/HLS/cabal instead of compiling HLS from source. Left empty (inert) until then.
  nixConfig = {
    extra-substituters = [ ];
    extra-trusted-public-keys = [ ];
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
        ]
        # Your project-specific customizations. seihou never generates, touches,
        # or migrates this file, so it is the conflict-free place to extend.
        ++ nixpkgs.lib.optional (builtins.pathExists ./flake.module.nix) ./flake.module.nix;
    };
}
