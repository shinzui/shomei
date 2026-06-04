# flake.module.nix — project-specific flake-parts customizations.
# seihou does NOT manage this file; it is safe to edit freely.
{ inputs, ... }:
{
  # Wire `nix fmt` (the flake formatter) via treefmt-nix.
  #
  # NOTE (EP-1 discovery): the seihou-generated `flake.nix` imports only
  # `./nix/haskell.nix` and this file — it does NOT import `./nix/treefmt.nix`,
  # and `treefmt-nix` is not a top-level flake input, so `nix fmt` is otherwise
  # unavailable. `nix/treefmt.nix` cannot be imported directly because it
  # references `inputs.treefmt-nix`, which only exists transitively under
  # `haskell-nix-dev`. We therefore reach the treefmt flake module through that
  # transitive path and inline the (same) formatter config here, keeping every
  # seihou-managed file untouched.
  imports = [ inputs.haskell-nix-dev.inputs.treefmt-nix.flakeModule ];

  perSystem = { pkgs, config, ... }: {
    treefmt = {
      projectRootFile = "flake.nix";
      # Leave seihou-managed Nix files alone: seihou owns and formats them with
      # its own toolchain, and our nixpkgs-fmt version would otherwise rewrite
      # them (breaking `nix fmt` idempotence and touching files we must not edit).
      settings.global.excludes = [ "nix/*" "flake.nix" ];
      programs.nixpkgs-fmt.enable = true;
      programs.fourmolu.enable = true;
      programs.cabal-fmt.enable = true;
    };

    # Add cabal-install, fourmolu, and cabal-fmt to the dev shell so they are
    # available both for `nix fmt` and interactively in `nix develop`.
    haskellProject.extraDevPackages = [
      pkgs.cabal-install
      pkgs.haskellPackages.fourmolu
      pkgs.haskellPackages.cabal-fmt
    ];
  };
}
