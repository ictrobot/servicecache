#!/usr/bin/env bash
# nix.sh: run build commands with installed single-user or multi-user Nix.
#
#   nix.sh build ARGS...   nix build ARGS, printing build logs and each output's
#                          store path
#   nix.sh check ARGS...   nix flake check ARGS
#
# Nix must be on PATH and have a usable store. The required
# command features are enabled per invocation. Builds and checks
# need no project-specific nix.conf settings.
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
  build | check) ;;
  *) usage ;;
esac

options=(--extra-experimental-features "nix-command flakes")
install="install single-user or multi-user Nix (https://nixos.org/download)"

nix="$(command -v nix)" || fail "no nix on PATH; $install"
"$nix" "${options[@]}" store info >/dev/null ||
  fail "$nix cannot access its store; check this user's Nix installation or daemon access"

case "$command" in
  build)
    exec "$nix" "${options[@]}" build --no-link --print-out-paths --print-build-logs "$@"
    ;;
  check) exec "$nix" "${options[@]}" flake check "$@" ;;
esac
