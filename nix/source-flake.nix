{ lib, nixpkgsInput }:
''
  {
    description = "ServiceCache guest build";
    inputs.nixpkgs = ${lib.generators.toPretty { } nixpkgsInput};
    outputs = { nixpkgs, ... }: {
      packages = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ] (system:
        import ./servicecache/nix/source-build.nix { inherit nixpkgs system; }
      );
    };
  }
''
