#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/../../toolchain/lib.sh"
sc_init mysql "${1:?usage: ${BASH_SOURCE[0]} version}"

# MySQL 8.4 and later bundle Boost; 8.0 pins the release to download.
case "${BOOST_VERSION:-}" in
  "") ;;
  1.77.0) boost_sha256=fc9f85fc030e233142908241af7a846e60630aa7388de9a5fafb1f3a26840854 ;;
  *) sc_fail "unsupported Boost version: $BOOST_VERSION"; return 1 2>/dev/null || exit 1 ;;
esac

MYSQL_DEPS_DIR="$SC_WORK/deps/mysql"
MYSQL_OPENSSL_DIR="$(sc_lib_dir openssl "$OPENSSL_VERSION")"
MYSQL_BOOST_DIR="${BOOST_VERSION:+$MYSQL_DEPS_DIR/boost-$BOOST_VERSION}"
export MYSQL_DEPS_DIR MYSQL_OPENSSL_DIR MYSQL_BOOST_DIR

install_boost_source() {
  local boost_archive_version="${BOOST_VERSION//./_}"
  local archive="$MYSQL_BOOST_DIR/boost_${boost_archive_version}.tar.bz2"
  local source_dir="$MYSQL_BOOST_DIR/boost_${boost_archive_version}"
  local command_name
  local url="https://archives.boost.io/release/$BOOST_VERSION/source/boost_${boost_archive_version}.tar.bz2"

  for command_name in curl sha256sum tar; do
    command -v "$command_name" >/dev/null 2>&1 ||
      { sc_fail "required host command not found: $command_name"; return 1; }
  done

  mkdir -p "$MYSQL_BOOST_DIR" || return 1
  sc_download "$url" "$archive" "$boost_sha256" || return 1
  if [[ ! -e "$source_dir" ]]; then
    tar -xjf "$archive" -C "$MYSQL_BOOST_DIR" || return 1
  elif [[ ! -f "$source_dir/boost/version.hpp" ]]; then
    sc_fail "unexpected Boost source directory: $source_dir"
    return 1
  fi
  echo "Boost $BOOST_VERSION source is ready"
}

"$SC_SERVICE_DIR/libs/openssl/build.sh" "$OPENSSL_VERSION"
if [[ -n "${BOOST_VERSION:-}" ]]; then
  install_boost_source
fi
