#!/usr/bin/env bash

sc_fail() {
  echo "error: $*" >&2
  return 1
}

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
  SC_VERSION_DIR="$SC_SERVICE_DIR/versions/$SC_VERSION"
  SC_SRC="$SC_WORK/src/$SC_SERVICE/$SC_VERSION"
  SC_BUILD="$SC_WORK/build/$SC_SERVICE/$SC_VERSION"
  SC_OUT="$SC_WORK/services"

  if [[ ! -f "$SC_VERSION_DIR/version.env" ]]; then
    sc_fail "version configuration not found: $SC_VERSION_DIR/version.env"
    return 1
  fi

  source "$SC_VERSION_DIR/version.env"
  if [[ -f "$SC_SERVICE_DIR/versions.sh" ]]; then
    source "$SC_SERVICE_DIR/versions.sh"
  fi
  source "$SC_TOOLCHAIN/versions.sh"
  source "$SC_TOOLCHAIN/env.sh"

  export SC_SERVICE SC_VERSION SC_ROOT SC_WORK SC_TOOLCHAIN
  export SC_SERVICE_DIR SC_VERSION_DIR SC_SRC SC_BUILD SC_OUT
}

sc_clone_tag() {
  if [[ $# -ne 2 ]]; then
    sc_fail "usage: sc_clone_tag tag destination"
    return 1
  fi

  SC_UPSTREAM_TAG="$1"
  local destination="$2"
  local source_url="${SC_SOURCE_URL:?SC_SOURCE_URL is not set}"

  mkdir -p "$(dirname "$destination")"
  if [[ ! -e "$destination" ]]; then
    git clone --branch "$SC_UPSTREAM_TAG" --depth 1 --single-branch \
      "$source_url" "$destination"
  elif [[ ! -d "$destination/.git" ]]; then
    sc_fail "source path exists but is not a Git checkout: $destination"
    return 1
  fi

  local expected_commit actual_commit
  expected_commit="$(git -C "$destination" rev-list -n 1 "$SC_UPSTREAM_TAG" 2>/dev/null || true)"
  actual_commit="$(git -C "$destination" rev-parse HEAD)"
  if [[ -z "$expected_commit" || "$actual_commit" != "$expected_commit" ]]; then
    sc_fail "source checkout is not at the exact $SC_UPSTREAM_TAG commit"
    return 1
  fi

  export SC_UPSTREAM_TAG
}

sc_apply_series() {
  if [[ $# -ne 2 ]]; then
    sc_fail "usage: sc_apply_series patch-directory source-directory"
    return 1
  fi

  local patch_dir="$1"
  local source_dir="$2"
  local series_file="$patch_dir/series"
  local expected_tag="${SC_UPSTREAM_TAG:?sc_clone_tag must run before sc_apply_series}"

  if ! git -C "$source_dir" rev-parse --git-dir >/dev/null 2>&1; then
    sc_fail "not a Git checkout: $source_dir"
    return 1
  fi

  local expected_commit actual_commit
  expected_commit="$(git -C "$source_dir" rev-list -n 1 "$expected_tag" 2>/dev/null || true)"
  actual_commit="$(git -C "$source_dir" rev-parse HEAD)"
  if [[ -z "$expected_commit" || "$actual_commit" != "$expected_commit" ]]; then
    echo "patches require the exact $expected_tag commit" >&2
    echo "checkout HEAD: $actual_commit" >&2
    echo "expected:      ${expected_commit:-tag not found}" >&2
    return 1
  fi
  if [[ ! -f "$series_file" ]]; then
    sc_fail "patch series not found: $series_file"
    return 1
  fi

  # Every applied patch is recorded here with its content hash, so that a
  # rerun recognises it even when a later patch in the series changed the
  # same lines and the patch no longer reverse-applies on its own. The file
  # is untracked, so resetting the checkout (git clean) forgets it too.
  local stamp_file="$source_dir/.sc-applied"

  local patch_name patch_path patch_hash
  while IFS= read -r patch_name; do
    [[ -z "$patch_name" || "$patch_name" == \#* ]] && continue
    patch_path="$patch_dir/$patch_name"
    if [[ ! -f "$patch_path" ]]; then
      sc_fail "series entry not found: $patch_path"
      return 1
    fi
    patch_hash="$(sha256sum "$patch_path" | cut -d' ' -f1)"

    if [[ -f "$stamp_file" ]] && grep -qxF "$patch_hash  $patch_name" "$stamp_file"; then
      echo "already applied: $patch_name"
    elif git -C "$source_dir" apply --check --whitespace=error-all \
        "$patch_path" 2>/dev/null; then
      echo "applying $patch_name"
      git -C "$source_dir" apply --whitespace=error-all "$patch_path"
      echo "$patch_hash  $patch_name" >> "$stamp_file"
    elif git -C "$source_dir" apply --reverse --check \
        "$patch_path" 2>/dev/null; then
      echo "already applied: $patch_name"
      echo "$patch_hash  $patch_name" >> "$stamp_file"
    else
      echo "cannot apply cleanly: $patch_name" >&2
      echo "the checkout has partial or conflicting changes (a patch that changed after it was applied?);" >&2
      echo "reset it to the pristine tag and rerun: make clean-wasmer or clean-service-<name>-<version>" >&2
      return 1
    fi
  done < "$series_file"
}

sc_strip() {
  if [[ $# -ne 2 ]]; then
    sc_fail "usage: sc_strip input output.wasm"
    return 1
  fi

  local input="$1"
  local output="$2"
  if [[ ! -f "$input" ]]; then
    sc_fail "module not found: $input"
    return 1
  fi

  mkdir -p "$(dirname "$output")"
  "$WASIXCC_BINARYEN_LOCATION/bin/wasm-opt" --strip-debug "$input" -o "$output"
  chmod +x "$output"
}

sc_assemble() {
  if [[ $# -lt 1 ]]; then
    sc_fail "usage: sc_assemble artifact..."
    return 1
  fi

  SC_OUT_DIR="$SC_OUT/$SC_SERVICE-$SC_VERSION"
  local manifest="$SC_SERVICE_DIR/service.toml"
  if [[ -f "$SC_VERSION_DIR/service.toml" ]]; then
    manifest="$SC_VERSION_DIR/service.toml"
  fi
  if [[ ! -f "$manifest" ]]; then
    sc_fail "service manifest not found: $manifest"
    return 1
  fi

  rm -rf "$SC_OUT_DIR"
  mkdir -p "$SC_OUT_DIR"

  local artifact
  for artifact in "$@"; do
    if [[ ! -e "$artifact" ]]; then
      sc_fail "artifact not found: $artifact"
      return 1
    fi
    cp -a "$artifact" "$SC_OUT_DIR/"
  done
  sed "s/{version}/$SC_VERSION/g" "$manifest" > "$SC_OUT_DIR/service.toml"
  export SC_OUT_DIR
}

sc_write_build_info() {
  local out_dir="${SC_OUT_DIR:?sc_assemble must run before sc_write_build_info}"
  local upstream_tag="${SC_UPSTREAM_TAG:?sc_clone_tag must run before sc_write_build_info}"
  local servicecache_commit
  servicecache_commit="$(git -C "$SC_ROOT" rev-parse HEAD)"

  {
    echo "Service: $SC_SERVICE"
    echo "Version: $SC_VERSION"
    echo "Upstream tag: $upstream_tag"
    echo "ServiceCache commit: $servicecache_commit"
    echo "wasixcc: $WASIXCC_VERSION"
    echo "WASIX sysroot: $WASIX_SYSROOT_TAG"
    echo "WASIX LLVM: $WASIX_LLVM_TAG"
    echo "Binaryen: $BINARYEN_TAG"
    echo "Wasmer: $WASMER_VERSION"
  } > "$out_dir/BUILD-INFO"
}
