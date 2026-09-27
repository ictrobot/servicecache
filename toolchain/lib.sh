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

# sc_init service version: what a service's smoke test begins with. It sets
# where the built service is looked for, work/services (SC_OUT), and the
# Wasmer CLI toolchain/run-wasix.sh runs its modules under (SC_WASMER): stock,
# or the extensions variant when the manifest declares extensions.
sc_init() {
  if [[ $# -ne 2 ]]; then
    sc_fail "usage: sc_init service version"
    return 1
  fi

  SC_SERVICE="$1"
  SC_VERSION="$2"
  SC_TOOLCHAIN="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  SC_ROOT="$(cd "$SC_TOOLCHAIN/.." && pwd)"
  SC_WORK="$SC_ROOT/work"
  SC_SERVICE_DIR="$SC_ROOT/services/$SC_SERVICE"
  SC_OUT="$SC_WORK/services"

  local manifest="$SC_OUT/$SC_SERVICE-$SC_VERSION/service.toml" extensions
  [[ -f "$manifest" ]] || { sc_fail "built service manifest not found: $manifest"; return 1; }
  extensions="$("$(sc_python)" -c 'import sys, tomllib
with open(sys.argv[1], "rb") as f:
    print(" ".join(tomllib.load(f)["service"].get("extensions", [])))' "$manifest")" || return 1

  local variant=stock
  if [[ -n "$extensions" ]]; then
    variant=extensions
  fi
  "$SC_ROOT/wasmer/build.sh" "$variant" >/dev/null || return 1
  SC_WASMER="$SC_WORK/wasmer/$variant/bin/wasmer"
  if [[ -n "$extensions" ]]; then
    echo "$SC_SERVICE $SC_VERSION: extensions $extensions," \
      "modules run under ${SC_WASMER#"$SC_ROOT/"}" >&2
  fi

  export SC_SERVICE SC_VERSION SC_ROOT SC_WORK SC_TOOLCHAIN SC_WASMER
  export SC_SERVICE_DIR SC_OUT
}
