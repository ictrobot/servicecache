# Collect services and smoke fixtures. A source tar carries this same collector
# with just its selected service version and dependencies.
{ pkgs, buildMetadata }:
let
  inherit (pkgs) lib;
  sc = import ./default.nix { inherit pkgs buildMetadata; };
  servicePkgs = import ./service-pkgs.nix { inherit pkgs; };
  directories =
    path:
    if builtins.pathExists path then
      builtins.attrNames (lib.filterAttrs (_: type: type == "directory") (builtins.readDir path))
    else
      [ ];
  libraryNames = lib.filter (name: builtins.pathExists (../libs + "/${name}/default.nix")) (
    directories ../libs
  );
  extensionNames = lib.filter (name: builtins.pathExists (../extensions + "/${name}/default.nix")) (
    directories ../extensions
  );
  scope = lib.makeScope lib.callPackageWith (self: {
    pkgs = servicePkgs;
    inherit sc;
    extensions = lib.genAttrs extensionNames (name: self.callPackage (../extensions + "/${name}") { });
    libraries = lib.genAttrs libraryNames (name: self.callPackage (../libs + "/${name}") { });
  });
  servicePackages = lib.concatMapAttrs (
    name: _:
    let
      directory = ../services + "/${name}";
      versions = lib.filter (
        version: builtins.pathExists (directory + "/versions/${version}/version.nix")
      ) (directories (directory + "/versions"));
    in
    lib.listToAttrs (
      map (
        version:
        lib.nameValuePair "${name}-${lib.replaceStrings [ "." ] [ "_" ] version}" (
          scope.callPackage (directory + "/shared/package.nix") {
            inherit version;
          }
        )
      ) versions
    )
  ) (lib.genAttrs (directories ../services) (_: null));
in
{
  services = servicePackages;
  smoke =
    lib.concatMapAttrs (
      name: extension:
      lib.optionalAttrs (extension ? smoke) { "smoke-extension-${name}" = extension.smoke; }
    ) scope.extensions
    // lib.concatMapAttrs (
      name: package: lib.optionalAttrs (package ? smoke) { "smoke-${name}" = package.smoke; }
    ) scope.libraries
    // {
      smoke-toolchain = sc.toolchain.smoke;
      go-toolchain = sc.goToolchain.go;
      go-toolchain-tests = sc.goToolchain.tests;
    };
}
