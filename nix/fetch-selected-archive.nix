{ pkgs, lib }:
{ selection, ... }@args:
let
  selected = import ./selection.nix { inherit lib; } selection;
  scripts = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [
      ./reduce-source.sh
      ./check-selection.sh
    ];
  };
  sparseCheckout = builtins.toFile "sparse-checkout" (
    lib.concatMapStrings (pattern: "${pattern}\n") selected.sparseCheckout
  );
  fetcherArgs = builtins.removeAttrs args [ "selection" ] // {
    nativeBuildInputs =
      (args.nativeBuildInputs or [ ]) ++ lib.optional selected.reduces pkgs.gitMinimal;
    postFetch = lib.optionalString selected.reduces ''
      bash ${scripts}/reduce-source.sh "$out" ${sparseCheckout} ${selected.checked}
    '';
    passthru = (args.passthru or { }) // {
      scSelection = selection;
    };
  };
  # Fixed-output paths depend on the name and expected hash, not the recipe,
  # so the name carries a hash of what decides the tree: the arguments,
  # fetchzip's unpack script around the reduction, and the tar, unzip and git
  # versions. None of these depend on the system, so every system evaluates
  # the same path.
  fingerprint = builtins.substring 0 12 (
    builtins.hashString "sha256" (
      builtins.toJSON {
        args = builtins.removeAttrs fetcherArgs [
          "passthru"
          "nativeBuildInputs"
        ];
        unpack = (pkgs.fetchzip fetcherArgs).postFetch;
        tar = pkgs.gnutar.version;
        unzip = pkgs.unzip.version;
        git = lib.optionalString selected.reduces pkgs.gitMinimal.version;
      }
    )
  );
in
assert selected.scope == [ ];
assert lib.assertMsg (!(args ? postFetch)) "fetchSelectedArchive does not accept postFetch";
pkgs.fetchzip (fetcherArgs // { name = "${args.name or "source"}-${fingerprint}"; })
