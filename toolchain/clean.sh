#!/usr/bin/env bash
set -euo pipefail

# clean.sh [--sources] service version
#
# Removes a service version's build directory and assembled output, and resets
# its source checkout to the pristine upstream tag so the next build re-applies
# the patch series from scratch. With --sources the checkout is removed too.

source "$(dirname "$0")/lib.sh"

sources=0
if [[ "${1:-}" == "--sources" ]]; then
  sources=1
  shift
fi
sc_init "${1:?usage: $0 [--sources] service version}" \
  "${2:?usage: $0 [--sources] service version}"

rm -rf "$SC_OUT/$SC_SERVICE-$SC_VERSION"

if [[ "$sources" -eq 1 ]]; then
  rm -rf "$SC_BUILD" "$SC_SRC"
else
  sc_reset_build_state
fi
