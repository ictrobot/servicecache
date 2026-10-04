#!/usr/bin/env bash
# build.sh: compile the toolchain's fixtures into SC_OUT_DIR, one module each,
# with the guest-cc and guest-c++ on PATH (toolchain/guest).
# toolchain/smoke/run.sh runs what this builds.
set -euo pipefail

sources="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
out="${SC_OUT_DIR:?SC_OUT_DIR is not set}"
mkdir -p "$out"

# C++ exceptions and threads together.
guest-c++ -O2 -pthread "$sources/threads-exceptions.cpp" -o "$out/wasix_cpp.wasm"

# For the manager's own tests: they report what they see of stdin and of the
# network, so the embedded runtime can be checked without any service.
guest-cc -O2 "$sources/stdio-net.c" -o "$out/stdio-net.wasm"
guest-cc -O2 "$sources/netprobe.c" -o "$out/netprobe.wasm"

# The libc patches (toolchain/sources/wasix-libc/patches and
# toolchain/sources/mimalloc/patches); each fixture fails without the change
# it checks.
guest-cc -O2 -pthread "$sources/relpath-race.c" -o "$out/relpath-race.wasm"
guest-cc -O2 "$sources/select-sleeps.c" -o "$out/select-sleeps.wasm"
guest-cc -O2 "$sources/getenv-at-start.c" -o "$out/getenv-at-start.wasm"
guest-cc -O2 -pthread "$sources/malloc-threads.c" -o "$out/malloc-threads.wasm"

# The Wasmer fixes patch set.
guest-cc -O2 -pthread "$sources/signal-epoll.c" -o "$out/signal-epoll.wasm"
guest-cc -O2 -pthread "$sources/epoll-interest-switch.c" -o "$out/epoll-interest-switch.wasm"
guest-cc -O2 -pthread "$sources/epoll-close-during-dispatch.c" \
  -o "$out/epoll-close-during-dispatch.wasm"
guest-cc -O2 -pthread "$sources/signal-during-handler.c" -o "$out/signal-during-handler.wasm"
guest-cc -O2 "$sources/lseek-under-signal.c" -o "$out/lseek-under-signal.wasm"
guest-cc -O2 "$sources/socket-filetypes.c" -o "$out/socket-filetypes.wasm"
guest-cc -O2 "$sources/poll-zero-timeout.c" -o "$out/poll-zero-timeout.wasm"
guest-cc -O2 "$sources/root-create.c" -o "$out/root-create.wasm"
guest-cc -O2 "$sources/dir-fsync.c" -o "$out/dir-fsync.wasm"
guest-cc -O2 "$sources/unlink-directory.c" -o "$out/unlink-directory.wasm"
guest-cc -O2 "$sources/rename-symlink.c" -o "$out/rename-symlink.wasm"
guest-cc -O2 -pthread "$sources/memfs-race.c" -o "$out/memfs-race.wasm"
guest-cc -O2 -pthread "$sources/flush-while-writing.c" -o "$out/flush-while-writing.wasm"
guest-cc -O2 -pthread "$sources/create-race.c" -o "$out/create-race.wasm"
