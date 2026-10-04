#!/usr/bin/env bash
# toolchain/go/export-patches.sh [checkout]: regenerate ../sources/go/patches
# from the wasix branch of a Go checkout (default: work/go), as the commits
# between the pinned Go release tag and the branch tip, in the conventions
# of the other patch series: Subject, Last-Update, description, diff.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$root/toolchain/lib.sh"
source "$root/wasmer/lib.sh"

checkout="${1:-$root/work/go}"
version="$(sed -En 's/^ *version = "([0-9.]+)";$/\1/p' "$root/toolchain/sources/go/default.nix")"
[[ -n "$version" ]] || { sc_fail "no version pinned in toolchain/sources/go/default.nix"; exit 1; }
sc_wasmer_export_range "$checkout" "go$version" wasix "$root/toolchain/sources/go/patches"
