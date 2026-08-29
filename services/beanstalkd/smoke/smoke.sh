#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "$0")/../../../toolchain/lib.sh"
sc_init beanstalkd "${1:?usage: $0 version}"

module="$SC_OUT/beanstalkd-$SC_VERSION/beanstalkd.wasm"
address="${BEANSTALKD_WASIX_ADDRESS:-127.0.0.1}"
port="${BEANSTALKD_WASIX_PORT:-11300}"

if [[ ! -f "$module" ]]; then
  echo "beanstalkd module not found: $module" >&2
  exit 1
fi

"$SC_TOOLCHAIN/run-wasix.sh" "$module" -l "$address" -p "$port" &
server_pid=$!
cleanup() {
  kill "$server_pid" 2>/dev/null || true
  wait "$server_pid" 2>/dev/null || true
}
trap cleanup EXIT

"$SC_SERVICE_DIR/smoke/beanstalk-probe.py" --host "$address" --port "$port"
