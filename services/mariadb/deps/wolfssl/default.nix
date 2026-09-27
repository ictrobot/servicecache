{
  sc,
  sourceData,
  versionDirectory,
}:
let
  pin = sourceData.upstream;
in
sc.mkSource {
  version = pin.rev;
  key = "wolfssl";
  name = "wolfssl-${builtins.substring 0 12 pin.rev}";
  upstream = sc.fetchSelectedGit {
    url = "https://github.com/wolfSSL/wolfssl.git";
    inherit (pin) rev hash;
    selection.exclude = [
      {
        paths = [ "IDE" ];
        reason = "Unused by the CMake build.";
      }
      {
        paths = [ "debian" ];
        reason = "Unused as distribution packages are not built.";
      }
      {
        paths = [
          "tests"
          "certs"
        ];
        reason = "Unused as upstream tests are not built.";
      }
      {
        paths = [ "doc" ];
        reason = "Unused as documentation is not built or installed.";
      }
      {
        paths = [ "wolfcrypt/src/port" ];
        reason = "Unused by the explicit source list.";
      }
      {
        paths = map (name: "wolfcrypt/src/${name}") [
          "sp_arm64.c"
          "sp_armthumb.c"
          "sp_arm32.c"
          "sp_cortexm.c"
        ];
        reason = "Unused by the explicit source list.";
      }
      {
        paths = [ "wolfcrypt/src/sp_x86_64_asm.asm" ];
        reason = "Unused without MSVC_INTEL.";
      }
    ];
  };
  tarHash = sourceData.tarHash;
  servicecacheFiles."services/mariadb/deps/wolfssl" = ./.;
}
