#!/usr/bin/env bash
# run.sh [DIRECTORY]: run the fixtures toolchain/smoke/build.sh compiled
# under the Wasmer CLIs built from source, and check what each prints. With no
# argument they are the flake's smoke-toolchain output, copied to
# work/build/toolchain-smoke, which is also where the manager's own tests look
# for them. A DIRECTORY holds fixtures already built, and may be read-only.
set -euo pipefail

SC_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

fail() {
  echo "error: $*" >&2
  exit 1
}

if [[ $# -eq 0 ]]; then
  built="$("$SC_ROOT/toolchain/nix.sh" build .#smoke-toolchain)"
  [[ -d "$built" ]] || fail "the build of smoke-toolchain printed no directory: ${built:-nothing}"
  modules="$SC_ROOT/work/build/toolchain-smoke"
  rm -rf "$modules"
  mkdir -p "$modules"
  cp -r --preserve=mode "$built/." "$modules/"
  chmod -R u+w "$modules"
else
  [[ $# -eq 1 && -d "$1" ]] || fail "usage: $0 [directory]"
  modules="$(cd "$1" && pwd)"
fi
command -v timeout >/dev/null 2>&1 || fail "required host command not found: timeout"

"$SC_ROOT/wasmer/build.sh" stock >/dev/null ||
  fail "could not build the stock Wasmer CLI (wasmer/build.sh stock)"
# Guest fixtures for the fixes patch set run under the fixes variant: stock
# does not carry the behaviour they test.
"$SC_ROOT/wasmer/build.sh" fixes >/dev/null ||
  fail "could not build the fixes Wasmer CLI (wasmer/build.sh fixes)"
stock="$SC_ROOT/work/wasmer/stock/bin/wasmer"
fixes="$SC_ROOT/work/wasmer/fixes/bin/wasmer"

# expect_stock module expected-output [wasmer-run-option...]
expect_stock() {
  local module="$1" expected="$2" output
  shift 2
  output="$("$stock" run "$@" "$modules/$module")" || fail "$module failed"
  [[ "$output" == "$expected" ]] || fail "$module: expected \"$expected\", got \"$output\""
  printf '%s\n' "$output"
}

# The fixtures that write a file do it where they are started, and the
# modules may be in a read-only directory, so they are started in one of
# their own.
scratch="$(mktemp -d "${TMPDIR:-/tmp}/toolchain-smoke.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT

# expect_fixes module expected-output [time-limit]: PATH covers a fixture's
# spawn-by-name of itself. A runtime deadlock can also prevent a guest
# watchdog from exiting, hence the limit. Wasmer resets the terminal as it
# starts, which stops a process in a background process group, so timeout
# keeps it in the foreground.
expect_fixes() {
  local output
  local -a watchdog=()
  if [[ -n "${3:-}" ]]; then
    watchdog=(timeout --foreground --kill-after=2s "$3")
  fi
  output="$("${watchdog[@]}" "$fixes" run --net \
    --volume "$modules:$modules" --volume "$scratch:$scratch" --cwd "$scratch" \
    --env "PATH=$modules" "$modules/$1")" ||
    fail "$1 failed under the fixes variant"
  [[ "$output" == "$2" ]] || fail "$1: expected \"$2\", got \"$output\""
  printf '%s\n' "$output"
}

expect_stock wasix_cpp.wasm $'WASIX C++ exception works\nWASIX pthread works'

# Two threads making relative-path syscalls at once must not corrupt each
# other's paths, select() and pselect() must wait for a timeout under one
# second rather than return at once, a program given an environment must
# start whether or not it references environ, and threads that end must give
# their memory back to malloc.
"$stock" run "$modules/relpath-race.wasm" > /dev/null ||
  fail "relative-path race smoke test failed"
echo "WASIX relative-path race test passed"
expect_stock select-sleeps.wasm "WASIX select and pselect wait for their timeouts"
expect_stock getenv-at-start.wasm \
  "WASIX starts with an environment and no reference to environ" \
  --env "SC_SMOKE_GETENV=set by run.sh"
expect_stock malloc-threads.wasm "WASIX malloc works across threads"

expect_fixes signal-epoll.wasm "WASIX signal wakes every epoll registration"
expect_fixes epoll-interest-switch.wasm "WASIX epoll interest switch keeps level readiness"
expect_fixes epoll-close-during-dispatch.wasm \
  "WASIX epoll sets close during dispatch without wedging the selector" 20s
expect_fixes signal-during-handler.wasm "WASIX signal during a handler still wakes the wait"
expect_fixes lseek-under-signal.wasm "WASIX seeks and syncs survive a signal flood"
