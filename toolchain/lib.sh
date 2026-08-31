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

  # Only the version's own declaration counts: an inherited value would
  # silently change the CLI below and the assembly gate.
  unset SC_GUEST_EXTENSIONS

  source "$SC_VERSION_DIR/version.env"
  if [[ -f "$SC_SERVICE_DIR/versions.sh" ]]; then
    source "$SC_SERVICE_DIR/versions.sh"
  fi
  source "$SC_TOOLCHAIN/versions.sh"
  source "$SC_TOOLCHAIN/env.sh"

  # The Wasmer CLI this package's modules run under, picked up by
  # run-wasix.sh for smoke tests and build-time execution: stock, or the
  # extensions variant when the version declares SC_GUEST_EXTENSIONS.
  SC_WASMER="$SC_WORK/wasmer/stock/bin/wasmer"
  if [[ -n "${SC_GUEST_EXTENSIONS:-}" ]]; then
    SC_WASMER="$SC_WORK/wasmer/extensions/bin/wasmer"
    echo "$SC_SERVICE $SC_VERSION: extensions $SC_GUEST_EXTENSIONS," \
      "modules run under ${SC_WASMER#"$SC_ROOT/"}" >&2
  fi

  export SC_SERVICE SC_VERSION SC_ROOT SC_WORK SC_TOOLCHAIN SC_WASMER
  export SC_SERVICE_DIR SC_VERSION_DIR SC_SRC SC_BUILD SC_OUT
}

# sc_checkout url tag tree: the tag checked out at tree, detached, as a
# worktree of a bare repository shared by every checkout of the same
# remote, work/git/<url with non-alphanumerics as underscores>. A tag is
# fetched alone and at depth 1, so versions of one project share their
# objects.
sc_checkout() {
  if [[ $# -ne 3 ]]; then
    sc_fail "usage: sc_checkout url tag tree"
    return 1
  fi

  local url="$1" tree="$3"
  SC_UPSTREAM_TAG="$2"
  local root
  root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  local cache="$root/work/git/${url//[^[:alnum:]]/_}"

  if [[ ! -e "$tree" ]]; then
    mkdir -p "$(dirname "$tree")"
    if [[ ! -d "$cache" ]]; then
      git init --quiet --bare "$cache"
    fi
    if ! git --git-dir="$cache" rev-parse --verify --quiet "refs/tags/$SC_UPSTREAM_TAG^{commit}" >/dev/null; then
      git --git-dir="$cache" fetch --depth=1 --no-tags "$url" tag "$SC_UPSTREAM_TAG"
    fi
    git --git-dir="$cache" worktree prune
    git --git-dir="$cache" worktree add --quiet --detach "$tree" "refs/tags/$SC_UPSTREAM_TAG"
  elif ! git -C "$tree" rev-parse --git-dir >/dev/null 2>&1; then
    sc_fail "source path exists but is not a Git checkout: $tree"
    return 1
  fi

  local expected_commit actual_commit
  expected_commit="$(git -C "$tree" rev-list -n 1 "$SC_UPSTREAM_TAG" 2>/dev/null || true)"
  actual_commit="$(git -C "$tree" rev-parse HEAD)"
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
  local expected_tag="${SC_UPSTREAM_TAG:?sc_checkout must run before sc_apply_series}"

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
      echo "reset it to the pristine tag and rerun: make clean-wasmer, clean-wasix-libc or clean-service-<name>-<version>" >&2
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
  sc_check_guest_imports "$SC_OUT_DIR" || return 1
  export SC_OUT_DIR
}

# Baseline WASIX import namespaces: what a plain WASIX program references.
SC_BASELINE_IMPORTS="env wasi wasi_snapshot_preview1 wasix_32v1"

# SC_GUEST_EXTENSIONS, from the version's version.env, enables extensions
# for a package: space-separated import namespaces its modules may
# reference beyond the baseline, each specified in extensions/<name>/ and
# listed under `extensions` in service.toml.
#
# The manifest may list more than the built modules import, never less: it is
# the allowance for every module the service loads, including ones it does not
# name. Checked here at assembly — the stock Wasmer CLI reads each module's
# import section — and recorded in BUILD-INFO.
#
# Only import extensions in permissively licensed modules (ARCHITECTURE.md,
# Extensions); never set the variable to clear an import-check failure.
sc_check_guest_imports() {
  local out_dir="$1"
  local wasmer="$SC_ROOT/work/wasmer/stock/bin/wasmer"
  if [[ ! -x "$wasmer" ]]; then
    sc_fail "stock Wasmer is required to check guest imports: run make wasmer-stock"
    return 1
  fi

  local allowed=" $SC_BASELINE_IMPORTS " declared=" " line namespace
  for namespace in ${SC_GUEST_EXTENSIONS:-}; do
    allowed+="$namespace "
    declared+="$namespace "
  done

  local manifest_exts=" "
  line="$(grep -E '^extensions *= *\[' "$out_dir/service.toml" || true)"
  if [[ -n "$line" ]]; then
    while IFS= read -r namespace; do
      manifest_exts+="$namespace "
    done < <(grep -oE '"[^"]+"' <<< "$line" | tr -d '"')
  fi
  # The two declarations must name the same namespaces: a manifest entry
  # SC_GUEST_EXTENSIONS does not declare would have the host register a
  # namespace the package never built or smoke-tested against.
  local ok=1
  for namespace in $declared; do
    [[ "$manifest_exts" == *" $namespace "* ]] || {
      sc_fail "SC_GUEST_EXTENSIONS declares $namespace but service.toml has no matching extensions entry"
      ok=0
    }
  done
  for namespace in $manifest_exts; do
    [[ "$declared" == *" $namespace "* ]] || {
      sc_fail "service.toml lists extension $namespace but SC_GUEST_EXTENSIONS does not declare it"
      ok=0
    }
  done
  [[ $ok -eq 1 ]] || return 1

  # Every file in the package with the WebAssembly magic is checked,
  # wherever it sits and whatever its name: assembly may ship a module
  # under a second name, or in a subdirectory, for a guest that executes
  # it by path. Symlinks are followed, so a linked module is checked too.
  local module namespaces bad=0
  while IFS= read -r -d '' module; do
    [[ "$(head -c 4 "$module" | od -An -tx1 | tr -d ' \n')" == "0061736d" ]] || continue
    namespaces="$("$wasmer" inspect "$module" | sed -n 's/^ *"\([^"]*\)"\..*/\1/p' | sort -u)" || {
      sc_fail "could not inspect ${module#"$out_dir"/}"
      return 1
    }
    for namespace in $namespaces; do
      if [[ "$allowed" != *" $namespace "* ]]; then
        sc_fail "${module#"$out_dir"/} imports namespace $namespace, outside the WASIX baseline and SC_GUEST_EXTENSIONS (see SC_BASELINE_IMPORTS in toolchain/lib.sh)"
        bad=1
      fi
    done
  done < <(find -L "$out_dir" -type f -print0)
  [[ $bad -eq 0 ]]
}

# The content hash of the patch series the sysroot's libc carries
# (patches/wasix-libc, in series order): what toolchain/bootstrap.sh stamps
# each rebuilt libc.a with, and what BUILD-INFO records.
sc_sysroot_patch_hash() {
  local root patch_dir patch
  root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  patch_dir="$root/patches/wasix-libc"
  while IFS= read -r patch; do
    [[ -z "$patch" || "$patch" == \#* ]] && continue
    cat "$patch_dir/$patch"
  done < "$patch_dir/series" | sha256sum | cut -d' ' -f1
}

sc_write_build_info() {
  local out_dir="${SC_OUT_DIR:?sc_assemble must run before sc_write_build_info}"
  local upstream_tag="${SC_UPSTREAM_TAG:?sc_checkout must run before sc_write_build_info}"
  local servicecache_commit
  servicecache_commit="$(git -C "$SC_ROOT" rev-parse HEAD)"

  {
    echo "Service: $SC_SERVICE"
    echo "Version: $SC_VERSION"
    echo "Upstream tag: $upstream_tag"
    echo "ServiceCache commit: $servicecache_commit"
    echo "wasixcc: $WASIXCC_VERSION"
    echo "WASIX sysroot: $WASIX_SYSROOT_TAG"
    echo "WASIX sysroot patches: $(sc_sysroot_patch_hash)"
    echo "WASIX LLVM: $WASIX_LLVM_TAG"
    echo "Binaryen: $BINARYEN_TAG"
    echo "Wasmer: $WASMER_VERSION"
    echo "Guest extensions: ${SC_GUEST_EXTENSIONS:-none}"
  } > "$out_dir/BUILD-INFO"
}
