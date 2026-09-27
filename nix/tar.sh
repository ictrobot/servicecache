#!/usr/bin/env bash
# Deterministic tar bytes for upstream and complete source tars.
set -euo pipefail
directory="${1:?source directory}"
output="${2:?output file}"
options=(--format=gnu --sort=name --mtime=@315532800 --owner=0 --group=0
  --numeric-owner --mode=u+rwX,go+rX,go-w --hard-dereference)
if [[ "${3:-}" == zstd ]]; then
  tar "${options[@]}" -cf - -C "$directory" . | zstd -T1 -q -o "$output"
else
  tar "${options[@]}" -cf "$output" -C "$directory" .
fi
