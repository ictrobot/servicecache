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
# The same probe, printing the notifications a statement raised after its rows.
notify_probe=("${probe[@]}" --notifications)
# The same probe, connected to the database pg_stat_statements' checks create.
other_database_probe=("${probe[@]}" --database smoke_pg_stat_statements)

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
  -c shared_preload_libraries=pg_stat_statements \
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

# check sql [expected]: one probe call, a session of its own, and its whole
# output, which is empty when no expected output is given. tls_check and
# notify_check do the same over a TLS connection and with notifications.
check_with() {
  local -n probe_command="$1"
  local actual expected="${3-}"
  actual="$("${probe_command[@]}" "$2")" || { echo "$2: the query failed" >&2; exit 1; }
  [[ "$actual" == "$expected" ]] || { echo "$2: expected '$expected', got '$actual'" >&2; exit 1; }
}
check() {
  check_with probe "$@"
}
tls_check() {
  check_with tls_probe "$@"
}
notify_check() {
  check_with notify_probe "$@"
}
other_database_check() {
  check_with other_database_probe "$@"
}

check "CREATE TABLE smoke (id int PRIMARY KEY, value text)"
check "INSERT INTO smoke VALUES (1, 'standalone')"
check "SELECT value FROM smoke WHERE id = 1" "standalone"
check "SELECT backend_type FROM pg_stat_activity WHERE pid = pg_backend_pid()" "client backend"

# The server is built against OpenSSL, its TLS library, and SHA-256 and the
# random bytes of a version 4 UUID come from libcrypto.
check "SELECT setting FROM pg_settings WHERE name = 'ssl_library'" "OpenSSL"
check "SELECT setting FROM pg_settings WHERE name = 'ssl'" "on"
check "SELECT encode(sha256('abc'), 'hex')" \
  "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
check "SELECT uuid_extract_version(gen_random_uuid())::text" "4"
check "SELECT (gen_random_uuid() <> gen_random_uuid())::text" "true"

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
tls_check "SELECT ssl::text FROM pg_stat_ssl WHERE pid = pg_backend_pid()" "true"
tls_check "SELECT version FROM pg_stat_ssl WHERE pid = pg_backend_pid()" "TLSv1.3"
check "SELECT ssl::text FROM pg_stat_ssl WHERE pid = pg_backend_pid()" "false"

# A forced parallel aggregate exercises what the extension exists for:
# postmaster children cooperating through shared memory. The full worker
# accounting stays in the host trials' adapter; one plan proving four
# launched workers is enough here. The session settings go in the same
# probe call as each query they apply to.
parallel_settings="SET max_parallel_workers_per_gather = 4; SET min_parallel_table_scan_size = 0; SET parallel_setup_cost = 0; SET parallel_tuple_cost = 0; SET parallel_leader_participation = off"
check "CREATE TABLE parallel_smoke AS SELECT id FROM generate_series(1, 20000) id"
check "ANALYZE parallel_smoke"
check "ALTER TABLE parallel_smoke SET (parallel_workers = 4)"
check "$parallel_settings; SELECT sum(id)::text FROM parallel_smoke" "200010000"
# The plan's text varies, so only its worker count is checked, as a whole
# line of that plan.
plan="$("${probe[@]}" "$parallel_settings; EXPLAIN (ANALYZE) SELECT sum(id) FROM parallel_smoke")" ||
  { echo "the parallel plan: the query failed" >&2; exit 1; }
grep -qxE ' *Workers Launched: 4' <<<"$plan" || {
  echo "the parallel plan did not launch 4 workers" >&2
  printf '%s\n' "$plan" >&2
  exit 1
}

# PL/pgSQL's module is linked into the server rather than loaded.
check "SELECT extname || ' ' || lanname FROM pg_extension, pg_language WHERE extname = 'plpgsql' AND lanname = 'plpgsql'" "plpgsql plpgsql"
check "CREATE FUNCTION smoke_total(n int) RETURNS int LANGUAGE plpgsql AS 'DECLARE total int := 0; BEGIN FOR i IN 1..n LOOP total := total + i; END LOOP; RETURN total; END'"
check "SELECT smoke_total(100)::text" "5050"
check "DO 'BEGIN PERFORM smoke_total(1); END'"

# citext
check "CREATE EXTENSION citext"
check "CREATE TABLE smoke_citext (name citext PRIMARY KEY)"
check "INSERT INTO smoke_citext VALUES ('Abc'), ('XYZ')"
check "INSERT INTO smoke_citext VALUES ('ABC') ON CONFLICT DO NOTHING"
check "SELECT name FROM smoke_citext WHERE name = 'abc'" "Abc"
check "SELECT count(*) FROM smoke_citext" "2"

# pg_trgm
check "CREATE EXTENSION pg_trgm"
check "SELECT array_length(show_trgm('word'), 1)" "5"
check "SELECT similarity('word', 'wordy') > 0.5" "t"
check "SELECT 'word'::text % 'wordy'::text" "t"
check "CREATE TABLE smoke_pg_trgm AS SELECT 'word' || id::text AS value FROM generate_series(1, 2000) id"
check "CREATE INDEX smoke_pg_trgm_index ON smoke_pg_trgm USING gin (value gin_trgm_ops)"
check "ANALYZE smoke_pg_trgm"
check "SET enable_seqscan = off; EXPLAIN (COSTS OFF) SELECT value FROM smoke_pg_trgm WHERE value LIKE '%rd1234%'" \
  "Bitmap Heap Scan on smoke_pg_trgm
  Recheck Cond: (value ~~ '%rd1234%'::text)
  ->  Bitmap Index Scan on smoke_pg_trgm_index
        Index Cond: (value ~~ '%rd1234%'::text)"
check "SET enable_seqscan = off; SELECT value FROM smoke_pg_trgm WHERE value LIKE '%rd1234%'" "word1234"

# hstore
check "CREATE EXTENSION hstore"
check "SELECT 'a=>1, b=>2'::hstore -> 'b'" "2"
check "SELECT 'a=>1, b=>2'::hstore ? 'a'" "t"
check "SELECT 'a=>1'::hstore || 'b=>2'::hstore" '"a"=>"1", "b"=>"2"'
check "CREATE TABLE smoke_hstore AS SELECT ('key=>' || id::text)::hstore AS pairs FROM generate_series(1, 2000) id"
check "CREATE INDEX smoke_hstore_index ON smoke_hstore USING gin (pairs)"
check "ANALYZE smoke_hstore"
check "SET enable_seqscan = off; EXPLAIN (COSTS OFF) SELECT pairs FROM smoke_hstore WHERE pairs @> 'key=>1234'" \
  "Bitmap Heap Scan on smoke_hstore
  Recheck Cond: (pairs @> '\"key\"=>\"1234\"'::hstore)
  ->  Bitmap Index Scan on smoke_hstore_index
        Index Cond: (pairs @> '\"key\"=>\"1234\"'::hstore)"
check "SET enable_seqscan = off; SELECT pairs -> 'key' FROM smoke_hstore WHERE pairs @> 'key=>1234'" "1234"

# btree_gist
check "CREATE EXTENSION btree_gist"
check "CREATE TABLE smoke_btree_gist_exclude (a int, b int4range, EXCLUDE USING gist (a WITH =, b WITH &&))"
check "INSERT INTO smoke_btree_gist_exclude VALUES (1, '[1,3)')"
check "INSERT INTO smoke_btree_gist_exclude VALUES (1, '[3,5)')"
check "INSERT INTO smoke_btree_gist_exclude VALUES (2, '[2,4)')"
check "SELECT count(*) FROM smoke_btree_gist_exclude" "3"
check "SELECT count(*) FROM smoke_btree_gist_exclude WHERE a = 1 AND b && '[2,4)'::int4range" "2"
check "CREATE TABLE smoke_btree_gist AS SELECT id FROM generate_series(1, 2000) id"
check "CREATE INDEX smoke_btree_gist_index ON smoke_btree_gist USING gist (id)"
check "ANALYZE smoke_btree_gist"
check "SET enable_seqscan = off; EXPLAIN (COSTS OFF) SELECT id FROM smoke_btree_gist WHERE id = 1234" \
  "Index Only Scan using smoke_btree_gist_index on smoke_btree_gist
  Index Cond: (id = 1234)"
check "SET enable_seqscan = off; SELECT id FROM smoke_btree_gist WHERE id = 1234" "1234"
check "SET enable_seqscan = off; EXPLAIN (COSTS OFF) SELECT id FROM smoke_btree_gist WHERE id BETWEEN 1234 AND 1236" \
  "Bitmap Heap Scan on smoke_btree_gist
  Recheck Cond: ((id >= 1234) AND (id <= 1236))
  ->  Bitmap Index Scan on smoke_btree_gist_index
        Index Cond: ((id >= 1234) AND (id <= 1236))"
check "SET enable_seqscan = off; SELECT id FROM smoke_btree_gist WHERE id BETWEEN 1234 AND 1236 ORDER BY id" \
  "1234
1235
1236"

# btree_gin
check "CREATE EXTENSION btree_gin"
check "CREATE TABLE smoke_btree_gin AS SELECT id, 'row' || id::text AS name FROM generate_series(1, 2000) id"
check "CREATE INDEX smoke_btree_gin_index ON smoke_btree_gin USING gin (id, name)"
check "ANALYZE smoke_btree_gin"
check "SET enable_seqscan = off; EXPLAIN (COSTS OFF) SELECT id FROM smoke_btree_gin WHERE id = 1234" \
  "Bitmap Heap Scan on smoke_btree_gin
  Recheck Cond: (id = 1234)
  ->  Bitmap Index Scan on smoke_btree_gin_index
        Index Cond: (id = 1234)"
check "SET enable_seqscan = off; SELECT name FROM smoke_btree_gin WHERE id = 1234" "row1234"
check "SET enable_seqscan = off; EXPLAIN (COSTS OFF) SELECT id FROM smoke_btree_gin WHERE id BETWEEN 1234 AND 1236" \
  "Bitmap Heap Scan on smoke_btree_gin
  Recheck Cond: ((id >= 1234) AND (id <= 1236))
  ->  Bitmap Index Scan on smoke_btree_gin_index
        Index Cond: ((id >= 1234) AND (id <= 1236))"
check "SET enable_seqscan = off; SELECT id FROM smoke_btree_gin WHERE id BETWEEN 1234 AND 1236 ORDER BY id" \
  "1234
1235
1236"

# unaccent
# ts_lexize through the dictionary reads its rules from share/tsearch_data.
check "CREATE EXTENSION unaccent"
check "SELECT unaccent('Àbc Déf')" "Abc Def"
check "SELECT ts_lexize('unaccent', 'Àbc')" "{Abc}"
check "CREATE TEXT SEARCH CONFIGURATION smoke_unaccent (COPY = simple)"
check "ALTER TEXT SEARCH CONFIGURATION smoke_unaccent ALTER MAPPING FOR asciiword, word WITH unaccent, simple"
check "SELECT to_tsvector('smoke_unaccent', 'Àbc Déf')" "'abc':1 'def':2"

# ltree
check "CREATE EXTENSION ltree"
check "SELECT 'a.b.c'::ltree <@ 'a.b'" "t"
check "SELECT nlevel('a.b.c')" "3"
check "SELECT subpath('a.b.c', 1)" "b.c"
check "SELECT 'a.b.c'::ltree ~ '*.b.*'" "t"
check "CREATE TABLE smoke_ltree (path ltree)"
check "INSERT INTO smoke_ltree VALUES ('a'), ('a.b'), ('a.b.c'), ('a.b.c.d'), ('a.e'), ('a.e.f'), ('a.g.b.c')"
check "CREATE INDEX smoke_ltree_index ON smoke_ltree USING gist (path)"
check "ANALYZE smoke_ltree"
check "SET enable_seqscan = off; EXPLAIN (COSTS OFF) SELECT path FROM smoke_ltree WHERE path <@ 'a.b'" \
  "Index Scan using smoke_ltree_index on smoke_ltree
  Index Cond: (path <@ 'a.b'::ltree)"
check "SET enable_seqscan = off; SELECT path FROM smoke_ltree WHERE path <@ 'a.b' ORDER BY path" \
  "a.b
a.b.c
a.b.c.d"

# tablefunc
check "CREATE EXTENSION tablefunc"
check "CREATE TABLE smoke_tablefunc (a text, b text, c int)"
check "INSERT INTO smoke_tablefunc VALUES ('first', 'a', 1), ('first', 'b', 2), ('second', 'a', 3), ('second', 'b', 4)"
check "SELECT * FROM crosstab('SELECT a, b, c FROM smoke_tablefunc ORDER BY 1, 2') AS t(a text, x int, y int)" \
  "first	1	2
second	3	4"
check "CREATE TABLE smoke_tablefunc_tree (id int, parent int)"
check "INSERT INTO smoke_tablefunc_tree VALUES (1, NULL), (2, 1), (3, 1), (4, 2)"
check "SELECT id, level, branch FROM connectby('smoke_tablefunc_tree', 'id', 'parent', '1', 0, '~') AS t(id int, parent int, level int, branch text)" \
  "1	0	1
2	1	1~2
4	2	1~2~4
3	1	1~3"
check "SELECT count(*) FROM normal_rand(10, 0, 1)" "10"

# pgcrypto
# This build has no zlib, so PGP compression is off.
check "CREATE EXTENSION pgcrypto"
check "SELECT encode(digest('abc', 'sha256'), 'hex')" \
  "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
check "SELECT encode(digest('abc', 'md5'), 'hex')" "900150983cd24fb0d6963f7d28e17f72"
check "SELECT encode(hmac('data', 'key', 'sha256'), 'hex')" \
  "5031fe3d989c6d1537a013fa6e739da23463fdaec3b70137d828e36ace221bd0"
check "SELECT crypt('password', '\$2a\$06\$rasEqmk5PLDMOfvBOhCsUO')" \
  "\$2a\$06\$rasEqmk5PLDMOfvBOhCsUOop1JWlcIbhZmM3t22Gxn6UQyABuNr2O"
check "WITH h AS (SELECT crypt('password', gen_salt('bf', 6)) AS h) SELECT crypt('password', h) = h FROM h" "t"
check "SELECT pgp_sym_decrypt(pgp_sym_encrypt('secret', 'pw', 'compress-algo=0'), 'pw')" "secret"
check "SELECT length(gen_random_bytes(16))" "16"

# sslinfo
# The probe presents no client certificate.
check "CREATE EXTENSION sslinfo"
tls_check "SELECT ssl_is_used()" "t"
tls_check "SELECT ssl_version()" "TLSv1.3"
tls_check "SELECT ssl_cipher()" "TLS_AES_256_GCM_SHA384"
tls_check "SELECT ssl_client_cert_present()" "f"
check "SELECT ssl_is_used()" "f"

# uuid-ossp
# A backend's version 1 state is visible only within one statement, so the
# checks over it generate their UUIDs in one.
check 'CREATE EXTENSION "uuid-ossp"'
check "SELECT uuid_generate_v3(uuid_ns_dns(), 'www.example.com')" "5df41881-3aed-3515-88a7-2f4a814cf09e"
check "SELECT uuid_generate_v5(uuid_ns_dns(), 'www.example.com')" "2ed6657d-e927-568b-95e1-2665a8aea6a2"
check "SELECT uuid_ns_url()" "6ba7b811-9dad-11d1-80b4-00c04fd430c8"
check "SELECT uuid_nil()" "00000000-0000-0000-0000-000000000000"
check "SELECT substr(uuid_generate_v4()::text, 15, 1)" "4"
check "SELECT substr(uuid_generate_v4()::text, 20, 1) ~ '[89ab]'" "t"
check "SELECT substr(uuid_generate_v1()::text, 15, 1)" "1"
check "SELECT substr(uuid_generate_v1()::text, 25) = substr(uuid_generate_v1()::text, 25)" "t"
check "WITH s AS (SELECT i, (('x' || substr(u, 15, 4) || substr(u, 10, 4) || substr(u, 1, 8))::bit(64) & x'0FFFFFFFFFFFFFFF')::bigint AS ts FROM (SELECT i, uuid_generate_v1()::text AS u FROM generate_series(1, 10) AS i) g) SELECT count(DISTINCT ts) = 10 AND max(ts) FILTER (WHERE i = 10) = max(ts) FROM s" "t"
check "SELECT (('x' || substr(uuid_generate_v1mc()::text, 25, 2))::bit(8) & B'00000001') = B'00000001'" "t"
check "SELECT uuid_generate_v1() <> uuid_generate_v1()" "t"

# intarray
# Its @>, <@ and && over int[] take precedence over the server's anyarray
# operators; the two agree on these arrays.
check "CREATE EXTENSION intarray"
check "SELECT '{1,2,3}'::int[] @> '{2}'" "t"
check "SELECT sort('{3,1,2}'::int[])" "{1,2,3}"
check "SELECT uniq(sort('{1,1,2}'::int[]))" "{1,2}"
check "SELECT '{1,2,3}'::int[] - 2" "{1,3}"
check "SELECT '{1,2,3}'::int[] @@ '1&3'::query_int" "t"
check "SELECT idx('{1,2,3}'::int[], 2)" "2"
check "CREATE TABLE smoke_intarray AS SELECT id, ARRAY[id, id % 7, id % 11] AS tags FROM generate_series(1, 2000) id"
check "CREATE INDEX smoke_intarray_index ON smoke_intarray USING gin (tags gin__int_ops)"
check "ANALYZE smoke_intarray"
check "SET enable_seqscan = off; EXPLAIN (COSTS OFF) SELECT id FROM smoke_intarray WHERE tags @> '{1234}'" \
  "Bitmap Heap Scan on smoke_intarray
  Recheck Cond: (tags @> '{1234}'::integer[])
  ->  Bitmap Index Scan on smoke_intarray_index
        Index Cond: (tags @> '{1234}'::integer[])"
check "SET enable_seqscan = off; SELECT id FROM smoke_intarray WHERE tags @> '{1234}'" "1234"

# cube
check "CREATE EXTENSION cube"
check "SELECT cube_dim('(1,2,3)'::cube)" "3"
check "SELECT cube_distance('(0,0)'::cube, '(3,4)'::cube)" "5"
check "SELECT '(1,2),(3,4)'::cube @> '(2,3)'::cube" "t"
check "SELECT cube_union('(0,0)'::cube, '(1,1)'::cube)" "(0, 0),(1, 1)"
check "CREATE TABLE smoke_cube AS SELECT id, cube(ARRAY[id % 50, id / 50]::float8[]) AS c FROM generate_series(1, 2000) id"
check "CREATE INDEX smoke_cube_index ON smoke_cube USING gist (c)"
check "ANALYZE smoke_cube"
check "SET enable_seqscan = off; EXPLAIN (COSTS OFF) SELECT id FROM smoke_cube WHERE c <@ '(10,10),(12,12)'::cube" \
  "Bitmap Heap Scan on smoke_cube
  Recheck Cond: (c <@ '(10, 10),(12, 12)'::cube)
  ->  Bitmap Index Scan on smoke_cube_index
        Index Cond: (c <@ '(10, 10),(12, 12)'::cube)"
check "SET enable_seqscan = off; SELECT id FROM smoke_cube WHERE c <@ '(10,10),(12,12)'::cube" \
  "510
511
512
560
561
562
610
611
612"

# earthdistance
# Distances are float8, so they are rounded before being compared.
check "CREATE EXTENSION earthdistance"
check "SELECT round(earth_distance(ll_to_earth(0, 0), ll_to_earth(0, 1)))" "111320"
check "SELECT round(('(0,0)'::point <@> '(1,0)'::point)::numeric, 3)" "69.093"
check "SELECT earth_box(ll_to_earth(0, 0), 1000) @> ll_to_earth(0.001, 0.001)" "t"

# bloom
check "CREATE EXTENSION bloom"
check "SELECT amname FROM pg_am WHERE amname = 'bloom'" "bloom"
check "CREATE TABLE smoke_bloom AS SELECT id, id % 61 AS a, id % 59 AS b FROM generate_series(1, 10000) id"
check "CREATE INDEX smoke_bloom_index ON smoke_bloom USING bloom (a, b)"
check "ANALYZE smoke_bloom"
check "SET enable_seqscan = off; EXPLAIN (COSTS OFF) SELECT id FROM smoke_bloom WHERE a = 5 AND b = 7" \
  "Bitmap Heap Scan on smoke_bloom
  Recheck Cond: ((a = 5) AND (b = 7))
  ->  Bitmap Index Scan on smoke_bloom_index
        Index Cond: ((a = 5) AND (b = 7))"
check "SET enable_seqscan = off; SELECT id FROM smoke_bloom WHERE a = 5 AND b = 7 ORDER BY id" \
  "66
3665
7264"

# tsm_system_rows
# Which rows a sample holds varies; how many does not.
check "CREATE EXTENSION tsm_system_rows"
check "CREATE TABLE smoke_tsm_system_rows AS SELECT id FROM generate_series(1, 10000) id"
check "ANALYZE smoke_tsm_system_rows"
check "SELECT count(*) FROM smoke_tsm_system_rows TABLESAMPLE SYSTEM_ROWS(100)" "100"
check "SELECT count(*) FROM smoke_tsm_system_rows TABLESAMPLE SYSTEM_ROWS(0)" "0"
check "SELECT count(*) FROM smoke_tsm_system_rows TABLESAMPLE SYSTEM_ROWS(20000)" "10000"
check "EXPLAIN (COSTS OFF) SELECT id FROM smoke_tsm_system_rows TABLESAMPLE SYSTEM_ROWS(100)" \
  "Sample Scan on smoke_tsm_system_rows
  Sampling: system_rows ('100'::bigint)"

# tsm_system_time
# How much a time budget reads depends on the machine, so only no time
# and ample time are checked.
check "CREATE EXTENSION tsm_system_time"
check "CREATE TABLE smoke_tsm_system_time AS SELECT id FROM generate_series(1, 10000) id"
check "ANALYZE smoke_tsm_system_time"
check "SELECT count(*) FROM smoke_tsm_system_time TABLESAMPLE SYSTEM_TIME(0)" "0"
check "SELECT count(*) FROM smoke_tsm_system_time TABLESAMPLE SYSTEM_TIME(100000)" "10000"
check "EXPLAIN (COSTS OFF) SELECT id FROM smoke_tsm_system_time TABLESAMPLE SYSTEM_TIME(100)" \
  "Sample Scan on smoke_tsm_system_time
  Sampling: system_time ('100'::double precision)"

# lo
# lo_manage unlinks a row's large object when the row is deleted.
check "CREATE EXTENSION lo"
check "CREATE TABLE smoke_lo (id int, a lo)"
check "CREATE TRIGGER smoke_lo_trigger BEFORE UPDATE OR DELETE ON smoke_lo FOR EACH ROW EXECUTE FUNCTION lo_manage(a)"
check "INSERT INTO smoke_lo VALUES (1, lo_from_bytea(0, 'hello'::bytea))"
check "SELECT convert_from(lo_get(a), 'UTF8') FROM smoke_lo" "hello"
check "SELECT count(*) FROM pg_largeobject_metadata" "1"
check "DELETE FROM smoke_lo"
check "SELECT count(*) FROM pg_largeobject_metadata" "0"

# isn
check "CREATE EXTENSION isn"
check "SELECT '978-0-00-123403-1'::isbn13" "978-0-00-123403-1"
check "SELECT isbn('0-00-123403-X')" "0-00-123403-X"
check "SELECT '978-0-00-123403-1'::isbn13::isbn" "0-00-123403-X"
check "SELECT '0-00-123403-X'::isbn = '978-0-00-123403-1'::isbn13" "t"
check "SELECT is_valid('978-0-00-123403-1'::isbn13)" "t"
check "SELECT '2001234567893'::ean13" "200-123456789-3"

# seg
check "CREATE EXTENSION seg"
check "SELECT '1.5 .. 2.5'::seg" "1.5 .. 2.5"
check "SELECT '10(+-)1'::seg" "9.0 .. 1.1e1"
check "SELECT '1 .. 3'::seg @> '2'::seg" "t"
check "SELECT '1 .. 3'::seg && '2 .. 5'::seg" "t"
check "SELECT seg_union('1 .. 2', '3 .. 4')" "1 .. 4"
check "CREATE TABLE smoke_seg AS SELECT id, (id || ' .. ' || (id + 1))::seg AS s FROM generate_series(1, 2000) id"
check "CREATE INDEX smoke_seg_index ON smoke_seg USING gist (s)"
check "ANALYZE smoke_seg"
check "SET enable_seqscan = off; EXPLAIN (COSTS OFF) SELECT id FROM smoke_seg WHERE s <@ '1000 .. 1003'::seg" \
  "Bitmap Heap Scan on smoke_seg
  Recheck Cond: (s <@ '1.000e3 .. 1.003e3'::seg)
  ->  Bitmap Index Scan on smoke_seg_index
        Index Cond: (s <@ '1.000e3 .. 1.003e3'::seg)"
check "SET enable_seqscan = off; SELECT id FROM smoke_seg WHERE s <@ '1000 .. 1003'::seg ORDER BY id" \
  "1000
1001
1002"

# dict_int
check "CREATE EXTENSION dict_int"
check "SELECT ts_lexize('intdict', '12345678')" "{123456}"
check "SELECT ts_lexize('intdict', '123')" "{123}"
check "ALTER TEXT SEARCH DICTIONARY intdict (MAXLEN = 4, REJECTLONG = true)"
check "SELECT ts_lexize('intdict', '12345678')" "{}"
check "SELECT ts_lexize('intdict', '1234')" "{1234}"

# tcn
# A notification reaches only a listening session, when its transaction
# commits, so LISTEN goes in the same call as the change.
check "CREATE EXTENSION tcn"
check "CREATE TABLE smoke_tcn (id int PRIMARY KEY, value text)"
check "CREATE TRIGGER smoke_tcn_trigger AFTER INSERT OR UPDATE OR DELETE ON smoke_tcn FOR EACH ROW EXECUTE FUNCTION triggered_change_notification()"
notify_check "LISTEN tcn; INSERT INTO smoke_tcn VALUES (1, 'a')" "NOTIFY tcn \"smoke_tcn\",I,\"id\"='1'"
notify_check "LISTEN tcn; UPDATE smoke_tcn SET value = 'b' WHERE id = 1" "NOTIFY tcn \"smoke_tcn\",U,\"id\"='1'"
notify_check "LISTEN tcn; DELETE FROM smoke_tcn WHERE id = 1" "NOTIFY tcn \"smoke_tcn\",D,\"id\"='1'"

# moddatetime
check "CREATE EXTENSION moddatetime"
check "CREATE TABLE smoke_moddatetime (id int PRIMARY KEY, a text, b timestamptz NOT NULL)"
check "CREATE TRIGGER smoke_moddatetime_trigger BEFORE UPDATE ON smoke_moddatetime FOR EACH ROW EXECUTE FUNCTION moddatetime(b)"
check "INSERT INTO smoke_moddatetime VALUES (1, 'first', '2000-01-01 00:00:00+00')"
check "SELECT b = '2000-01-01 00:00:00+00' FROM smoke_moddatetime" "t"
check "UPDATE smoke_moddatetime SET a = 'second' WHERE id = 1"
check "SELECT b > '2000-01-01 00:00:00+00' AND b <= now() FROM smoke_moddatetime" "t"
# contrib/spi's other trigger modules are neither linked in nor installed.
check "SELECT count(*) FROM pg_available_extensions WHERE name IN ('autoinc', 'insert_username', 'refint')" "0"

# vector
check "CREATE EXTENSION vector"
check "SELECT '[1,2,3]'::vector <-> '[4,5,6]'::vector" "5.196152422706632"
check "SELECT '[1,2,3]'::vector <#> '[4,5,6]'::vector" "-32"
check "SELECT '[1,2,3]'::vector <=> '[4,5,6]'::vector" "0.025368153802923787"
check "SELECT '[1,2,3]'::vector <+> '[4,5,6]'::vector" "9"
check "SELECT vector_dims('[1,2,3]'::vector)" "3"
check "SELECT '[1,2,3]'::halfvec <-> '[4,5,6]'::halfvec" "5.196152422706632"
check "SELECT '{1:1,3:2}/5'::sparsevec <-> '{1:2}/5'::sparsevec" "2.23606797749979"
check "SELECT '[1,2]'::vector + '[3,4]'::vector" "[4,6]"
check "SELECT avg(v) FROM (VALUES ('[1,2]'::vector), ('[3,4]'::vector)) t(v)" "[2,3]"
check "LOAD 'vector'; SELECT current_setting('hnsw.ef_search'), current_setting('ivfflat.probes')" "40	1"
# Both index methods answer approximately, so only the exact match, at
# distance 0, is checked.
check "CREATE TABLE smoke_vector_hnsw (id int PRIMARY KEY, v vector(3))"
check "INSERT INTO smoke_vector_hnsw SELECT id, ARRAY[id % 97, id % 89, id % 83]::float[]::vector(3) FROM generate_series(1, 5000) id"
check "CREATE INDEX smoke_vector_hnsw_index ON smoke_vector_hnsw USING hnsw (v vector_l2_ops)"
check "ANALYZE smoke_vector_hnsw"
check "SELECT v FROM smoke_vector_hnsw WHERE id = 1234" "[70,77,72]"
check "SET enable_seqscan = off; EXPLAIN (COSTS OFF) SELECT id FROM smoke_vector_hnsw ORDER BY v <-> '[70,77,72]' LIMIT 3" \
  "Limit
  ->  Index Scan using smoke_vector_hnsw_index on smoke_vector_hnsw
        Order By: (v <-> '[70,77,72]'::vector)"
check "SET enable_seqscan = off; SELECT id, v <-> '[70,77,72]' FROM smoke_vector_hnsw ORDER BY v <-> '[70,77,72]' LIMIT 1" "1234	0"
check "CREATE TABLE smoke_vector_ivfflat (id int PRIMARY KEY, v vector(3))"
check "INSERT INTO smoke_vector_ivfflat SELECT id, ARRAY[id % 97, id % 89, id % 83]::float[]::vector(3) FROM generate_series(1, 5000) id"
check "CREATE INDEX smoke_vector_ivfflat_index ON smoke_vector_ivfflat USING ivfflat (v vector_l2_ops) WITH (lists = 10)"
check "ANALYZE smoke_vector_ivfflat"
check "SET enable_seqscan = off; EXPLAIN (COSTS OFF) SELECT id FROM smoke_vector_ivfflat ORDER BY v <-> '[70,77,72]' LIMIT 3" \
  "Limit
  ->  Index Scan using smoke_vector_ivfflat_index on smoke_vector_ivfflat
        Order By: (v <-> '[70,77,72]'::vector)"
check "SET enable_seqscan = off; SELECT id, v <-> '[70,77,72]' FROM smoke_vector_ivfflat ORDER BY v <-> '[70,77,72]' LIMIT 1" "1234	0"
# A parallel build's workers start through the module's own entry points.
# The table is too small for the planner to grant workers, so it is told.
check "CREATE TABLE smoke_vector_parallel (id int PRIMARY KEY, v vector(3)) WITH (parallel_workers = 2)"
check "INSERT INTO smoke_vector_parallel SELECT id, ARRAY[id % 97, id % 89, id % 83]::float[]::vector(3) FROM generate_series(1, 5000) id"
check "SET max_parallel_maintenance_workers = 2; SET maintenance_work_mem = '64MB'; CREATE INDEX smoke_vector_parallel_index ON smoke_vector_parallel USING hnsw (v vector_l2_ops)"
check "SET enable_seqscan = off; SELECT id, v <-> '[70,77,72]' FROM smoke_vector_parallel ORDER BY v <-> '[70,77,72]' LIMIT 1" "1234	0"

# pg_stat_statements
# Preloaded at server start: its statistics live in shared memory, so each
# check below is run by one backend and read back by another.
check "SHOW shared_preload_libraries" "pg_stat_statements"
check "CREATE EXTENSION pg_stat_statements"
check "CREATE ROLE smoke_pg_stat_statements"
check "CREATE DATABASE smoke_pg_stat_statements"
check "CREATE TABLE smoke_pg_stat_statements_a (id int)"
check "CREATE TABLE smoke_pg_stat_statements_b (id int)"
check "CREATE FUNCTION smoke_pg_stat_statements_f() RETURNS bigint LANGUAGE plpgsql AS 'BEGIN RETURN (SELECT count(*) FROM smoke_pg_stat_statements_a); END'"
check "SELECT pg_stat_statements_reset() IS NOT NULL" "t"
# One normalised statement is one entry per database and role.
check "SELECT 42 + 1" "43"
check "SELECT 42 + 2" "44"
check "SELECT 42 + 3" "45"
check "SET ROLE smoke_pg_stat_statements; SELECT 42 + 4" "46"
other_database_check "SELECT 42 + 5" "47"
check "SELECT d.datname, r.rolname, s.calls FROM pg_stat_statements s JOIN pg_database d ON d.oid = s.dbid JOIN pg_roles r ON r.oid = s.userid WHERE s.query = 'SELECT \$1 + \$2' ORDER BY 1, 2" \
  "postgres	postgres	3
postgres	smoke_pg_stat_statements	1
smoke_pg_stat_statements	postgres	1"
# Four concurrent sessions update one entry 25 times each without losing any.
concurrent_statements=()
for i in $(seq 25); do
  concurrent_statements+=("SELECT 100 * $i")
done
concurrent_sessions=()
for _ in 1 2 3 4; do
  "${probe[@]}" "${concurrent_statements[@]}" > /dev/null &
  concurrent_sessions+=("$!")
done
for session in "${concurrent_sessions[@]}"; do
  wait "$session" || { echo "a concurrent session failed" >&2; exit 1; }
done
check "SELECT calls FROM pg_stat_statements WHERE query = 'SELECT \$1 * \$2'" "100"
# A parallel query is counted once, by its leader.
check "$parallel_settings; SELECT count(*) FROM parallel_smoke WHERE id % 3 = 0" "6666"
check "SELECT calls, rows, parallel_workers_to_launch, parallel_workers_launched FROM pg_stat_statements WHERE query = 'SELECT count(*) FROM parallel_smoke WHERE id % \$1 = \$2'" "1	1	4	4"
check "SET pg_stat_statements.track = 'all'; SELECT smoke_pg_stat_statements_f()" "0"
check "SELECT calls FROM pg_stat_statements WHERE NOT toplevel AND query LIKE '%FROM smoke_pg_stat_statements_a%'" "1"
check "SET pg_stat_statements.track_planning = on; SELECT 6 * 7 + 1" "43"
check "SELECT plans, calls FROM pg_stat_statements WHERE query = 'SELECT \$1 * \$2 + \$3'" "1	1"
check "SELECT pg_stat_statements_reset(0, 0, (SELECT queryid FROM pg_stat_statements WHERE query = 'SELECT \$1 * \$2')) IS NOT NULL" "t"
check "SELECT count(*) FROM pg_stat_statements WHERE query = 'SELECT \$1 * \$2'" "0"
check "SELECT dealloc FROM pg_stat_statements_info" "0"
# The server's own statistics are shared memory too; pg_stat_force_next_flush
# makes a backend hand its counts over before it answers.
other_database_check "SELECT pg_stat_force_next_flush()"
check "SELECT xact_commit > 0 FROM pg_stat_database WHERE datname = 'smoke_pg_stat_statements'" "t"
check "SELECT count(*) FROM smoke_pg_stat_statements_b; SELECT count(*) FROM smoke_pg_stat_statements_b; SELECT pg_stat_force_next_flush()" "0
0"
check "SELECT seq_scan FROM pg_stat_user_tables WHERE relname = 'smoke_pg_stat_statements_b'" "2"

kill "$server_pid" 2>/dev/null || true
wait "$server_pid" 2>/dev/null || true
server_pid=""

echo "PostgreSQL WASIX smoke test passed."
