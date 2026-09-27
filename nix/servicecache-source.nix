# Copy only selected ServiceCache files. Resolving links keeps their contents
# available without exporting the directories that own the link targets.
{ pkgs, lib }:
entries:
let
  walk =
    ancestors: name: path:
    let
      resolved = builtins.path {
        inherit path;
        name = "servicecache-source-file";
      };
      directory = builtins.readFileType resolved == "directory";
      identity = toString resolved;
    in
    assert lib.assertMsg (
      !(builtins.elem identity ancestors)
    ) "ServiceCache source directory link cycle: ${name}";
    if directory then
      [ ''mkdir -p "$out"/${lib.escapeShellArg name}'' ]
      ++ lib.concatMap (child: walk (ancestors ++ [ identity ]) "${name}/${child}" (path + "/${child}")) (
        builtins.attrNames (builtins.readDir path)
      )
    else
      [
        ''
          mkdir -p "$out"/${lib.escapeShellArg (builtins.dirOf name)}
          cp --preserve=mode ${resolved} "$out"/${lib.escapeShellArg name}
        ''
      ];
in
pkgs.runCommand "servicecache-source" { } (
  lib.concatStringsSep "\n" (
    lib.concatMap (name: walk [ ] name entries.${name}) (builtins.attrNames entries)
  )
)
