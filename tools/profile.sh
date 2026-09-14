#!/usr/bin/env bash
set -euo pipefail

# tools/profile.sh output command [arguments...]: record a command with perf,
# with SERVICECACHE_JITDUMP=1 so ServiceCache writes jitdumps of its guest
# code, then prepare the recording and open perf report. Recording stops when
# the command exits or on Ctrl-C. See PROFILING.md.
#
# output is a new or empty directory. It receives a copy of the command's
# executable, which is what runs, so rebuilding the original leaves the
# recording readable; the raw recording, perf.raw.data; the prepared one,
# perf.data; and control, a FIFO for perf record --control.
#
# PERF            perf to run (default: perf); see PROFILING.md for the builds
#                 that work
# PERF_FREQUENCY  samples per second per thread (default: 499)
# PERF_STACK      bytes of stack copied with each sample (default: 32768)
# PERF_DELAY      perf record --delay; -1 starts with sampling off, and
#                 "echo 'enable cycles:u' > output/control" turns it on

if (( $# < 2 )); then
  echo "usage: $0 output command [arguments...]" >&2
  exit 2
fi
perf="${PERF:-perf}"
output="$1"
executable="$(command -v "$2")" || {
  echo "command not found: $2" >&2
  exit 1
}
shift 2
delay=()
if [[ -n "${PERF_DELAY:-}" ]]; then
  delay=("--delay=$PERF_DELAY")
fi

log() {
  printf '[%(%H:%M:%S)T] %s\n' -1 "$*" >&2
}
TIMEFORMAT='  took %1Rs'

version="$("$perf" version)"
log "using $(command -v -- "$perf"), $version"
if [[ "$version" =~ ^perf\ version\ 7\.[0-2]([.-]|$) ]]; then
  log "warning: perf 7.0 to 7.2 may drop call graphs; see PROFILING.md"
fi

# Guest call graphs require perf's libdw unwinder. `dwarf-unwind` says
# that some DWARF unwinder is enabled, while `libdw-dwarf-unwind` only
# says that perf has libdw support. Newer perf can select libdw at report
# time; older perf selects libunwind whenever that backend was built in.
if ! "$perf" check feature -q dwarf-unwind,libdw-dwarf-unwind; then
  echo "$perf cannot unwind with libdw, or is too old to tell;" \
    "see PROFILING.md" >&2
  exit 1
fi

unwind_style=()
report_help="$("$perf" report -h 2>&1 || true)"
if [[ "$report_help" == *--unwind-style* ]]; then
  unwind_style=(--unwind-style=libdw)
elif "$perf" check feature -q libunwind; then
  echo "$perf uses libunwind rather than libdw; see PROFILING.md" >&2
  exit 1
fi

mkdir -p -- "$output"
if [[ -n "$(ls -A -- "$output")" ]]; then
  echo "output directory is not empty: $output" >&2
  exit 1
fi
output="$(realpath -- "$output")"
copy="$output/$(basename -- "$executable")"
cp --reflink=auto -- "$executable" "$copy"
mkfifo -- "$output/control"

# -k 1 stamps samples with CLOCK_MONOTONIC, the clock jitdumps use. Child
# processes and threads are recorded too. Ctrl-C reaches perf and the command;
# catching it here lets the script go on to prepare the recording. Do not add
# -z: perf inject --jit does not find the jitdumps in a compressed recording,
# so guest functions would go unnamed.
log "recording $(basename -- "$executable") into $output (Ctrl-C to stop)"
status=0
trap : INT
SERVICECACHE_JITDUMP=1 "$perf" record -k 1 -e cycles:u \
  -F "${PERF_FREQUENCY:-499}" --call-graph "dwarf,${PERF_STACK:-32768}" \
  -m 2M "${delay[@]}" --control "fifo:$output/control" \
  -o "$output/perf.raw.data" -- "$copy" "$@" || status=$?
trap - INT
if (( status != 0 && status != 130 )); then
  log "perf record exited with status $status"
  exit "$status"
fi

# 1. Read the jitdumps. The recording holds each process's mapping of its
# jitdump, /tmp/jitted-wasmer-*/jit-<pid>.dump. For every function a dump
# describes, perf inject writes an ELF file beside it with the function's code,
# name and unwind information, and adds an event mapping that file at the
# function's address, at the time the dump gives. With -b --buildid-all, the
# header lists the build ID of every file the recording maps, including files
# no sample landed in but a call graph passes through.
log "reading jitdumps (1/3)"
time "$perf" inject --jit -b --buildid-all \
  -i "$output/perf.raw.data" -o "$output/perf.jit.data"

# 2. Optional: the output of pass 1 is already a complete recording. This pass
# does work up front so that perf report opens the recording quickly every
# time after: it puts each file's build ID into its mapping events. Without
# them, perf report learns each file's identity as it reads the mappings and
# re-sorts its list of files every time, which is slow when there are many
# mappings, and a guest has one per function.
log "adding build IDs to mappings (2/3); this can be slow"
time "$perf" inject --mmap2-buildid-all \
  -i "$output/perf.jit.data" -o "$output/perf.mmap.data"

# 3. Needed only because of pass 2, which does not carry the header's build ID
# list over: write it again in full, as pass 1 did, for perf buildid-list and
# similar tools.
log "writing the build ID list (3/3)"
time "$perf" inject -b --buildid-all \
  -i "$output/perf.mmap.data" -o "$output/perf.data"

# Keep only the raw recording and the prepared one.
rm -f -- "$output/perf.jit.data" "$output/perf.mmap.data"

log "profile: $output/perf.data"
report=("$perf" report --no-inline "${unwind_style[@]}" -i "$output/perf.data")
if [[ -t 0 && -t 1 ]]; then
  exec "${report[@]}"
fi
log "read it with: ${report[*]}"
