# Collect services and smoke fixtures. A source tar carries this same collector
# with just its selected service version and dependencies.
{ pkgs, buildMetadata }:
let
  inherit (pkgs) lib;
  sc = import ./default.nix { inherit pkgs buildMetadata; };
  directories =
    path:
    if builtins.pathExists path then
      builtins.attrNames (lib.filterAttrs (_: type: type == "directory") (builtins.readDir path))
    else
      [ ];
  scope = lib.makeScope lib.callPackageWith (self: {
    inherit sc;
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
  smoke = {
    smoke-toolchain = sc.toolchain.smoke;
  };
}
