#!/usr/bin/env bash
# Fails unless every selection pattern matches a file in the index of the
# current Git repository.
set -euo pipefail
patterns="${1:?patterns file}"
while IFS= read -r pattern; do
  matched="$(git ls-files --cached --ignored --exclude="$pattern")"
  if [[ -z "$matched" ]]; then
    echo "source selection pattern matches no files: $pattern" >&2
    exit 1
  fi
done <"$patterns"
