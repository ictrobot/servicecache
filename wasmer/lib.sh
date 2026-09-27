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
  local root set patch patches
  root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  {
    echo "v$WASMER_VERSION"
    for set in $WASMER_PATCH_SETS; do
      patches="$(sc_patch_names "$root/$set")" || return 1
      while IFS= read -r patch; do
        cat "$root/$set/$patch"
      done <<< "$patches"
    done
  } | sha256sum | cut -d' ' -f1
}

# sc_wasmer_dev_sets: the stacked branches of a Wasmer dev checkout, one
# "from to set-directory" line per patch set, innermost first.
sc_wasmer_dev_sets() {
  echo "v$WASMER_VERSION fixes wasmer/fixes/patches"
  echo "fixes ictrobot_shm_v1 extensions/ictrobot_shm_v1/patches"
  echo "ictrobot_shm_v1 jitdump wasmer/jitdump/patches"
  echo "jitdump servicecache wasmer/servicecache/patches"
}

# sc_wasmer_comparable <patch>: all content except its modification date.
sc_wasmer_comparable() {
  sed '/^Last-Update:/d' "$1"
}

# sc_wasmer_patch_date <previous> <current> <today>: the date an exported
# patch carries. It keeps the date of the previous file of the same name
# when their contents match apart from Last-Update, and is today otherwise.
sc_wasmer_patch_date() {
  local previous="$1" current="$2" today="$3" date=""
  if [[ -f "$previous" ]] &&
     diff -q <(sc_wasmer_comparable "$previous") <(sc_wasmer_comparable "$current") >/dev/null 2>&1; then
    date="$(sed -n '/^diff --git/q; s/^Last-Update:[ \t]*//p' "$previous" | head -n 1)"
  fi
  echo "${date:-$today}"
}

# sc_wasmer_insert_date <patch> <date>: put the Last-Update line after the
# Subject field, continuation lines included.
sc_wasmer_insert_date() {
  local patch="$1" date="$2"
  awk -v date="$date" '
    !placed && subject && $0 !~ /^[ \t]/ { print "Last-Update: " date; placed = 1 }
    /^Subject:/ && !subject { subject = 1 }
    { print }
    END { if (subject && !placed) print "Last-Update: " date }
  ' "$patch" > "$patch.dated" || return 1
  mv "$patch.dated" "$patch"
}

# sc_wasmer_export_range <checkout> <from> <to> <directory> [previous]:
# write the commits from..to as the directory's patch series. Each file keeps
# its Subject and body and then the diff, like the service patches, with a
# Last-Update line after the Subject. format-patch knows
# nothing of that line, so it is carried across from the set in previous
# (default: the directory as it was). Unchanged content keeps its date;
# descriptions, hunk positions and index hashes all count as changes.
# Exporting an unchanged branch reproduces the set byte for byte.
sc_wasmer_export_range() {
  local checkout="$1" from="$2" to="$3" patch_dir="$4" previous="${5:-$4}"
  local patch today kept status=0
  today="$(date +%F)"
  kept="$(mktemp -d)" || return 1
  if [[ -d "$previous" ]]; then
    find "$previous" -maxdepth 1 -name '*.patch' -exec cp -- {} "$kept/" \; || {
      rm -rf "$kept"
      return 1
    }
  fi
  mkdir -p "$patch_dir"
  rm -f "$patch_dir"/*.patch
  git -C "$checkout" format-patch --keep-subject --no-signature --quiet \
    -o "$patch_dir" "$from..$to" || status=1
  for patch in "$patch_dir"/*.patch; do
    (( status )) && break
    [[ -f "$patch" ]] || continue
    sed -i \
      -e '1,/^Subject:/{/^Subject:/!d}' \
      -e '/^---$/,/^diff --git/{/^diff --git/!d}' \
      -e '0,/^diff --git/s//\n&/' \
      "$patch" &&
      sc_wasmer_insert_date "$patch" \
        "$(sc_wasmer_patch_date "$kept/${patch##*/}" "$patch" "$today")" || status=1
  done
  rm -rf "$kept"
  return "$status"
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
