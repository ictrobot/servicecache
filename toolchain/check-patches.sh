#!/usr/bin/env bash
# Check patch headers, and each patch's Last-Update against the Git history of
# what that date is for (sc_patch_content).
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
source toolchain/lib.sh
export LC_ALL=C
today="$(date +%F)"
count=0
fail() { echo "$*" >&2; exit 1; }

# content_date patch: today while the patch's content differs from HEAD's,
# otherwise the author date of the newest commit that changed it.
content_date() {
  local patch="$1" commit date
  if ! git cat-file -e "HEAD:$patch" 2>/dev/null ||
     ! cmp -s <(sc_patch_content "$patch") <(git show "HEAD:$patch" | sc_patch_content); then
    echo "$today"
    return
  fi
  while read -r commit date; do
    if ! git cat-file -e "$commit^:$patch" 2>/dev/null ||
       ! cmp -s <(git show "$commit:$patch" | sc_patch_content) \
         <(git show "$commit^:$patch" | sc_patch_content); then
      echo "$date"
      return
    fi
  done < <(git log --format='%H %as' -- "$patch")
}

while IFS= read -r -d '' patch; do
  [[ "${patch##*/}" =~ ^[0-9]{4}-.+\.patch$ ]] || fail "$patch: expected NNNN-name.patch"
  [[ ! -L "$patch" ]] || continue
  awk '
    /^(diff --git |--- )/ { exit }
    /^Subject:/ { subjects++; subject = ($0 ~ /^Subject:[ \t]*[^ \t]/ && $0 !~ /^Subject:[ \t]*\[PATCH/) }
    /^$/ { body = 1 }
    body && NF && !/^[[:alnum:]-]+:/ { description = 1 }
    END { exit !(subjects == 1 && subject && description) }
  ' "$patch" || fail "$patch: expected one nonempty Subject without a [PATCH] prefix and a description before the diff"
  stated="$(sed -En '/^(diff --git |--- )/q; s/[ \t]*$//; s/^Last-Update:[ \t]*//p' "$patch")"
  expected="$(content_date "$patch")"
  [[ -n "$expected" && "$stated" == "$expected" ]] ||
    fail "$patch: expected Last-Update: $expected, got ${stated:-none}"
  count=$((count + 1))
done < <(git ls-files -z '*.patch')
(( count > 0 )) || fail "no patches found"
echo "$count patches checked"
