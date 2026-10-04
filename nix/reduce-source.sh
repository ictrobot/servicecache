#!/usr/bin/env bash
# Replaces an unpacked archive with a sparse checkout of it, so archives and
# Git sources share Git's pattern matching and neither keeps empty directories.
set -euo pipefail
source="${1:?source directory}"
sparse="${2:?sparse-checkout patterns file}"
checked="${3:?checked patterns file}"

# Git would record a nested repository as a link and leave out its files.
if [[ -n "$(find "$source" -name .git -print -quit)" ]]; then
  echo "source archive contains .git" >&2
  exit 1
fi

# Move the archive aside so the checkout writes into an empty directory.
work="$(mktemp -d)"
mv "$source" "$work/unpacked"
mkdir "$source"
# The caller may have been inside the directory that moved.
cd "$source"

# A temporary repository outside the tree, unaffected by any Git configuration
# on the machine. Its objects are discarded, so they are not compressed.
export GIT_DIR="$work/git" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
git init --quiet --bare
git config core.compression 0

# Keep the archive's file contents exactly: no attributes apply while adding
# or checking out, whether from the archive's own .gitattributes or the system.
GIT_ATTR_SOURCE="$(git mktree </dev/null)"
export GIT_ATTR_SOURCE GIT_ATTR_NOSYSTEM=1
git config core.autocrlf false
git config core.attributesFile /dev/null

# Add every file. --force includes the ones the archive's own .gitignore
# files would leave out.
export GIT_WORK_TREE="$work/unpacked"
git add --force --all
bash "$(dirname "$0")/check-selection.sh" "$checked"

# Check out the selected files. Without an index every file is new to Git, so
# it writes each one the patterns keep.
tree="$(git write-tree)"
rm "$GIT_DIR/index"
GIT_WORK_TREE="$source"
git sparse-checkout set --no-cone --stdin <"$sparse"
git read-tree -mu "$tree"

rm -rf "$work"
