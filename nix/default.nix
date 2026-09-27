# Shared constructors and build context. Service discovery belongs to collect-services.nix.
{
  pkgs,
  buildMetadata ? { },
}:
let
  inherit (pkgs) lib;
  base = {
    mkSource = import ./mk-source.nix { inherit pkgs lib; };
    fetchSelectedGit = import ./fetch-selected-git.nix { inherit pkgs lib; };
    fetchSelectedArchive = import ./fetch-selected-archive.nix { inherit pkgs lib; };
    patchSeries = import ./patch-series.nix { inherit lib; };
    collectMetadata = import ./collect-metadata.nix { inherit lib; };
    mkServiceSource = import ./mk-service-source.nix { inherit pkgs lib; };
  };
  toolchain = import ../toolchain {
    inherit pkgs;
    sc = base;
  };
in
base
// {
  inherit toolchain;
  mkGuestBuild = import ./mk-guest-build.nix {
    inherit
      pkgs
      lib
      toolchain
      buildMetadata
      ;
  };
}
