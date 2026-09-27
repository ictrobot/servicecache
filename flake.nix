{
  description = "ServiceCache builds";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

  outputs =
    { self, nixpkgs }:
    let
      inherit (nixpkgs) lib;
      forEachSystem = lib.genAttrs [
        "x86_64-linux"
        "aarch64-linux"
      ];
      nixFiles = lib.fileset.toSource {
        root = ./.;
        fileset = lib.fileset.fileFilter (file: file.hasExt "nix") ./.;
      };
    in
    {
      # The formatter is the same one used by the check below.
      formatter = forEachSystem (system: nixpkgs.legacyPackages.${system}.nixfmt);

      packages = forEachSystem (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          wasmer = import ./wasmer/build.nix { inherit pkgs; };
        in
        lib.mapAttrs' (name: package: lib.nameValuePair "wasmer-${name}" package) wasmer.packages
        // lib.mapAttrs' (name: package: lib.nameValuePair "wasmer-${name}-tests" package) wasmer.tests
      );

      checks = forEachSystem (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        {
          format = pkgs.runCommand "nix-files-are-formatted" { nativeBuildInputs = [ pkgs.nixfmt ]; } ''
            find ${nixFiles} -name '*.nix' -exec nixfmt --check {} +
            touch $out
          '';
        }
      );
    };
}
