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
      collected = forEachSystem (
        system:
        import ./nix/collect-services.nix {
          pkgs = nixpkgs.legacyPackages.${system};
          buildMetadata.nixpkgsRevision = nixpkgs.rev;
        }
      );
      nixFiles = lib.fileset.toSource {
        root = ./.;
        fileset = lib.fileset.fileFilter (file: file.hasExt "nix") ./.;
      };
    in
    {
      # The formatter is the same one used by the check below.
      formatter = forEachSystem (system: nixpkgs.legacyPackages.${system}.nixfmt);

      # Keep service IFD opt-in when flake check and flake show inspect outputs.
      legacyPackages = forEachSystem (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          sc = import ./nix { inherit pkgs; };
          flakeFile = pkgs.writeText "flake.nix" (
            import ./nix/source-flake.nix {
              inherit lib;
              nixpkgsInput = (import ./flake.nix).inputs.nixpkgs;
            }
          );
        in
        lib.mapAttrs (
          serviceName: service:
          let
            source = sc.mkServiceSource {
              inherit service serviceName flakeFile;
              servicecacheFiles = {
                "flake.nix" = ./flake.nix;
                "flake.lock" = ./flake.lock;
                "nix" = ./nix;
                "README.md" = ./README.md;
                "LICENSE" = ./LICENSE;
              };
            };
            serviceBuild = import "${source.directory}/servicecache/nix/source-build.nix" {
              inherit nixpkgs system;
            };
          in
          serviceBuild.default.overrideAttrs (old: {
            passthru = old.passthru // {
              source = source.tar;
              inherit (serviceBuild) prepare;
            };
          })
        ) collected.${system}.services
      );

      packages = forEachSystem (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          # The ServiceCache source tar includes this flake but omits wasmer/.
          # It uses this entry point to recreate the service source tar; source-flake.nix
          # generates that tar's separate entry point for building the service.
          wasmer =
            if builtins.pathExists ./wasmer/build.nix then
              import ./wasmer/build.nix { inherit pkgs; }
            else
              {
                packages = { };
                tests = { };
              };
        in
        collected.${system}.smoke
        // lib.mapAttrs' (name: package: lib.nameValuePair "wasmer-${name}" package) wasmer.packages
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
