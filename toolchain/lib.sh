#!/usr/bin/env bash

sc_fail() {
  echo "error: $*" >&2
  return 1
}

# sc_patch_names patch-directory: print every patch name in bytewise filename
# order. The sequence number in each name is the patch application order.
sc_patch_names() {
  if [[ $# -ne 1 ]]; then
    sc_fail "usage: sc_patch_names patch-directory"
    return 1
  fi

  local patch_dir="$1" patch name
  local LC_ALL=C
  local -a patches=("$patch_dir"/*.patch)
  if [[ ! -f "${patches[0]}" ]]; then
    sc_fail "no patch files found in $patch_dir"
    return 1
  fi
  for patch in "${patches[@]}"; do
    name="${patch##*/}"
    if [[ ! "$name" =~ ^[0-9]{4}-.+\.patch$ ]]; then
      sc_fail "patch filename must start with a four-digit sequence number: $patch"
      return 1
    fi
    printf '%s\n' "$name"
  done
}

# sc_patch_content [patch]: the part of a patch its Last-Update date is for,
# from the file or standard input: the Subject and description without the
# Last-Update line, then only the diff's removed and added lines. Index
# hashes, hunk positions and context lines change when the tree under the
# patch does, while the change itself stays the same.
sc_patch_content() {
  awk '/^diff --git / { diff = 1 } diff ? /^[-+]/ : !/^Last-Update:/' "$@"
}

# Use the configured interpreter, or python3, for all host Python commands.
sc_python() {
  SC_PYTHON="${SC_PYTHON:-python3}"
  if ! "$SC_PYTHON" -c 'import sys; sys.exit(sys.version_info < (3, 11))' >/dev/null 2>&1; then
    sc_fail "$SC_PYTHON must be Python 3.11 or newer; set SC_PYTHON to the interpreter to use"
    return 1
  fi
  export SC_PYTHON
  printf '%s\n' "$SC_PYTHON"
}

# sc_smoke_init service version: what a service's smoke test begins with. It
# sets where the built service is looked for, work/services (SC_OUT).
# SC_WASMER must name the Wasmer CLI toolchain/run-wasix.sh runs the modules
# under; `./x smoke` sets it to the variant the service's manifest needs.
sc_smoke_init() {
  if [[ $# -ne 2 ]]; then
    sc_fail "usage: sc_smoke_init service version"
    return 1
  fi

  SC_SERVICE="$1"
  SC_VERSION="$2"
  SC_TOOLCHAIN="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  SC_ROOT="$(cd "$SC_TOOLCHAIN/.." && pwd)"
  SC_WORK="$SC_ROOT/work"
  SC_SERVICE_DIR="$SC_ROOT/services/$SC_SERVICE"
  SC_OUT="$SC_WORK/services"

  local manifest="$SC_OUT/$SC_SERVICE-$SC_VERSION/service.toml"
  [[ -f "$manifest" ]] || { sc_fail "built service manifest not found: $manifest"; return 1; }
  if [[ -z "${SC_WASMER:-}" ]]; then
    sc_fail "SC_WASMER must name the Wasmer CLI to run $SC_SERVICE $SC_VERSION under ('./x smoke' sets it)"
    return 1
  fi
  [[ -x "$SC_WASMER" ]] || { sc_fail "SC_WASMER is not an executable: $SC_WASMER"; return 1; }

  export SC_SERVICE SC_VERSION SC_ROOT SC_WORK SC_TOOLCHAIN SC_WASMER
  export SC_SERVICE_DIR SC_OUT
}
