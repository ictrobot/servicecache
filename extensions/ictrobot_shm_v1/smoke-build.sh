#!/usr/bin/env bash
# smoke-build.sh: compile the ictrobot_shm_v1 demo into SC_OUT_DIR with the
# guest-cc on PATH (toolchain/guest). The flake runs it as
# smoke-extension-ictrobot_shm_v1, and smoke.sh runs what it builds.
set -euo pipefail

sources="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
out="${SC_OUT_DIR:?SC_OUT_DIR is not set}"
mkdir -p "$out"

guest-cc -O2 -pthread -I "$sources/include" "$sources/demo.c" -o "$out/ictrobot-shm-demo.wasm"
