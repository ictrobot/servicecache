#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "$0")/../../../toolchain/lib.sh"
sc_smoke_init nats-server "${1:?usage: $0 version}"

module="$SC_OUT/nats-server-$SC_VERSION/nats-server.wasm"
adapter="$SC_SERVICE_DIR/smoke/adapter"
address="${NATS_WASIX_ADDRESS:-127.0.0.1}"
port="${NATS_WASIX_PORT:-4222}"

if [[ ! -f "$module" ]]; then
  echo "nats-server module not found: $module" >&2
  exit 1
fi

# JetStream's store lives in the checkout, which run-wasix.sh maps into the
# guest at its own path.
mkdir -p "$SC_WORK/tmp"
store="$(mktemp -d "$SC_WORK/tmp/nats-server-smoke.XXXXXX")"
server_pid=""

stop_server() {
  [[ -n "$server_pid" ]] || return 0
  kill "$server_pid" 2>/dev/null || true
  wait "$server_pid" 2>/dev/null || true
  server_pid=""
}

cleanup() {
  stop_server
  rm -rf "$store"
}
trap cleanup EXIT

# Start the server with JetStream on and wait until it advertises it.
start_server() {
  "$SC_TOOLCHAIN/run-wasix.sh" "$module" -a "$address" -p "$port" -js -sd "$store" &
  server_pid=$!
  for _ in $(seq 50); do
    if "$adapter" check-initialized "$address" "$port" 2>/dev/null; then
      return 0
    fi
    kill -0 "$server_pid" 2>/dev/null || { echo "nats-server exited" >&2; exit 1; }
    sleep 0.2
  done
  echo "nats-server did not answer on $address:$port" >&2
  exit 1
}

start_server
"$adapter" check-working "$address" "$port"
"$adapter" diverge "$address" "$port" smoke
echo "nats-server $SC_VERSION: a subscriber received a published message and a JetStream key read back"

# The key is in JetStream's file store, so a second server finds it.
stop_server
start_server
"$adapter" check-diverged "$address" "$port" smoke
echo "nats-server $SC_VERSION: the key survived a restart"
