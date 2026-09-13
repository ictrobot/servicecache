#!/usr/bin/env bash
set -euo pipefail

# wasmer/setup-dev.sh [checkout]: put the branches export-patches.sh reads
# at the committed patch sets in the Wasmer dev checkout (default:
# work/wasmer-dev), cloning it when missing. A branch whose export no
# longer reproduces its set is rebuilt with git am, along with the
# branches stacked on it; old tips stay in the reflog and no other branch
# is touched.

root="$(cd "$(dirname "$0")/.." && pwd)"
source "$root/toolchain/lib.sh"
source "$root/toolchain/versions.sh"
source "$root/wasmer/lib.sh"

checkout="${1:-$root/work/wasmer-dev}"
tag="v$WASMER_VERSION"
: "${SC_SOURCE_URL:=https://github.com/wasmerio/wasmer.git}"

if [[ ! -e "$checkout" ]]; then
  cache="$(sc_git_cache "$SC_SOURCE_URL" "$tag")"
  git clone --quiet --no-checkout "$cache" "$checkout"
  git -C "$checkout" checkout --quiet --detach "$tag"
  echo "cloned $checkout at $tag"
elif [[ ! -d "$checkout" ]] ||
     [[ "$(git -C "$checkout" rev-parse --show-toplevel 2>/dev/null || true)" != "$(cd "$checkout" && pwd -P)" ]]; then
  # An empty directory would resolve to the repository enclosing it.
  echo "$checkout is not the root of a Git checkout" >&2
  exit 1
elif ! git -C "$checkout" rev-parse --verify --quiet "$tag^{commit}" >/dev/null; then
  git -C "$checkout" fetch --depth=1 --no-tags "$SC_SOURCE_URL" tag "$tag"
fi

# branch_current from to set-directory: to is stacked on from and exporting
# from..to reproduces the set. The export alone cannot tell a branch left
# on an older from, since a range only subtracts.
branch_current() {
  local from="$1" to="$2" set_dir="$3" export_dir patch same=1
  git -C "$checkout" rev-parse --verify --quiet "refs/heads/$to" >/dev/null || return 1
  git -C "$checkout" merge-base --is-ancestor "$from" "$to" 2>/dev/null || return 1
  export_dir="$(mktemp -d "$root/work/wasmer-dev-export.XXXXXX")"
  if sc_wasmer_export_range "$checkout" "$from" "$to" "$export_dir" 2>/dev/null &&
     cmp -s "$export_dir/series" "$set_dir/series"; then
    while IFS= read -r patch; do
      if ! cmp -s "$export_dir/$patch" "$set_dir/$patch"; then
        same=0
        break
      fi
    done < "$set_dir/series"
  else
    same=0
  fi
  rm -rf "$export_dir"
  (( same ))
}

sets=()
while IFS= read -r line; do
  sets+=("$line")
done < <(sc_wasmer_dev_sets)

first_stale=-1
for i in "${!sets[@]}"; do
  read -r from to set_dir <<< "${sets[$i]}"
  if ! branch_current "$from" "$to" "$root/$set_dir"; then
    first_stale=$i
    break
  fi
  echo "$to holds $set_dir"
done
if (( first_stale < 0 )); then
  echo "the dev checkout's branches hold the committed patch sets"
  exit 0
fi

# The checked-out branch cannot be moved; it is detached and reattached.
current="$(git -C "$checkout" symbolic-ref --quiet --short HEAD || true)"
reattach=""
for ((i = first_stale; i < ${#sets[@]}; i++)); do
  read -r from to set_dir <<< "${sets[$i]}"
  if [[ "$to" == "$current" ]]; then
    if [[ -n "$(git -C "$checkout" status --porcelain --untracked-files=no)" ]]; then
      echo "$checkout has $to checked out with uncommitted changes;" \
        "commit or stash them, then rerun" >&2
      exit 1
    fi
    reattach="$to"
  fi
done

# The exported patches carry no author, which git am requires.
ident="$(git -C "$checkout" var GIT_AUTHOR_IDENT)"
ident="${ident% *}"
ident="${ident% *}"

worktree="$(mktemp -d "$root/work/wasmer-dev-rebuild.XXXXXX")"
cleanup() {
  git -C "$checkout" worktree remove --force "$worktree" 2>/dev/null || true
  rm -rf "$worktree"
  if [[ -n "$reattach" ]] && ! git -C "$checkout" symbolic-ref --quiet HEAD >/dev/null; then
    git -C "$checkout" checkout --quiet "$reattach"
  fi
}
trap cleanup EXIT

if [[ -n "$reattach" ]]; then
  git -C "$checkout" checkout --quiet --detach
fi
read -r from _ _ <<< "${sets[$first_stale]}"
git -C "$checkout" worktree add --quiet --detach "$worktree" "$from"

for ((i = first_stale; i < ${#sets[@]}; i++)); do
  read -r from to set_dir <<< "${sets[$i]}"
  old="$(git -C "$checkout" rev-parse --verify --quiet --short "refs/heads/$to" || true)"
  git -C "$worktree" checkout --quiet --detach "$from"
  while IFS= read -r patch; do
    [[ -z "$patch" || "$patch" == \#* ]] && continue
    {
      echo "From 0000000000000000000000000000000000000000 Mon Sep 17 00:00:00 2001"
      echo "From: $ident"
      cat "$root/$set_dir/$patch"
    } | git -C "$worktree" -c commit.gpgsign=false am --quiet --keep || {
      echo "could not apply $set_dir/$patch on $from" >&2
      exit 1
    }
  done < "$root/$set_dir/series"
  git -C "$worktree" branch --force "$to" HEAD
  echo "rebuilt $to from $set_dir${old:+ (was $old, still in its reflog)}"
done
