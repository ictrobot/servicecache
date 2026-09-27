#!/usr/bin/env bash
set -euo pipefail

source "${SC_TOOLCHAIN:?}/guest-lib.sh"
sc_build_init valkey "${1:?usage: $0 version}"

# Bundled libraries that differ between Valkey release series: 9.x replaced
# hiredis with libvalkey and moved the Lua engine into a module, which is
# linked statically here.
case "$SC_VERSION" in
  7.2.*|8.1.*)
    client_lib=hiredis
    series_options=()
    ;;
  9.*)
    client_lib=libvalkey
    # The settings the patches select when CFLAGS name wasm32; guest-cc keeps
    # its target in its configuration file, so they are passed here.
    series_options=(
      BUILD_LUA=yes
      LUA_PIC_FLAG=
      "LUA_WASM_API_FLAGS=-DVALKEYMODULE_API=extern -DVALKEYMODULE_ATTR_COMMON="
    )
    ;;
  *)
    sc_fail "no build options defined for Valkey $SC_VERSION"
    ;;
esac

# The makefiles compile beside their sources, so the build has a copy of them.
tree="$SC_BUILD_DIR/valkey"
sc_copy_source "$SC_SOURCE_VALKEY_DIR" "$tree"

# src/mkreleasehdr.sh asks git for a revision and a change count; the copy
# is no repository and the build's PATH has no git, so it writes its fallbacks.

# -fno-PIC comes last, after the -fPIC the bundled libraries' makefiles pass:
# a guest module is linked once and never relocated. The server and the
# client build with the libraries' options plus their own.
deps_options=(
  CC="${SC_CCACHE:+$SC_CCACHE }guest-cc"
  AR=guest-ar
  RANLIB=guest-ranlib
  BUILD_TLS=no
  BUILD_RDMA=no
  CFLAGS="-DNO_PROCESSOR_CLOCK -fno-PIC"
  LDFLAGS=-pthread
)
make_options=(
  "${deps_options[@]}"
  CLANG=clang
  MALLOC=libc
  "${series_options[@]}"
  USE_SYSTEMD=no
  # OPTIMIZATION left at its default -O3 adds -flto, at 7.2 to the server's
  # own flags too, which OPT does not replace.
  OPT=-O2
  OPTIMIZATION=-O2
  FINAL_LDFLAGS="-pthread -O2"
  FINAL_LIBS=-lm
)

sc_guest make -C "$tree/src" -j"$JOBS" valkey-server "${make_options[@]}"

# The client library is linked by valkey-cli but is not one of its Make
# prerequisites, so build it explicitly.
sc_guest make -C "$tree/deps" -j"$JOBS" "$client_lib" linenoise fpconv \
  "${deps_options[@]}"

sc_guest make -C "$tree/src" -j"$JOBS" valkey-cli "${make_options[@]}"

sc_strip 2 "$tree/src/valkey-server" "$SC_BUILD_DIR/valkey-server.wasm"
sc_strip 2 "$tree/src/valkey-cli" "$SC_BUILD_DIR/valkey-cli.wasm"

sc_assemble "$SC_BUILD_DIR/valkey-server.wasm" "$SC_BUILD_DIR/valkey-cli.wasm"
