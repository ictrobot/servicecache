#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "$0")/../../../toolchain/lib.sh"
sc_init valkey "${1:?usage: $0 version}"

service_dir="$SC_OUT/valkey-$SC_VERSION"
server_module="$service_dir/valkey-server.wasm"
cli_module="$service_dir/valkey-cli.wasm"
address="${VALKEY_WASIX_BIND_ADDRESS:-127.0.0.1}"
port="${VALKEY_WASIX_PORT:-6380}"
maxmemory="${VALKEY_WASIX_MAXMEMORY:-256mb}"

# Lua scripts reach the server API through the "server" global since 8.0;
# 7.2 only has the "redis" name.
lua_api=server
case "$SC_VERSION" in
  7.2.*) lua_api=redis ;;
esac

for module in "$server_module" "$cli_module"; do
  if [[ ! -f "$module" ]]; then
    echo "Valkey module not found: $module" >&2
    exit 1
  fi
done

mkdir -p "$SC_WORK"
data_dir="$(mktemp -d "$SC_WORK/valkey-smoke.XXXXXX")"
"$SC_TOOLCHAIN/run-wasix.sh" "$server_module" \
  --bind "$address" \
  --port "$port" \
  --protected-mode no \
  --daemonize no \
  --save "" \
  --appendonly no \
  --maxmemory "$maxmemory" \
  --maxmemory-policy noeviction \
  --dir "$data_dir" &
server_pid=$!
cleanup() {
  kill "$server_pid" 2>/dev/null || true
  wait "$server_pid" 2>/dev/null || true
  rm -rf -- "$data_dir"
}
trap cleanup EXIT

probe=("$SC_SERVICE_DIR/smoke/valkey-probe.py" --host "$address" --port "$port")
ready=false
for ((attempt = 0; attempt < 100; attempt++)); do
  if "${probe[@]}" PING >/dev/null 2>&1; then
    ready=true
    break
  fi
  sleep 0.1
done
if [[ "$ready" != true ]]; then
  echo "Valkey did not become ready on $address:$port" >&2
  exit 1
fi

write_resp_command() {
  printf '*%d\r\n' "$#"
  for argument in "$@"; do
    printf '$%d\r\n%s\r\n' "${#argument}" "$argument"
  done
}

{
  write_resp_command SET wasm-initializer-key hello-from-initializer
  write_resp_command INCR wasm-initializer-counter
} | "$SC_TOOLCHAIN/run-wasix.sh" "$cli_module" \
  -h "$address" -p "$port" --pipe

assert_response() {
  local expected="$1"
  shift
  local actual
  actual="$("${probe[@]}" "$@")"
  if [[ "$actual" != "$expected" ]]; then
    echo "unexpected response for $*: expected '$expected', got '$actual'" >&2
    exit 1
  fi
  printf '%-28s %s\n' "$*" "$actual"
}

assert_response hello-from-initializer GET wasm-initializer-key
assert_response 1 GET wasm-initializer-counter
assert_response PONG PING
"${probe[@]}" DEL wasm-key wasm-counter wasm-hash wasm-lua-key >/dev/null
assert_response OK SET wasm-key hello-wasix
assert_response hello-wasix GET wasm-key
assert_response 1 INCR wasm-counter
assert_response 42 INCRBY wasm-counter 41
assert_response 2 HSET wasm-hash runtime wasmer target wasix
assert_response wasmer HGET wasm-hash runtime
assert_response wasix HGET wasm-hash target
assert_response 42 EVAL "return 6 * 7" 0
assert_response OK EVAL "return ${lua_api}.call('SET', KEYS[1], ARGV[1])" 1 wasm-lua-key lua-wasix
assert_response lua-wasix EVAL "return ${lua_api}.call('GET', KEYS[1])" 1 wasm-lua-key

lua_sha="$("${probe[@]}" SCRIPT LOAD "return ARGV[1]")"
assert_response evalsha-wasix EVALSHA "$lua_sha" 0 evalsha-wasix

lua_library="#!lua name=wasixlib"$'\n'"${lua_api}.register_function('answer', function(keys, args) return 42 end)"
assert_response wasixlib FUNCTION LOAD REPLACE "$lua_library"
assert_response 42 FCALL answer 0
assert_response OK FUNCTION DELETE wasixlib

echo "Valkey WASIX smoke test passed."
