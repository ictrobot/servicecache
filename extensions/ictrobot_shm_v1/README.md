# ictrobot_shm_v1: cross-process shared memory for WASIX

WASIX has no cross-process shared memory: `mmap` is implemented inside
the guest's libc over private linear memory, and `fork()` deep-copies
that memory, so a nominally `MAP_SHARED` mapping becomes an independent
copy in every virtual process. This extension adds the missing
primitive: a guest asks the runtime to map a `/dev/shm` object's
contents over a range of its own linear memory, and every process that
maps the same object sees the same bytes.

The namespace is versioned and frozen: `ictrobot_shm_v1` never changes
shape. Additions or changed semantics arrive as a new namespace.

## Requirements and instantiation

- wasm32 only. There is no 64-bit ABI; one can be added as its own
  namespace when a wasm64 WASIX guest can exist.
- Provided by a runtime carrying this extension's patch set
  ([`patches/`](patches/), for the `sys` backend on Linux). A module
  that imports the namespace fails to instantiate, loudly, on any
  runtime that does not provide it. Import the namespace only from
  binaries that require it.
- Backing objects are ordinary `shm_open` descriptors: the runtime
  backs `/dev/shm` with memory files, and `ftruncate` sizes them. The
  descriptor must be open for reading and writing.

## Functions

Sizes and addresses are in bytes. `page` is the WebAssembly page size, 65536.
All of `address`, `length` and `offset` must be multiples of `page`, and
`length` must be non-zero.

```wat
;; (import "ictrobot_shm_v1" "fd_map"
;;   (func (param $fd i32) (param $address i32)
;;         (param $length i32) (param $offset i64) (result i32)))
;; (import "ictrobot_shm_v1" "fd_unmap"
;;   (func (param $address i32) (param $length i32) (result i32)))
```

Both return a WASI errno: 0 on success. The C declarations, and thin
wrappers that convert the errno into the usual -1-and-`errno`
convention, are in [`ictrobot_shm_v1.h`](ictrobot_shm_v1.h).

### fd_map(fd, address, length, offset) → errno

Replaces `[address, address+length)` of the calling process's linear
memory with the contents of the object behind `fd`, starting at byte
`offset` of the object. The range must already be valid guest memory —
obtain it with an ordinary anonymous `mmap` — and `[offset,
offset+length)` must lie within the object's current size. After
success, loads and stores in the range act on the shared object:
every process mapping the same object range observes the same bytes.

Errors: `EINVAL` (zero or unaligned `address`/`length`/`offset`, range
beyond the object's size, or the overlay failed), `EOVERFLOW`
(`address+length` or `offset+length` overflows), `EBADF` (not an open
file descriptor), `EACCES` (descriptor not open read-write), `ENODEV`
(descriptor is not a `/dev/shm` object), `EEXIST` (the range overlaps a
mapping this process already holds), `EFAULT` (no memory attached).

### fd_unmap(address, length) → errno

Removes one mapping previously established by `fd_map`. `address` and
`length` must name that mapping exactly; partial unmaps are not part of
version 1. The range returns to private, zero-filled memory.

Errors: `EINVAL` (zero or unaligned arguments, no mapping with exactly
this address and length, or the restore failed), `EFAULT` (no memory
attached).

## Semantics

- **Lifetime.** A mapping belongs to the virtual process that created
  it. Closing `fd` or `shm_unlink`ing the object's name does not remove
  existing mappings; the object lives until the last mapping and
  descriptor are gone.
- **fork.** A forked child inherits its parent's mappings: the same
  guest addresses map the same shared object ranges, so parent and
  child communicate through them immediately.
- **exec.** As on Linux, no mapping survives `exec`; the object's name
  and descriptors do. The new image re-attaches explicitly.
- **Growth.** `memory.grow` extends a WASIX linear memory in place,
  since it is shared with a declared maximum and reserved in full up
  front, and leaves mappings untouched. A grow that would have to move
  the allocation fails rather than silently privatise the mapped pages.
- **Futexes.** A futex word inside a mapped range takes its identity
  from the shared object and offset, not the guest address: waits and
  wakes pair across processes, so process-shared pthread primitives
  and `sem_t` work inside a mapping. A process's `fd_map` or `fd_unmap`
  racing its own futex calls on the range is undefined, as on Linux
  when remapping under a live futex: establish or replace a mapping
  before using futexes inside it.
- **Coherence.** Mapped pages are host shared memory. Plain loads and
  stores are not synchronization; use atomics or the futex-backed
  primitives above, exactly as between threads.

## Why this shape

A wasm32 guest has one linear memory, and every C pointer is an offset
into it. A shared page therefore cannot arrive as a new range the way
`mmap` returns one: there is no address space outside the allocation,
and although wasm allows a module several memories, no C toolchain can
address a second one. The only place a shared page can exist is inside
pages the guest already owns, so `fd_map` replaces a caller-chosen,
caller-allocated range — closer to SysV `shmat` with `SHM_REMAP`,
which attaches a named segment over the existing mappings at a chosen
address, than to POSIX `mmap`. The costs follow from that shape: the
donated range's contents are destroyed on map and come back as zeros
on unmap, and the caller keeps the allocation alive for the mapping's
lifetime.

The mapping must be a real host shared page rather than copies the
runtime keeps coherent: process-shared semaphores and futexes need one
kernel identity per word, which is what the futex semantics above rest
on, and a copy scheme would reintroduce exactly the divergence this
extension exists to remove.

Making `shm_open` + `mmap(MAP_SHARED)` quietly start sharing was
rejected. wasix-libc's `mmap` keeps its private behaviour everywhere,
portable programs keep the semantics they were tested with, and
sharing happens only where a program was deliberately ported to ask
for it — failing loudly anywhere it cannot be provided. If toolchains
ever address multiple memories, importing a segment as its own memory
would be the cleaner ABI.

## Demo

[`demo.c`](demo.c) is a self-contained two-process walkthrough: the
parent creates and maps an object, spawns a child that maps the same
name, the two exchange a value through the page under a process-shared
semaphore, and the object's name and descriptor are dropped while the
mappings live on. Its smoke test builds it with the WASIX toolchain
and runs it under the extensions variant, a patched Wasmer carrying
the extension patch set and fixes:

```sh
make smoke-extension-ictrobot_shm_v1
```
