# Shared constructors and the guest toolchain built with them.
{ pkgs }:
let
  inherit (pkgs) lib;
  base = {
    mkSource = import ./mk-source.nix { inherit pkgs lib; };
    fetchSelectedGit = import ./fetch-selected-git.nix { inherit pkgs lib; };
    fetchSelectedArchive = import ./fetch-selected-archive.nix { inherit pkgs lib; };
    patchSeries = import ./patch-series.nix { inherit lib; };
  };
  toolchain = import ../toolchain {
    inherit pkgs;
    sc = base;
  };
in
base // { inherit toolchain; }
