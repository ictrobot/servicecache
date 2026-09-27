{ lib }:
directory:
let
  names = builtins.filter (lib.hasSuffix ".patch") (builtins.attrNames (builtins.readDir directory));
  invalid = builtins.filter (
    name: builtins.match "^[0-9][0-9][0-9][0-9]-.+[.]patch$" name == null
  ) names;
in
assert lib.assertMsg (names != [ ]) "No patch files found in ${toString directory}";
assert lib.assertMsg (invalid == [ ])
  "Patch filenames must start with a four-digit sequence number: ${lib.concatStringsSep ", " invalid}";
map (name: builtins.toFile name (builtins.readFile (directory + "/${name}"))) names
