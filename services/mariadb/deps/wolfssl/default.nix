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
        patterns = [ "/IDE/" ];
        reason = "Unused by the CMake build.";
      }
      {
        patterns = [ "/debian/" ];
        reason = "Unused as distribution packages are not built.";
      }
      {
        patterns = [
          "/tests/"
          "/certs/"
        ];
        reason = "Unused as upstream tests are not built.";
      }
      {
        patterns = [ "/doc/" ];
        reason = "Unused as documentation is not built or installed.";
      }
      {
        patterns = [ "/wolfcrypt/src/port/" ];
        reason = "Unused by the explicit source list.";
      }
      {
        patterns = map (name: "/wolfcrypt/src/${name}") [
          "sp_arm64.c"
          "sp_armthumb.c"
          "sp_arm32.c"
          "sp_cortexm.c"
        ];
        reason = "Unused by the explicit source list.";
      }
      {
        patterns = [ "/wolfcrypt/src/sp_x86_64_asm.asm" ];
        reason = "Unused without MSVC_INTEL.";
      }
    ];
  };
  tarHash = sourceData.tarHash;
  servicecacheFiles."services/mariadb/deps/wolfssl" = ./.;
}
