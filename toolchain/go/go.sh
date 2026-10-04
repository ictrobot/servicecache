#!/usr/bin/env bash
# Build the Go toolchain from the pinned, patched tree with its own make.bash,
# bootstrapped by nixpkgs' Go. toolchain/go/default.nix supplies the inputs;
# SC_OUT_DIR receives the built tree, a Go installation.
set -euo pipefail

# make.bash builds inside its tree, so the tree is copied to the output and
# built there, as a Go installation is. The version comes from the tree's
# VERSION file, so no git is needed; the build cache and home stay inside the
# build directory.
mkdir -p "$SC_BUILD_DIR/home" "$SC_BUILD_DIR/go-cache"
cp -r "$SC_SOURCE_GO_DIR" "$SC_OUT_DIR"
chmod -R u+w "$SC_OUT_DIR"
(
  cd "$SC_OUT_DIR/src"
  env -i PATH="$PATH" \
    HOME="$SC_BUILD_DIR/home" \
    GOROOT_BOOTSTRAP="$SC_GO_BOOTSTRAP_DIR/share/go" \
    GOCACHE="$SC_BUILD_DIR/go-cache" \
    GOMAXPROCS="$JOBS" \
    GOTOOLCHAIN=local GOENV=off GOFLAGS= GOPROXY=off CGO_ENABLED=0 \
    bash ./make.bash -v --no-banner
)

# The bootstrap's intermediate objects are not part of the toolchain.
rm -rf "$SC_OUT_DIR/pkg/obj" "$SC_OUT_DIR/pkg/bootstrap"
echo "built $(head -n 1 "$SC_OUT_DIR/VERSION") with the wasix series"
