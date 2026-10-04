{ pkgs, lib }:
{
  name,
  tree,
  hash,
}:
pkgs.stdenvNoCC.mkDerivation {
  inherit name;
  nativeBuildInputs = [
    # The go command is nixpkgs', so that evaluating a service source does not
    # build the Go toolchain: the vendor tree depends on go.mod, go.sum and the
    # modules' content, not on the compiler, and the hash catches any change.
    pkgs.go
    pkgs.gitMinimal
    pkgs.cacert
  ];
  phases = [ "buildPhase" ];
  buildPhase = ''
    export HOME="$NIX_BUILD_TOP/home" GOCACHE="$NIX_BUILD_TOP/go-cache" GOPATH="$NIX_BUILD_TOP/go"
    export GOTOOLCHAIN=local GOENV=off GOFLAGS=-mod=mod
    mkdir -p "$HOME" "$GOCACHE" "$GOPATH"
    cp -r ${tree} source
    chmod -R u+w source
    cd source
    go mod vendor -o "$out"
  '';
  # A proxy or mirror is the caller's environment, as for nixpkgs' fetchers.
  impureEnvVars = lib.fetchers.proxyImpureEnvVars ++ [ "GOPROXY" ];
  outputHashAlgo = "sha256";
  outputHashMode = "recursive";
  outputHash = hash;
  # The whole vendor tree is kept: go build reads modules.txt and the
  # packages the build imports, and every module's licence stays at its path.
  passthru.scSelection = { };
}
