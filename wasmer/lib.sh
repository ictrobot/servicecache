# Shared helpers for the wasmer/ scripts. Not a script; sourced by them
# after toolchain/lib.sh and toolchain/versions.sh.

# sc_wasmer_load_variant <variant>: sets WASMER_VARIANT, WASMER_PATCH_SETS
# (repo-relative patch set directories, in application order) and
# WASMER_VARIANT_TREE from wasmer/<variant>/variant.env.
sc_wasmer_load_variant() {
  local root
  root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  WASMER_VARIANT="${1:?usage: sc_wasmer_load_variant variant}"
  local variant_env="$root/wasmer/$WASMER_VARIANT/variant.env"
  if [[ ! -f "$variant_env" ]]; then
    echo "unknown wasmer variant: $WASMER_VARIANT (no $variant_env)" >&2
    return 1
  fi
  WASMER_PATCH_SETS=""
  # shellcheck source=/dev/null
  source "$variant_env"
  WASMER_VARIANT_TREE="$root/work/src/wasmer/$WASMER_VARIANT"
}

# sc_wasmer_sets_hash: content hash of the loaded variant's patch sets (and
# the pinned tag), for stamping built CLIs so a changed series rebuilds.
sc_wasmer_sets_hash() {
  local root set patch
  root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  {
    echo "v$WASMER_VERSION"
    for set in $WASMER_PATCH_SETS; do
      while IFS= read -r patch; do
        [[ -z "$patch" || "$patch" == \#* ]] && continue
        cat "$root/$set/$patch"
      done < "$root/$set/series"
    done
  } | sha256sum | cut -d' ' -f1
}

# sc_wasmer_napi_submodule <tree>: lib/cli needs the wasmer-napi submodule
# before cargo can load the workspace manifest; nothing the host embeds does.
sc_wasmer_napi_submodule() {
  git -C "$1" submodule update --init --depth 1 lib/napi >/dev/null 2>&1 ||
    git -C "$1" submodule update --init lib/napi || {
      echo "could not check out the wasmer-napi submodule that lib/cli needs" >&2
      return 1
    }
}
