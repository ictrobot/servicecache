{ pkgs, sc }:
{
  directory = ./include;
  servicecacheFiles = {
    "extensions/ictrobot_shm_v1/default.nix" = ./default.nix;
    "extensions/ictrobot_shm_v1/include" = ./include;
  };
  smoke =
    let
      recipe = pkgs.lib.fileset.toSource {
        root = ./.;
        fileset = pkgs.lib.fileset.unions [
          ./include
          ./demo.c
          ./smoke-build.sh
        ];
      };
    in
    pkgs.runCommand "smoke-extension-ictrobot_shm_v1" { nativeBuildInputs = sc.toolchain.programs; } ''
      SC_OUT_DIR="$out" bash ${recipe}/smoke-build.sh
    '';
}
