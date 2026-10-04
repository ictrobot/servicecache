#!/usr/bin/env bash
# nix.sh: run build commands with installed single-user or multi-user Nix.
#
#   nix.sh build [--ccache] [LINK=].#OUTPUT...
#                         build the flake's outputs in one nix build, printing
#                         build logs; one given as LINK=.#OUTPUT is linked at
#                         LINK, a garbage collector root, and the others'
#                         store paths are printed. --ccache mounts
#                         work/ccache at /ccache.
#   nix.sh check ARGS...  nix flake check ARGS
#
# Nix must be on PATH and have a usable store. The required
# command features are enabled per invocation, and the warning that the Git
# tree has uncommitted changes is turned off. Default builds and checks
# need no project-specific nix.conf settings. Trusted users mount work/ccache
# at /ccache for this invocation; other users need a configured /ccache mount.
# The cache must be writable by Nix's build user(s).
# Build logs, diagnostics and the links made go to standard error; standard
# output holds the store paths of the outputs without a link.
set -euo pipefail

fail() {
  echo "error: $*" >&2
  exit 1
}

usage() {
  sed -n '2,/^set -euo/{/^set -euo/d;s/^# \{0,1\}//;p}' "${BASH_SOURCE[0]}" >&2
  exit 2
}

[[ $# -ge 1 ]] || usage
command="$1"
shift
case "$command" in
  build | check) ;;
  *) usage ;;
esac

# A build's outputs, each with its link or none. An output is always .#NAME,
# which holds no "=", so a link is what comes before an argument's first "=".
ccache=false
outputs=()
links=()
if [[ "$command" == build ]]; then
  if [[ "${1:-}" == --ccache ]]; then
    ccache=true
    shift
  fi
  [[ $# -ge 1 ]] || usage
  for argument in "$@"; do
    if [[ "$argument" == .#* ]]; then
      outputs+=("$argument")
      links+=("")
    elif [[ "$argument" == *=* && "${argument#*=}" == .#* ]]; then
      outputs+=("${argument#*=}")
      links+=("${argument%%=*}")
    else
      fail "not .#OUTPUT or LINK=.#OUTPUT: $argument"
    fi
  done
  for link in "${links[@]}"; do
    [[ -z "$link" || -L "$link" || ! -e "$link" ]] ||
      fail "$link is not a link; remove it to link its output there"
  done
fi

options=(--extra-experimental-features "nix-command flakes" --no-warn-dirty)
install="install single-user or multi-user Nix (https://nixos.org/download)"

nix="$(command -v nix)" || fail "no nix on PATH; $install"
store_info="$("$nix" "${options[@]}" store info --json)" ||
  fail "$nix cannot access its store; check this user's Nix installation or daemon access"

if [[ "$command" == check ]]; then
  exec "$nix" "${options[@]}" flake check "$@"
fi

if "$ccache" && grep -Eq '"trusted":[[:space:]]*true' <<< "$store_info"; then
  cache="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/work/ccache"
  mkdir -p "$cache"
  options+=(--option extra-sandbox-paths "/ccache=$cache")
fi

printed="$("$nix" "${options[@]}" build --no-link --print-out-paths --print-build-logs "${outputs[@]}")"
mapfile -t paths <<< "$printed"
[[ ${#paths[@]} -eq ${#outputs[@]} ]] ||
  fail "the build printed ${#paths[@]} paths for ${#outputs[@]} outputs"

# nix build prints the outputs in the order given. The paths are built, so
# nix-store --add-root only links each and registers it as a garbage
# collector root.
nix_store="$(command -v nix-store)" || fail "no nix-store on PATH; $install"
for index in "${!outputs[@]}"; do
  link="${links[$index]}"
  if [[ -z "$link" ]]; then
    printf '%s\n' "${paths[$index]}"
    continue
  fi
  mkdir -p "$(dirname "$link")"
  "$nix_store" --realise "${paths[$index]}" --add-root "$link" > /dev/null
  echo "$link: linked to ${paths[$index]}" >&2
done
