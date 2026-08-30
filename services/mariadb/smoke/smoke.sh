#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "$0")/../../../toolchain/lib.sh"
sc_init mariadb "${1:?usage: $0 version}"

service_dir="$SC_OUT/mariadb-$SC_VERSION"
server_module="$service_dir/mariadbd.wasm"
client_module="$service_dir/mariadb.wasm"
share_dir="$service_dir/share"
address="${MARIADB_WASIX_BIND_ADDRESS:-127.0.0.1}"
port="${MARIADB_WASIX_PORT:-3306}"

for required_path in \
  "$server_module" \
  "$client_module" \
  "$share_dir/bootstrap.sql" \
  "$share_dir/english/errmsg.sys" \
  "$share_dir/charsets/Index.xml"; do
  if [[ ! -e "$required_path" ]]; then
    echo "MariaDB service artifact not found: $required_path" >&2
    exit 1
  fi
done

mkdir -p "$SC_WORK"
smoke_dir="$(mktemp -d "$SC_WORK/mariadb-smoke.XXXXXX")"
data_dir="$smoke_dir/data"
tmp_dir="$smoke_dir/tmp"
server_log="$smoke_dir/mariadbd.log"
server_pid=""
mkdir -p "$data_dir" "$tmp_dir"

cleanup() {
  if [[ -n "$server_pid" ]]; then
    kill "$server_pid" 2>/dev/null || true
    wait "$server_pid" 2>/dev/null || true
  fi
  rm -rf -- "$smoke_dir"
}
trap cleanup EXIT

common_args=(
  --user=root
  --basedir="$service_dir"
  --datadir="$data_dir"
  --tmpdir="$tmp_dir"
  --lc-messages-dir="$share_dir"
  --character-sets-dir="$share_dir/charsets"
  --innodb-buffer-pool-size=16M
  --innodb-log-file-size=16M
  --innodb-read-io-threads=1
  --innodb-write-io-threads=2
  --innodb-purge-threads=1
  --skip-log-bin
)

# The bootstrap failed about one time in twenty until the sysroot's libc was
# fixed: two guest threads resolving relative paths at once corrupted each
# other's paths (wasix-libc chdir.c; the fix is
# patches/wasix-libc/0001-chdir-lock-relative-path-resolution.patch, built into
# the sysroot by toolchain/bootstrap.sh). A guest built against an unpatched
# sysroot still has it, so a failed bootstrap is retried once, loudly.
bootstrapped=false
for attempt in 1 2; do
  if "$SC_TOOLCHAIN/run-wasix.sh" "$server_module" \
      --no-defaults \
      --bootstrap \
      --silent-startup \
      --skip-log-error \
      --log-warnings=0 \
      --enforce-storage-engine= \
      --max-allowed-packet=8M \
      --net-buffer-length=16K \
      "${common_args[@]}" < "$share_dir/bootstrap.sql"; then
    bootstrapped=true
    break
  fi
  echo "MariaDB bootstrap failed (attempt $attempt); retrying on a fresh data directory" >&2
  rm -rf -- "$data_dir"
  mkdir -p "$data_dir"
done
if [[ "$bootstrapped" != true ]]; then
  echo "MariaDB bootstrap failed twice" >&2
  exit 1
fi

"$SC_TOOLCHAIN/run-wasix.sh" "$server_module" \
  --no-defaults \
  "${common_args[@]}" \
  --port="$port" \
  --bind-address="$address" \
  --socket= \
  --pid-file="$smoke_dir/mariadbd.pid" \
  --innodb-open-files=64 \
  --console >"$server_log" 2>&1 &
server_pid=$!

probe=("$SC_SERVICE_DIR/smoke/mysql-probe.py" --host "$address" --port "$port")
ready=false
for ((attempt = 0; attempt < 300; attempt++)); do
  if "${probe[@]}" "SELECT 1" >/dev/null 2>&1; then
    ready=true
    break
  fi
  if ! kill -0 "$server_pid" 2>/dev/null; then
    break
  fi
  sleep 0.1
done
if [[ "$ready" != true ]]; then
  echo "MariaDB did not become ready on $address:$port" >&2
  sed -n '1,240p' "$server_log" >&2
  exit 1
fi

client_output="$({
  printf '%s\n' \
    "CREATE DATABASE IF NOT EXISTS wasm_cli_test;" \
    "CREATE TABLE IF NOT EXISTS wasm_cli_test.innodb_probe (id INT PRIMARY KEY, value VARCHAR(32) NOT NULL) ENGINE=InnoDB;" \
    "DELETE FROM wasm_cli_test.innodb_probe;" \
    "INSERT INTO wasm_cli_test.innodb_probe VALUES (1, 'wasix-client');" \
    "SELECT VERSION();" \
    "SELECT id, value FROM wasm_cli_test.innodb_probe ORDER BY id;"
} | "$SC_TOOLCHAIN/run-wasix.sh" "$client_module" \
  --no-defaults -h "$address" -P "$port" -u root --batch)"
printf '%s\n' "$client_output"

probe_output="$("${probe[@]}" \
  "SELECT VERSION() AS version" \
  "SELECT p.id, p.value, t.ENGINE FROM wasm_cli_test.innodb_probe AS p JOIN information_schema.tables AS t ON t.table_schema='wasm_cli_test' AND t.table_name='innodb_probe' ORDER BY p.id")"
printf '%s\n' "$probe_output"

if ! grep -Eq '^[^[:space:]]+-servicecache$' <<<"$probe_output"; then
  echo "SELECT VERSION() did not end in -servicecache" >&2
  exit 1
fi
if ! grep -Fqx $'1\twasix-client\tInnoDB' <<<"$probe_output"; then
  echo "InnoDB table round trip did not return the expected row" >&2
  exit 1
fi

# A clean shutdown over the wire: the server must exit on its own.
"${probe[@]}" "SHUTDOWN" >/dev/null
stopped=false
for ((attempt = 0; attempt < 300; attempt++)); do
  if ! kill -0 "$server_pid" 2>/dev/null; then
    stopped=true
    break
  fi
  sleep 0.1
done
if [[ "$stopped" != true ]]; then
  echo "MariaDB did not exit within 30s of SHUTDOWN" >&2
  tail -n 40 "$server_log" >&2
  exit 1
fi
wait "$server_pid" || true
server_pid=""
if ! grep -q "Shutdown complete" "$server_log"; then
  echo "MariaDB exited without logging 'Shutdown complete'" >&2
  tail -n 40 "$server_log" >&2
  exit 1
fi

# TLS, server and client, on its own servers.
"$(dirname "$0")/tls.sh" "$SC_VERSION"

echo "MariaDB WASIX smoke test passed."
