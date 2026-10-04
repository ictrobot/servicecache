#!/usr/bin/env bash
# nix.sh: run build commands with installed single-user or multi-user Nix.
#
#   nix.sh build ARGS...          nix build ARGS, printing build logs and each
#                                 output's store path
#   nix.sh build-ccache ARGS...   the same, with work/ccache mounted at /ccache
#   nix.sh check ARGS...          nix flake check ARGS
#
# Nix must be on PATH and have a usable store. The required
# command features are enabled per invocation, and the warning that the Git
# tree has uncommitted changes is turned off. Default builds and checks
# need no project-specific nix.conf settings. Trusted users mount work/ccache
# at /ccache for this invocation; other users need a configured /ccache mount.
# The cache must be writable by Nix's build user(s).
# Builds make no result link unless --out-link is supplied. Build logs and
# diagnostics go to standard error; standard output holds the resulting store
# paths.
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
  build | build-ccache | check) ;;
  *) usage ;;
esac

options=(--extra-experimental-features "nix-command flakes" --no-warn-dirty)
install="install single-user or multi-user Nix (https://nixos.org/download)"

nix="$(command -v nix)" || fail "no nix on PATH; $install"
store_info="$("$nix" "${options[@]}" store info --json)" ||
  fail "$nix cannot access its store; check this user's Nix installation or daemon access"

if [[ "$command" == build-ccache ]] && grep -Eq '"trusted":[[:space:]]*true' <<< "$store_info"; then
  cache="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/work/ccache"
  mkdir -p "$cache"
  options+=(--option extra-sandbox-paths "/ccache=$cache")
fi

case "$command" in
  build | build-ccache)
    exec "$nix" "${options[@]}" build --no-link --print-out-paths --print-build-logs "$@"
    ;;
  check) exec "$nix" "${options[@]}" flake check "$@" ;;
esac
