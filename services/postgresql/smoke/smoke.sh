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
  -c shared_buffers=16MB -c max_connections=50 \
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

"${probe[@]}" \
  "CREATE TABLE smoke (id int PRIMARY KEY, value text)" \
  "INSERT INTO smoke VALUES (1, 'standalone')" \
  "SELECT value FROM smoke WHERE id = 1" \
  "SELECT count(*)::text FROM pg_stat_activity"

# A forced parallel aggregate exercises what the extension exists for:
# postmaster children cooperating through shared memory. The full worker
# accounting stays in the host trials' adapter; one plan proving four
# launched workers is enough here.
parallel="$("${probe[@]}" \
  "CREATE TABLE parallel_smoke AS SELECT id FROM generate_series(1, 20000) id" \
  "ANALYZE parallel_smoke" \
  "SET max_parallel_workers_per_gather = 4; SET min_parallel_table_scan_size = 0; SET parallel_setup_cost = 0; SET parallel_tuple_cost = 0; SET parallel_leader_participation = off; ALTER TABLE parallel_smoke SET (parallel_workers = 4)" \
  "SELECT sum(id)::text FROM parallel_smoke" \
  "EXPLAIN (ANALYZE) SELECT sum(id) FROM parallel_smoke")"
[[ "$parallel" == *"200010000"* ]] ||
  { echo "the parallel aggregate returned the wrong sum" >&2; exit 1; }
[[ "$parallel" == *"Workers Launched: 4"* ]] || {
  echo "the parallel plan did not launch 4 workers" >&2
  printf '%s\n' "$parallel" >&2
  exit 1
}

kill "$server_pid" 2>/dev/null || true
wait "$server_pid" 2>/dev/null || true
server_pid=""

echo "PostgreSQL WASIX smoke test passed."
