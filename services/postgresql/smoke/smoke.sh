#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "$0")/../../../toolchain/lib.sh"
sc_init postgresql "${1:?usage: $0 version}"

service_dir="$SC_OUT/postgresql-$SC_VERSION"
for artifact in postgres.wasm postgres initdb.wasm psql.wasm service.toml \
  share/postgres.bki share/system_views.sql; do
  if [[ ! -e "$service_dir/$artifact" ]]; then
    echo "PostgreSQL service artifact not found: $service_dir/$artifact" >&2
    exit 1
  fi
done

# The server imports ictrobot_shm_v1, so sc_init routes this smoke to the
# extensions CLI; stock refuses to instantiate the module, by design. Boot
# a fresh cluster standalone, the way the other services' smokes drive
# their servers, and probe it over the wire with real SQL.
port="${POSTGRESQL_WASIX_PORT:-54329}"
probe=("$SC_SERVICE_DIR/smoke/postgresql-probe.py" --host 127.0.0.1 --port "$port")
# The same probe over TLS, which it asks for before the startup packet,
# accepting the server's own certificate.
tls_probe=("${probe[@]}" --tls)

mkdir -p "$SC_WORK"
data_dir="$(mktemp -d "$SC_WORK/postgresql-smoke.XXXXXX")"
server_pid=""
cleanup() {
  if [[ -n "$server_pid" ]]; then
    kill "$server_pid" 2>/dev/null || true
    wait "$server_pid" 2>/dev/null || true
  fi
  rm -rf -- "$data_dir"
}
trap cleanup EXIT

"$SC_TOOLCHAIN/run-wasix.sh" "$service_dir/initdb.wasm" \
  --pgdata="$data_dir/data" --username=postgres --auth=trust --no-sync \
  --locale=C --encoding=UTF8 -L "$service_dir/share" > "$data_dir/initdb.log" ||
  { tail -n 20 "$data_dir/initdb.log" >&2; exit 1; }

"$SC_TOOLCHAIN/run-wasix.sh" "$service_dir/postgres.wasm" \
  -D "$data_dir/data" -h 127.0.0.1 -p "$port" \
  -c listen_addresses=127.0.0.1 -c unix_socket_directories= \
  -c dynamic_shared_memory_type=posix -c io_method=sync \
  -c fsync=off -c synchronous_commit=off -c full_page_writes=off \
  -c shared_buffers=16MB -c max_connections=50 -c ssl=on \
  > "$data_dir/server.log" 2>&1 &
server_pid=$!

ready=false
for ((attempt = 0; attempt < 100; attempt++)); do
  if "${probe[@]}" "SELECT 1" >/dev/null 2>&1; then
    ready=true
    break
  fi
  sleep 0.2
done
if [[ "$ready" != true ]]; then
  echo "PostgreSQL did not become ready on 127.0.0.1:$port" >&2
  tail -n 20 "$data_dir/server.log" >&2
  exit 1
fi

# check description expected sql: one probe call, a session of its own, and
# its whole output. Statements that return no rows expect "". tls_check does
# the same over a TLS connection.
check_with() {
  local -n probe_command="$1"
  local actual
  actual="$("${probe_command[@]}" "$4")" || { echo "$2: the query failed" >&2; exit 1; }
  [[ "$actual" == "$3" ]] || { echo "$2: expected '$3', got '$actual'" >&2; exit 1; }
}
check() {
  check_with probe "$@"
}
tls_check() {
  check_with tls_probe "$@"
}

check "create a table" "" "CREATE TABLE smoke (id int PRIMARY KEY, value text)"
check "insert a row" "" "INSERT INTO smoke VALUES (1, 'standalone')"
check "read the row back" "standalone" "SELECT value FROM smoke WHERE id = 1"
check "the connection's backend" "client backend" \
  "SELECT backend_type FROM pg_stat_activity WHERE pid = pg_backend_pid()"

# The server is built against OpenSSL, its TLS library, and SHA-256 and the
# random bytes of a version 4 UUID come from libcrypto.
check "TLS library" "OpenSSL" "SELECT setting FROM pg_settings WHERE name = 'ssl_library'"
check "TLS" "on" "SELECT setting FROM pg_settings WHERE name = 'ssl'"
check "SHA-256 of 'abc'" "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad" \
  "SELECT encode(sha256('abc'), 'hex')"
check "UUID version" "4" "SELECT uuid_extract_version(gen_random_uuid())::text"
check "two UUIDs differ" "true" "SELECT (gen_random_uuid() <> gen_random_uuid())::text"

# The cluster initdb made has no certificate, so the server generates one at
# its first start, under the names ssl_cert_file and ssl_key_file give in the
# data directory. WASIX keeps no file modes, so what can be checked is that
# both files are there and hold the PEM objects they should.
check_generated() {
  local name="$1" first_line="$2" path="$data_dir/data/$1"
  [[ -f "$path" ]] || { echo "the server did not generate $name in its data directory" >&2; exit 1; }
  [[ "$(head -n 1 "$path")" == "$first_line" ]] ||
    { echo "the generated $name does not begin with $first_line" >&2; exit 1; }
}
check_generated server.crt "-----BEGIN CERTIFICATE-----"
check_generated server.key "-----BEGIN PRIVATE KEY-----"

# A connection that asks for TLS gets it, over the generated certificate, and
# pg_stat_ssl reports the session. Plain connections, which every other check
# uses, are still served, unencrypted.
tls_check "TLS session encrypted" "true" "SELECT ssl::text FROM pg_stat_ssl WHERE pid = pg_backend_pid()"
tls_check "TLS session version" "TLSv1.3" "SELECT version FROM pg_stat_ssl WHERE pid = pg_backend_pid()"
check "plain session unencrypted" "false" "SELECT ssl::text FROM pg_stat_ssl WHERE pid = pg_backend_pid()"

# A forced parallel aggregate exercises what the extension exists for:
# postmaster children cooperating through shared memory. The full worker
# accounting stays in the host trials' adapter; one plan proving four
# launched workers is enough here. The session settings go in the same
# probe call as each query they apply to.
parallel_settings="SET max_parallel_workers_per_gather = 4; SET min_parallel_table_scan_size = 0; SET parallel_setup_cost = 0; SET parallel_tuple_cost = 0; SET parallel_leader_participation = off"
check "create the parallel table" "" \
  "CREATE TABLE parallel_smoke AS SELECT id FROM generate_series(1, 20000) id"
check "analyze the parallel table" "" "ANALYZE parallel_smoke"
check "set its parallel workers" "" "ALTER TABLE parallel_smoke SET (parallel_workers = 4)"
check "the parallel aggregate's sum" "200010000" \
  "$parallel_settings; SELECT sum(id)::text FROM parallel_smoke"
# The plan's text varies, so only its worker count is checked, as a whole
# line of that plan.
plan="$("${probe[@]}" "$parallel_settings; EXPLAIN (ANALYZE) SELECT sum(id) FROM parallel_smoke")" ||
  { echo "the parallel plan: the query failed" >&2; exit 1; }
grep -qxE ' *Workers Launched: 4' <<<"$plan" || {
  echo "the parallel plan did not launch 4 workers" >&2
  printf '%s\n' "$plan" >&2
  exit 1
}

kill "$server_pid" 2>/dev/null || true
wait "$server_pid" 2>/dev/null || true
server_pid=""

echo "PostgreSQL WASIX smoke test passed."
