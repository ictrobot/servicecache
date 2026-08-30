#!/usr/bin/env bash
# TLS through the bundled wolfSSL, server and client. Connector/C on wolfSSL
# is not an upstream configuration, so the principal patched TLS paths are
# exercised: server verification, TLS version and cipher selection, client
# certificates, a CA directory, a revocation list. Needs an openssl on the
# host for the throwaway certificates; skipped with a note without one.
set -euo pipefail

source "$(dirname "$0")/../../../toolchain/lib.sh"
sc_init mariadb "${1:?usage: $0 version}"

if ! command -v openssl >/dev/null 2>&1; then
  echo "openssl not found on the host; skipping the TLS test" >&2
  exit 0
fi

service_dir="$SC_OUT/mariadb-$SC_VERSION"
server_module="$service_dir/mariadbd.wasm"
client_module="$service_dir/mariadb.wasm"
share_dir="$service_dir/share"
address="${MARIADB_WASIX_BIND_ADDRESS:-127.0.0.1}"
port="${MARIADB_WASIX_PORT:-3306}"

mkdir -p "$SC_WORK"
tls_dir="$(mktemp -d "$SC_WORK/mariadb-tls.XXXXXX")"
data_dir="$tls_dir/data"
tmp_dir="$tls_dir/tmp"
server_log="$tls_dir/mariadbd.log"
server_pid=""
mkdir -p "$data_dir" "$tmp_dir" "$tls_dir/capath"

cleanup() {
  if [[ -n "$server_pid" ]]; then
    kill "$server_pid" 2>/dev/null || true
    wait "$server_pid" 2>/dev/null || true
  fi
  rm -rf -- "$tls_dir"
}
trap cleanup EXIT

# A CA and an unrelated one; server certificates for the bind address and
# for another name; a client certificate; the CA in a hashed directory; a
# revocation list, empty and with the server certificate revoked.
issue() {
  local name="$1" subject="$2" san="$3"
  openssl req -newkey rsa:2048 -nodes -subj "$subject" \
    -keyout "$tls_dir/$name.key" -out "$tls_dir/$name.csr" >/dev/null 2>&1
  openssl x509 -req -in "$tls_dir/$name.csr" -days 2 \
    -CA "$tls_dir/ca.crt" -CAkey "$tls_dir/ca.key" -CAcreateserial \
    -extfile <(printf 'subjectAltName=%s\n' "$san") \
    -out "$tls_dir/$name.crt" >/dev/null 2>&1
}
self_signed_ca() {
  openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj "/CN=$1" \
    -addext "basicConstraints=critical,CA:TRUE" \
    -addext "keyUsage=critical,keyCertSign,cRLSign" \
    -keyout "$tls_dir/$1.key" -out "$tls_dir/$1.crt" >/dev/null 2>&1
}
self_signed_ca ca
self_signed_ca other-ca
issue server "/CN=$address" "IP:$address"
issue other "/CN=other.example" "DNS:other.example"
issue client "/CN=tls-user" "DNS:tls-user"
openssl rsa -in "$tls_dir/client.key" -traditional -out "$tls_dir/client-rsa.key" 2>/dev/null
cat "$tls_dir/client.crt" "$tls_dir/client.key" >"$tls_dir/client-both.pem"
cp "$tls_dir/ca.crt" "$tls_dir/capath/$(openssl x509 -hash -noout -in "$tls_dir/ca.crt").0"
printf '[ca]\ndefault_ca = tls_test\n[tls_test]\ndatabase = %s/index.txt\ncrlnumber = %s/crlnumber\n' \
  "$tls_dir" "$tls_dir" >"$tls_dir/ca.cnf"
printf 'default_md = sha256\nprivate_key = %s/ca.key\ncertificate = %s/ca.crt\ndefault_crl_days = 2\n' \
  "$tls_dir" "$tls_dir" >>"$tls_dir/ca.cnf"
: >"$tls_dir/index.txt"
echo 01 >"$tls_dir/crlnumber"
openssl ca -config "$tls_dir/ca.cnf" -gencrl -out "$tls_dir/empty.crl" >/dev/null 2>&1
openssl ca -config "$tls_dir/ca.cnf" -revoke "$tls_dir/server.crt" >/dev/null 2>&1
openssl ca -config "$tls_dir/ca.cnf" -gencrl -out "$tls_dir/revoked.crl" >/dev/null 2>&1

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

# Retried once, as in smoke.sh.
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

probe=("$SC_SERVICE_DIR/smoke/mysql-probe.py" --host "$address" --port "$port")

# $1 < $2, comparing dotted version numbers.
version_lt() {
  [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -n1)" = "$1" ]
}

# The server with the given certificate, ready to answer the probe.
start_server() {
  "$SC_TOOLCHAIN/run-wasix.sh" "$server_module" \
    --no-defaults \
    "${common_args[@]}" \
    --port="$port" \
    --bind-address="$address" \
    --socket= \
    --pid-file="$tls_dir/mariadbd.pid" \
    --innodb-open-files=64 \
    --ssl-ca="$tls_dir/ca.crt" \
    --ssl-cert="$tls_dir/$1.crt" \
    --ssl-key="$tls_dir/$1.key" \
    --console >>"$server_log" 2>&1 &
  server_pid=$!
  for ((attempt = 0; attempt < 300; attempt++)); do
    if "${probe[@]}" "SELECT 1" >/dev/null 2>&1; then
      return
    fi
    if ! kill -0 "$server_pid" 2>/dev/null; then
      break
    fi
    sleep 0.1
  done
  echo "MariaDB did not become ready on $address:$port" >&2
  sed -n '1,240p' "$server_log" >&2
  exit 1
}

stop_server() {
  "${probe[@]}" "SHUTDOWN" >/dev/null
  for ((attempt = 0; attempt < 300; attempt++)); do
    if ! kill -0 "$server_pid" 2>/dev/null; then
      wait "$server_pid" || true
      server_pid=""
      return
    fi
    sleep 0.1
  done
  echo "MariaDB did not exit within 30s of SHUTDOWN" >&2
  exit 1
}

# check <description> <statement> <expected line pattern> <client options...>:
# the client's output for the statement must contain a line matching the
# pattern — a result, or the expected error.
check() {
  local description="$1" statement="$2" pattern="$3" output
  shift 3
  output="$(printf '%s\n' "$statement" \
    | "$SC_TOOLCHAIN/run-wasix.sh" "$client_module" \
        --no-defaults -h "$address" -P "$port" --batch "$@" 2>&1 || true)"
  if ! grep -Eq "$pattern" <<<"$output"; then
    echo "TLS check failed: $description" >&2
    printf '%s\n' "$output" >&2
    exit 1
  fi
  echo "ok: $description"
}

cipher="SHOW STATUS LIKE 'Ssl_cipher';"
version="SHOW STATUS LIKE 'Ssl_version';"
has_cipher=$'^Ssl_cipher\t[^[:space:]]+$'
tls_error='^ERROR 2026 '
ca=(--ssl-ca="$tls_dir/ca.crt")

start_server server
server_version="$("${probe[@]}" "SELECT @@version" | tail -n1 | cut -d- -f1)"
"${probe[@]}" "CREATE USER 'tls-user'@'%' REQUIRE X509" >/dev/null
check "the client negotiates TLS when the server offers it" "$cipher" "$has_cipher" -u root
check "verified against the CA" "$version" $'^Ssl_version\tTLSv1\\.[23]$' -u root --ssl --ssl-verify-server-cert "${ca[@]}"
check "verified against a CA directory" "$version" $'^Ssl_version\tTLSv1\\.[23]$' -u root --ssl --ssl-verify-server-cert --ssl-capath="$tls_dir/capath"
check "rejected under another CA" "SELECT 1;" "$tls_error" -u root --ssl --ssl-verify-server-cert --ssl-ca="$tls_dir/other-ca.crt"
check "TLSv1.2 on request" "$version" $'^Ssl_version\tTLSv1\\.2$' -u root --ssl --tls-version=TLSv1.2
check "a requested cipher" "$cipher" $'^Ssl_cipher\tECDHE-RSA-AES128-GCM-SHA256$' -u root --ssl --tls-version=TLSv1.2 --ssl-cipher=ECDHE-RSA-AES128-GCM-SHA256
check "REQUIRE X509 refuses a client without a certificate" "SELECT 1;" '^ERROR 1045 ' -u tls-user --ssl
check "a client certificate with a PKCS#8 key" "SELECT USER();" '^tls-user@' -u tls-user --ssl-cert="$tls_dir/client.crt" --ssl-key="$tls_dir/client.key"
check "a client certificate with a traditional RSA key" "SELECT USER();" '^tls-user@' -u tls-user --ssl-cert="$tls_dir/client.crt" --ssl-key="$tls_dir/client-rsa.key"
check "a client certificate and key in one file" "SELECT USER();" '^tls-user@' -u tls-user --ssl-cert="$tls_dir/client-both.pem"
check "an empty revocation list" "$version" $'^Ssl_version\tTLSv1\\.[23]$' -u root --ssl --ssl-verify-server-cert "${ca[@]}" --ssl-crl="$tls_dir/empty.crl"
check "a revoked server certificate" "SELECT 1;" "$tls_error" -u root --ssl --ssl-verify-server-cert "${ca[@]}" --ssl-crl="$tls_dir/revoked.crl"
stop_server

# Hostname/IP-SAN mismatch is only enforced by the older client. Connector/C
# 3.4.2+ (bundled from MariaDB 11.4.4) skips hostname verification for a
# connection it classifies as local: with 127.0.0.1, --ssl-verify-server-cert
# still requests certificate-chain verification but not
# MARIADB_TLS_VERIFY_HOST, so a mismatched name is not rejected. Assert the
# rejection only for a client that does enforce it.
if version_lt "$server_version" 11.4.4; then
  start_server other
  check "a certificate for another name is rejected when verifying" "SELECT 1;" "$tls_error" -u root --ssl --ssl-verify-server-cert "${ca[@]}"
  check "and accepted when not" "$cipher" "$has_cipher" -u root --ssl
  stop_server
else
  echo "skipped: hostname verification of local connections (Connector/C 3.4.2+, server $server_version)"
fi

echo "MariaDB WASIX TLS test passed."
