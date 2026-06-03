{
  description = "Shōmei is a Haskell authentication toolkit designed to support two deployment modes:";

  inputs.haskell-nix-dev.url = "github:shinzui/haskell-nix-dev";
  inputs.nixpkgs.follows = "haskell-nix-dev/nixpkgs";
  inputs.flake-utils.follows = "haskell-nix-dev/flake-utils";

  # TODO(haskell-nix-dev EP-2): fill in the Cachix substituter URL and public key once the
  # base flake's binary cache is published, so the first `nix develop` downloads prebuilt
  # GHC/HLS/cabal instead of compiling HLS from source. Left empty (inert) until then.
  nixConfig = {
    extra-substituters = [ ];
    extra-trusted-public-keys = [ ];
  };

  outputs = { self, nixpkgs, haskell-nix-dev, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs { inherit system; };
        hsdev = haskell-nix-dev.lib.${system};
        haskellPackages = pkgs.haskell.packages."ghc9124";

        commonNativeBuildInputs = [
          pkgs.zlib
          pkgs.just
          pkgs.pkg-config
          pkgs.postgresql
        ] ++ pkgs.lib.optional true pkgs.process-compose;

        commonShellHook = ''

          export PGHOST="$PWD/db"
          export PGDATA="$PGHOST/db"
          export PGLOG=$PGHOST/postgres.log
          export PGDATABASE=shomei
          export PG_CONNECTION_STRING=postgresql://$(jq -rn --arg x $PGHOST '$x|@uri')/$PGDATABASE

          mkdir -p $PGHOST
          mkdir -p .dev

          if [ ! -d $PGDATA ]; then
            initdb --auth=trust --no-locale --encoding=UTF8
          fi
        '';

        mkProjectShell = ghc: hsdev.mkDevShell {
          inherit ghc;
          extraNativeBuildInputs = commonNativeBuildInputs;
          withHls = true;
          shellHook = commonShellHook;
        };
      in
      {
        packages = {
          default = haskellPackages.callCabal2nix "shomei" ./. { };
        };

        checks = {
        };

        devShells = {
          default = mkProjectShell "ghc9124";
          "ghc9124" = mkProjectShell "ghc9124";
        };
      });
}
