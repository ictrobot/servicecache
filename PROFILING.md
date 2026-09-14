# Profiling

ServiceCache and the patched Wasmer CLI run WebAssembly as native code
generated at run time, which perf cannot name or unwind on its own. Both can
write jitdumps describing that code, so a perf profile names guest functions
and unwinds through them. `tools/profile.sh` records a command with perf and
prepares the recording for reading.

## Requirements

- `kernel.perf_event_paranoid` at 2 or lower, which allows sampling your own
  processes' user space.
- perf that unwinds with libdw: `perf check feature dwarf-unwind` and
  `perf check feature libdw-dwarf-unwind` both on. A perf whose report has no
  `--unwind-style` option, such as 6.19, must also be built without libunwind,
  which it would otherwise use instead; the build below is.
- A perf without the multithreaded unwinding regression, which silently drops
  the call graphs of all but one thread when reading a whole recording. perf
  7.0, including its release candidates, through 7.2 is affected; 6.19 and
  earlier predate it, and 7.3 fixes it. Distributions may backport the
  regression (Linux commit `6b2658b3f36a`) or its fix (`f2effca1ef5d`), so
  check the source rather than the version.

To build perf from a Linux source tree, with the libdw, libelf and slang
development packages installed:

```sh
mkdir -p perf-build
make -C tools/perf O="$PWD/perf-build" NO_LIBUNWIND=1 NO_LIBTRACEEVENT=1 NO_LIBPYTHON=1 NO_LIBPERL=1
```

## tools/profile.sh

```sh
tools/profile.sh output command [arguments...]
```

The script runs `command` under `perf record` with `SERVICECACHE_JITDUMP=1`
set, with DWARF call graphs, until the command exits or you press Ctrl-C. In
that recording, samples in generated code are only addresses in anonymous
memory. Each process also writes a jitdump describing the code it generates,
and maps the file so the recording notes where it is.

The script then runs `perf inject --jit`. It reads each jitdump, writes an ELF
file beside it for every function the jitdump describes, holding the
function's code, name and unwind information, and adds a mapping of each file
at its function's address to the recording, placed in time by the jitdump's
timestamps. `-k 1` makes samples use the same clock. `perf report`, which the
script opens last, then names and unwinds guest frames from those files as it
would any other code, so keep the jitdump directories, `/tmp/jitted-wasmer-*`,
until you have finished with the recording.

`output` must be a new or empty directory. It keeps:

- a copy of the command's executable, which is what runs, so rebuilding the
  original leaves the recording readable;
- `perf.raw.data`, the recording as taken;
- `perf.data`, the prepared recording, which
  `perf report --no-inline -i output/perf.data` opens again later;
- `control`, a FIFO for switching sampling on and off.

Settings:

- `PERF`: the perf to run, by default `perf`.
- `PERF_FREQUENCY`: samples per second per thread, by default 499.
- `PERF_STACK`: bytes of stack copied with each sample, by default 32768.
  Raise it if call graphs stop short in deep stacks, such as a debug build's.
- `PERF_DELAY`: passed to `perf record --delay`. With `-1`, sampling starts
  off, and you switch it from another terminal:

  ```sh
  echo 'enable cycles:u' > output/control
  echo 'disable cycles:u' > output/control
  ```

  Name the event: a bare `disable` also stops the tracking of new processes
  and mappings, so a process started meanwhile has unresolved frames.

## Recording ServiceCache

```sh
make build-release service-valkey-9.1.1
tools/profile.sh "$(mktemp -d)" \
  target/release/servicecache --services-dir work/services run valkey@9.1.1
```

Drive a workload against the printed endpoint, then press Ctrl-C. With
`--clones 1`, press Enter to fork a clone. To include every instance a manager
starts, record `serve`.

With `SERVICECACHE_JITDUMP` set, every ServiceCache process writes
`/tmp/jitted-wasmer-*/jit-<pid>.dump`, describing each guest function it
compiles or loads from the cache, and a clone writes its own before its guest
resumes. A sample in guest code, or in ServiceCache code that a guest called,
shows the guest functions that led to it. Guest functions are named from their
module's name section, which service builds keep, then from an export, then as
`wasm[N]`. Calls between native and guest code pass through trampolines named
`wasmer::call_trampoline[N]` and `wasmer::dynamic_trampoline[N]`.

`SERVICECACHE_PERFMAP=1` instead writes only guest function names, to
`/tmp/perf-<pid>.map`, for profiles that need names without call graphs.

## Recording the patched Wasmer CLI

The `jitdump` Wasmer variant builds a CLI whose `--profiler jitdump` writes
the same jitdumps. A sample in guest code shows the guest functions that led
to it.

```sh
make wasmer-jitdump
tools/profile.sh "$(mktemp -d)" \
  work/wasmer/jitdump/bin/wasmer run --profiler jitdump module.wasm
```
