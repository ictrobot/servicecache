{ pkgs, lib }:
{ selection, ... }@args:
let
  exclusions = map (rule: {
    inherit (rule) paths;
    keep = rule.keep or [ ];
  }) (selection.exclude or [ ]);
  fetcherArgs = builtins.removeAttrs args [ "selection" ] // {
    nativeBuildInputs = (args.nativeBuildInputs or [ ]) ++ lib.optional (exclusions != [ ]) pkgs.jq;
    postFetch = lib.optionalString (exclusions != [ ]) ''
      bash ${./reduce-source.sh} "$out" ${builtins.toFile "exclusions.json" (builtins.toJSON exclusions)}
    '';
    passthru = (args.passthru or { }) // {
      scSelection = selection;
    };
  };
  # Fixed-output paths depend on the name and expected hash, not the recipe,
  # so the name carries a hash of what decides the tree: the arguments,
  # fetchzip's unpack script around the reduction, and the tar and unzip
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
      }
    )
  );
in
assert (selection.scope or [ ]) == [ ];
assert lib.assertMsg (!(args ? postFetch)) "fetchSelectedArchive does not accept postFetch";
pkgs.fetchzip (fetcherArgs // { name = "${args.name or "source"}-${fingerprint}"; })
