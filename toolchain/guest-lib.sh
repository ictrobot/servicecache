#!/usr/bin/env bash

sc_fail() {
  echo "error: $*" >&2
  return 1
}

# Begin a guest build with inputs and settings supplied by its derivation.
sc_build_init() {
  SC_SERVICE="$1"
  SC_VERSION="$2"
  sc_build_environment
}

sc_library_init() {
  SC_LIBRARY="$1"
  SC_VERSION="$2"
  sc_build_environment
}

sc_build_environment() {
  PATH="$(sc_store_path)" || return 1
  export PATH
  if [[ -n "${SC_CCACHE:-}" ]]; then
    SC_CCACHE="$(command -v "$SC_CCACHE")" || return 1
    if [[ -n "${CCACHE_DIR:-}" && ! -w "$CCACHE_DIR" ]]; then
      sc_fail "ccache requires a writable $CCACHE_DIR sandbox mount; configure its directory, permissions and Nix sandbox-paths"
      return 1
    fi
  fi
  mkdir -p "$SC_BUILD_DIR" "$SC_OUT_DIR"
  export SOURCE_DATE_EPOCH=315532800 GIT_CEILING_DIRECTORIES="$SC_BUILD_DIR"
  export SC_BUILD_DIR SC_OUT_DIR SC_CCACHE JOBS SC_VERSION
}

# Both native and guest steps run only the programs supplied by Nix.
sc_store_path() {
  local directory kept=""
  local -a directories
  IFS=: read -ra directories <<< "$PATH"
  for directory in "${directories[@]}"; do
    [[ "$directory" != "${NIX_STORE:-/nix/store}"/* ]] || kept+="${kept:+:}$directory"
  done
  [[ -n "$kept" ]] || { sc_fail "PATH has no programs supplied by Nix"; return 1; }
  echo "$kept"
}

# Nixpkgs' native compiler hooks and flags must not reach guest compilation.
# A step can add a setting explicitly with sc_guest env NAME=value command.
SC_GUEST_ENVIRONMENT=(
  TMPDIR TERM JOBS SOURCE_DATE_EPOCH GIT_CEILING_DIRECTORIES 'SC_*' 'CCACHE_*'
)

sc_guest() {
  local entry pattern
  local -a step=(env -i "PATH=$PATH" HOME=/nonexistent)
  while IFS= read -r -d '' entry; do
    for pattern in "${SC_GUEST_ENVIRONMENT[@]}"; do
      if [[ "${entry%%=*}" == $pattern ]]; then
        step+=("$entry")
        break
      fi
    done
  done < <(env -0)
  "${step[@]}" "$@"
}

# Stage a writable source once in this build's fresh directory. Copy into an
# existing directory when composing declared vendored sources inside a tree.
sc_copy_source() {
  mkdir -p "$2" || return 1
  cp -R "$1/." "$2/" || return 1
  chmod -R u+w "$2"
}

# sc_strip level input output.wasm: the module a link wrote, as it is
# delivered. Binaryen's wasm-opt runs over it once, with the optimisation
# level the build links with (-O<level>, 0 for a link given none), keeping the
# name section, which it writes only with -g, so a profiler can name guest
# functions, and dropping any DWARF, which the link already leaves out
# (--strip-debug in toolchain/guest/guest.cfg).
sc_strip() {
  local level="$1"
  local input="$2"
  local output="$3"
  mkdir -p "$(dirname "$output")"
  BINARYEN_CORES="$JOBS" wasm-opt "-O$level" -g --strip-dwarf "$input" -o "$output"
  chmod +x "$output"
}

sc_assemble() {
  cp -a "$@" "$SC_OUT_DIR/"
  sed "s/{version}/$SC_VERSION/g" "$SC_MANIFEST" > "$SC_OUT_DIR/service.toml"
  "$SC_PYTHON" "$SC_TOOLCHAIN/guest_artifacts.py" "$SC_OUT_DIR" || return 1
  cp "$SERVICECACHE_METADATAPath" "$SC_OUT_DIR/build-info.json"
}
