# Shared helpers for the wasmer/ scripts. Not a script; sourced by them
# after toolchain/lib.sh.

: "${WASMER_VERSION=$(cat "$(dirname "${BASH_SOURCE[0]}")/version")}"

# sc_wasmer_load_variant <variant>: sets WASMER_VARIANT, WASMER_PATCH_SETS
# (repo-relative patch set directories, in application order) and
# WASMER_VARIANT_TREE from wasmer/<variant>/patches.list.
sc_wasmer_load_variant() {
  local root
  root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  WASMER_VARIANT="${1:?usage: sc_wasmer_load_variant variant}"
  local list="$root/wasmer/$WASMER_VARIANT/patches.list"
  if [[ ! -f "$list" ]]; then
    echo "unknown Wasmer variant: $WASMER_VARIANT (no $list)" >&2
    return 1
  fi
  WASMER_PATCH_SETS="$(sed '/^[[:space:]]*#/d; /^[[:space:]]*$/d' "$list")"
  WASMER_VARIANT_TREE="$root/work/src/wasmer/$WASMER_VARIANT"
}

# sc_wasmer_dev_sets: the stacked branches of a Wasmer dev checkout, one
# "from to set-directory" line per patch set, innermost first.
sc_wasmer_dev_sets() {
  echo "v$WASMER_VERSION fixes wasmer/fixes/patches"
  echo "fixes ictrobot_shm_v1 extensions/ictrobot_shm_v1/patches"
  echo "ictrobot_shm_v1 jitdump wasmer/jitdump/patches"
  echo "jitdump servicecache wasmer/servicecache/patches"
}

# sc_wasmer_check_notices <checkout> <from> <to>: fail unless every file
# that a commit in from..to modifies, and that Wasmer marks as containing
# code from external sources, carries a change notice after that commit.
sc_wasmer_check_notices() {
  local checkout="$1" from="$2" to="$3" commit commits file files content status=0
  commits="$(git -C "$checkout" rev-list --reverse "$from..$to")" || return 1
  for commit in $commits; do
    files="$(git -C "$checkout" diff --name-only --diff-filter=M "$commit^" "$commit")" || return 1
    while IFS= read -r file; do
      [[ -n "$file" ]] || continue
      content="$(git -C "$checkout" show "$commit^:$file")" || return 1
      grep -qF 'This file contains code from external sources' <<< "$content" || continue
      content="$(git -C "$checkout" show "$commit:$file")" || return 1
      if ! grep -qE '^// Modified (for ServiceCache|to add the [^ ]+ extension)' <<< "$content"; then
        echo "$to: ${commit:0:7} modifies $file, which has no change notice" >&2
        status=1
      fi
    done <<< "$files"
  done
  return "$status"
}

# sc_wasmer_patch_date <previous> <current> <today>: the date an exported
# patch carries. It keeps the date of the previous file of the same name
# while their sc_patch_content matches, and is today otherwise.
sc_wasmer_patch_date() {
  local previous="$1" current="$2" today="$3" date=""
  if [[ -f "$previous" ]] &&
     diff -q <(sc_patch_content "$previous") <(sc_patch_content "$current") >/dev/null 2>&1; then
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
# (default: the directory as it was), and kept while the patch's
# description and changed lines are the same (sc_patch_content).
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

# sc_git_cache url tag: prints the bare repository shared by every checkout
# of the remote, work/git/<url with non-alphanumerics as underscores>, with
# the tag fetched into it alone and at depth 1.
sc_git_cache() {
  if [[ $# -ne 2 ]]; then
    sc_fail "usage: sc_git_cache url tag"
    return 1
  fi

  local url="$1" tag="$2" root cache
  root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  cache="$root/work/git/${url//[^[:alnum:]]/_}"
  if [[ ! -d "$cache" ]]; then
    git init --quiet --bare "$cache"
  fi
  if ! git --git-dir="$cache" rev-parse --verify --quiet "refs/tags/$tag^{commit}" >/dev/null; then
    git --git-dir="$cache" fetch --depth=1 --no-tags "$url" tag "$tag"
  fi
  echo "$cache"
}

# sc_checkout url tag tree: the tag checked out at tree, detached, as a
# worktree of the bare repository sc_git_cache keeps for the remote.
sc_checkout() {
  if [[ $# -ne 3 ]]; then
    sc_fail "usage: sc_checkout url tag tree"
    return 1
  fi

  local url="$1" tree="$3"
  SC_UPSTREAM_TAG="$2"

  if [[ ! -e "$tree" ]]; then
    local cache
    cache="$(sc_git_cache "$url" "$SC_UPSTREAM_TAG")" || return 1
    mkdir -p "$(dirname "$tree")"
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

# sc_series_stamps patch-directory...: the .sc-applied lines that applying
# the series in order leaves behind.
sc_series_stamps() {
  local patch_dir patch_name patches
  for patch_dir in "$@"; do
    patches="$(sc_patch_names "$patch_dir")" || return 1
    while IFS= read -r patch_name; do
      echo "$(sha256sum "$patch_dir/$patch_name" | cut -d' ' -f1)  $patch_name"
    done <<< "$patches"
  done
}

# sc_reset_if_stale tree [patch-directory...]: reset a checkout to the tag
# when its .sc-applied stamp is not a prefix of what the series would
# leave (after a branch switch, typically), or when it is modified with no
# stamp at all, so the sc_apply_series calls that follow start clean.
# Build directories are left alone.
sc_reset_if_stale() {
  if [[ $# -lt 1 ]]; then
    sc_fail "usage: sc_reset_if_stale tree [patch-directory...]"
    return 1
  fi

  local tree="$1"
  shift
  if [[ ! -e "$tree/.git" ]]; then
    return 0
  fi

  local stamp_file="$tree/.sc-applied" reason
  if [[ -f "$stamp_file" ]]; then
    local expected applied
    expected="$(sc_series_stamps "$@")" || return 1
    applied="$(cat "$stamp_file")"
    if [[ -z "$applied" || "$expected"$'\n' == "$applied"$'\n'* ]]; then
      return 0
    fi
    reason="its applied patches are not the current series"
  elif [[ -n "$(git -C "$tree" status --porcelain --untracked-files=no)" ]]; then
    reason="it has changes but no record of applied patches"
  else
    return 0
  fi

  echo "resetting ${tree}: $reason" >&2
  git -C "$tree" reset --quiet --hard &&
    git -C "$tree" clean --quiet -fdx
}

sc_apply_series() {
  if [[ $# -ne 2 ]]; then
    sc_fail "usage: sc_apply_series patch-directory source-directory"
    return 1
  fi

  local patch_dir="$1"
  local source_dir="$2"
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
  # Every applied patch is recorded here with its content hash, so that a
  # rerun recognises it even when a later patch in the series changed the
  # same lines and the patch no longer reverse-applies on its own. The file
  # is untracked, so resetting the checkout (git clean) forgets it too.
  local stamp_file="$source_dir/.sc-applied"

  local patch_name patch_path patch_hash patches
  patches="$(sc_patch_names "$patch_dir")" || return 1
  while IFS= read -r patch_name; do
    patch_path="$patch_dir/$patch_name"
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
      echo "remove $source_dir and rerun make setup-wasmer" >&2
      return 1
    fi
  done <<< "$patches"
}
