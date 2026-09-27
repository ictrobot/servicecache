#!/usr/bin/env bash
# Check patch headers and dates against the maximum Git author date for each path.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
export LC_ALL=C
today="$(date +%F)"
count=0
fail() { echo "$*" >&2; exit 1; }

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
  dates="$(git log --format=%as -- "$patch")"
  changed="$(git diff --name-only HEAD -- "$patch")"
  [[ -z "$changed" ]] || dates+=$'\n'"$today"
  expected="$(printf '%s\n' "$dates" | sort | tail -n 1)"
  [[ -n "$expected" && "$stated" == "$expected" ]] ||
    fail "$patch: expected Last-Update: $expected, got ${stated:-none}"
  count=$((count + 1))
done < <(git ls-files -z '*.patch')
(( count > 0 )) || fail "no patches found"
echo "$count patches checked"
