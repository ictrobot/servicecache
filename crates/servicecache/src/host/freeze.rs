//! Freeze is terminal; fork resumes.
//!
//! `freeze` closes the gate so no coroutine can be resumed, drains to
//! quiescence (every guest thread suspended in a wait, no host loop mid-poll,
//! no spawn in flight), then dismantles execution: the guest threads end
//! with the raw `exit` syscall, the selector thread returns and is joined,
//! and tokio's worker ends itself in its park hook. The tokio runtime is
//! abandoned, never dropped or joined, so no destructor runs after
//! quiescence. The process is then one thread, which is verified from
//! `/proc/self/status` before `frozen` is answered. A frozen host is only
//! ever forked or stopped: nothing can resume it in place. Its network
//! presence ends with it (`HostNetworking::shut_down_sockets`): the
//! listener stops accepting and every connection the guest holds is shut
//! down, so a client of the template is disconnected rather than left
//! waiting on a guest that never runs again. Finally, every shared-memory
//! object is copied into private frozen backing and its mappings are
//! retained. A clone therefore inherits neither live connections nor live
//! shared mappings.
//!
//! After the freeze the template releases the all-zero pages of the
//! guest's memory (`Compaction`): an idle guest can hold many, and `fork()`
//! pays for every mapped page. The scan runs in short slices on the control
//! thread while the control channel is quiet, so a fork waits for at most
//! one slice and the freeze itself stays short; the scan takes seconds for
//! a large guest, and a clone forked before it is done shares the pages as
//! they were.
//!
//! `fork` runs on that one thread. The child rebuilds what the parent
//! dismantled — clone-local shared backing replayed from the frozen snapshot,
//! a new tokio runtime (a new fork generation, so every timer re-arms), its
//! own listening socket installed before a new epoll instance can observe
//! it, and fresh OS threads that re-create every registered coroutine's wait
//! and resume it. The parent closes its copies of the child's descriptors
//! and stays frozen.

use std::{
    net::{SocketAddr, TcpListener},
    os::fd::OwnedFd,
    sync::atomic::{AtomicBool, Ordering},
    time::{Duration, Instant},
};

use anyhow::{Context as _, Result, bail};

use super::{Host, die_with_parent};

/// How long a guest gets to reach quiescence.
const DRAIN_TIMEOUT: Duration = Duration::from_secs(10);

/// How long the remaining threads get to end after the drain.
const DISMANTLE_TIMEOUT: Duration = Duration::from_secs(5);

/// How often the thread count is re-read while the last threads end: the
/// tokio worker cannot be joined, and a read costs tens of microseconds.
const DISMANTLE_POLL: Duration = Duration::from_micros(50);

/// Set for the freeze: tokio threads end themselves on their next park.
static TOKIO_EXIT: AtomicBool = AtomicBool::new(false);

/// tokio's `on_thread_park` hook. It runs before the worker transitions to
/// parked, with no lock held.
fn tokio_park_hook() {
    if TOKIO_EXIT.load(Ordering::SeqCst) {
        wasmer_vm::exit_current_thread();
    }
}

/// The tokio runtime a host uses, in the parent and again in every child.
///
/// # Errors
///
/// Fails if the runtime cannot be created.
pub(super) fn build_tokio() -> Result<tokio::runtime::Runtime> {
    tokio::runtime::Builder::new_multi_thread()
        .worker_threads(1)
        .max_blocking_threads(1)
        .thread_name("tokio")
        .on_thread_park(tokio_park_hook)
        .enable_all()
        .build()
        .context("failed to create the tokio runtime")
}

/// The threads of this process by name, from `/proc`.
fn thread_names() -> Vec<String> {
    let Ok(tasks) = std::fs::read_dir("/proc/self/task") else {
        return Vec::new();
    };
    tasks
        .filter_map(Result::ok)
        .map(|task| {
            std::fs::read_to_string(task.path().join("comm"))
                .map_or_else(|_| "?".to_owned(), |name| name.trim().to_owned())
        })
        .collect()
}

/// `Threads:` from `/proc/self/status`.
fn thread_count() -> usize {
    std::fs::read_to_string("/proc/self/status")
        .ok()
        .and_then(|status| {
            status
                .lines()
                .find_map(|line| line.strip_prefix("Threads:"))
                .and_then(|value| value.trim().parse().ok())
        })
        .unwrap_or(0)
}

/// Freezes the guest. Terminal: after this only `fork` and `stop` work, and
/// a failure leaves the host unusable.
///
/// # Errors
///
/// Fails if host-side tasks are in flight, the guest does not reach
/// quiescence in time, or threads remain after dismantling.
pub(super) fn freeze(host: &mut Host) -> Result<usize> {
    let in_flight = host.tasks.shared_tasks_in_flight();
    if in_flight > 0 {
        bail!("{in_flight} host-side task(s) in flight; a fork would lose them");
    }
    let started = Instant::now();
    tracing::info!("freezing");

    wasmer_vm::suspend::close_gate();
    let quiescence = wasmer_vm::suspend::drain(DRAIN_TIMEOUT)
        .map_err(|err| anyhow::anyhow!("{err}"))
        .context("draining the guest")?;
    tracing::debug!(
        coroutines = quiescence.coroutines,
        elapsed = ?started.elapsed(),
        "guest drained"
    );

    host.networking.selector().halt();

    TOKIO_EXIT.store(true, Ordering::SeqCst);
    // Wake the worker so it parks again and sees the flag.
    host.tasks.handle().spawn(async {});

    let deadline = Instant::now() + DISMANTLE_TIMEOUT;
    while thread_count() != 1 {
        if Instant::now() >= deadline {
            bail!(
                "{} threads remain after dismantling: {}",
                thread_count(),
                thread_names().join(", ")
            );
        }
        std::thread::sleep(DISMANTLE_POLL);
    }
    tracing::debug!(elapsed = ?started.elapsed(), "host threads ended");
    host.networking.shut_down_sockets()?;
    // SAFETY: every guest coroutine and host execution thread has ended, and
    // a frozen host can only fork or stop.
    let shared_memory =
        unsafe { wasmer_wasix::freeze_shared_memory() }.context("snapshotting shared memory")?;
    let shared_objects = shared_memory.len();
    host.shared_memory = Some(shared_memory);
    tracing::debug!(shared_objects, "snapshotted shared memory");
    tracing::info!(
        coroutines = quiescence.coroutines,
        elapsed = ?started.elapsed(),
        "frozen"
    );
    Ok(quiescence.coroutines)
}

/// What `fork` returns in each process.
pub(super) enum Forked {
    /// The parent: the child's pid and where the child serves.
    Parent { pid: u32, endpoint: SocketAddr },
    /// The child, with the control end that is now its channel. Unless the
    /// rebuild failed, the guest is running again.
    Child {
        control: OwnedFd,
        rebuilt: Result<()>,
    },
}

/// Forks the frozen host. In the child the guest is running again on
/// `listener`; the parent gets the child's pid and closes the descriptors.
///
/// # Errors
///
/// When `fork` fails. A failed rebuild in the child is reported in
/// `Forked::Child`; the child then has nothing to serve and should exit.
pub(super) fn fork(host: &mut Host, child_control: OwnedFd, listener: OwnedFd) -> Result<Forked> {
    let listener = TcpListener::from(listener);
    let endpoint = listener
        .local_addr()
        .context("the child's listening socket has no address")?;
    let forked_at = Instant::now();
    // SAFETY: the process is single-threaded (verified by `freeze`), so the
    // child inherits no lock held or state half-changed by another thread.
    let pid = unsafe { libc::fork() };
    if pid < 0 {
        return Err(std::io::Error::last_os_error()).context("fork failed");
    }
    if pid == 0 {
        let rebuilt = rebuild(host, listener, forked_at);
        return Ok(Forked::Child {
            control: child_control,
            rebuilt,
        });
    }
    // The syscall's own cost in the template: mostly copying the page tables
    // of the guest's memory.
    tracing::debug!(clone = pid, elapsed = ?forked_at.elapsed(), "fork() returned");
    drop(child_control);
    drop(listener);
    Ok(Forked::Parent {
        pid: pid.unsigned_abs(),
        endpoint,
    })
}

/// In the child: rebuild the host machinery the parent dismantled and
/// resume every coroutine. `forked_at` was taken in the template just
/// before `fork()`, so its elapsed time here spans the syscall too.
fn rebuild(host: &mut Host, listener: TcpListener, forked_at: Instant) -> Result<()> {
    let started = Instant::now();
    // The parent-death signal does not survive a fork; the template is
    // this clone's parent.
    die_with_parent()?;
    tracing::debug!(
        pid = std::process::id(),
        template = nix::unistd::getppid().as_raw(),
        since_fork = ?forked_at.elapsed(),
        "rebuilding in the clone"
    );

    let shared_memory = host
        .shared_memory
        .as_ref()
        .context("the frozen host has no shared-memory snapshot")?;
    // SAFETY: freeze dismantled every guest thread before the native fork, and
    // none are resurrected until the end of this function.
    let shared_objects =
        unsafe { shared_memory.reshare_after_fork() }.context("resharing memory in the clone")?;
    tracing::debug!(shared_objects, elapsed = ?started.elapsed(), "reshared clone memory");

    TOKIO_EXIT.store(false, Ordering::SeqCst);
    let runtime = build_tokio()?;
    host.tasks.replace_runtime(runtime.handle().clone());
    // The parent's runtime: its threads do not exist here and its state is
    // never touched again (`ManuallyDrop`).
    host.tokio = std::mem::ManuallyDrop::new(runtime);
    let tokio_built = started.elapsed();

    let endpoint = listener.local_addr()?;
    host.networking.replace_listener(listener)?;
    host.set_title(super::title::State::Serving(endpoint));
    let listener_replaced = started.elapsed();
    host.networking
        .selector()
        .rebuild_after_fork()
        .context("failed to rebuild the selector")?;
    let selector_rebuilt = started.elapsed();

    let resurrected = wasmer_vm::resurrect_all(&mut |body| {
        std::thread::Builder::new()
            .name("guest".to_owned())
            .stack_size(super::tasks::DRIVER_STACK_SIZE)
            .spawn(body)
            .map(|_| ())
    })
    .map_err(|err| anyhow::anyhow!("{err}"))
    .context("resurrecting the guest threads")?;
    let elapsed = started.elapsed();
    tracing::debug!(
        tokio = ?tokio_built,
        listener = ?listener_replaced.saturating_sub(tokio_built),
        selector = ?selector_rebuilt.saturating_sub(listener_replaced),
        threads = ?elapsed.saturating_sub(selector_rebuilt),
        "clone rebuilt"
    );
    tracing::info!(
        pid = std::process::id(),
        threads = resurrected.threads,
        elapsed = ?elapsed,
        since_fork = ?forked_at.elapsed(),
        "clone running"
    );
    Ok(())
}

/// What a [`Compaction`] found and did, in pages of the host's size.
#[derive(Debug, Default, Clone, Copy)]
struct ZeroPages {
    /// Private anonymous linear memories scanned.
    memories: usize,
    /// Anonymous pages of those memories within their current length.
    scanned: usize,
    /// Pages of those memories inside shared file overlays, left alone.
    overlay: usize,
    /// Of the scanned pages, resident (`mincore`).
    resident: usize,
    /// Of which resident and entirely zero.
    zero: usize,
    /// Zero pages released with `MADV_DONTNEED`.
    released: usize,
    /// Fully resident 2 MiB blocks kept whole because they are not zero
    /// throughout (each may be one huge page); their pages are not counted
    /// one by one.
    kept_blocks: usize,
    /// `madvise` calls made, one per run of released pages.
    runs: usize,
}

/// One linear memory under scan: where it is and how far the scan got.
#[derive(Debug)]
struct MemoryScan {
    base: usize,
    pages: usize,
    /// The mappings (`smaps`) the memory spans, as page index ranges with
    /// whether the mapping holds huge pages: a fully resident 2 MiB block
    /// of one that does is released only when it is zero throughout.
    mappings: Vec<(usize, usize, bool)>,
    /// The anonymous page ranges of the memory, in order: everything but
    /// its shared file overlays. Only these ranges are scanned.
    extents: Vec<(usize, usize)>,
    /// The next page to scan.
    next: usize,
    /// A run of zero pages found but not yet released, as page indices.
    pending: Option<(usize, usize)>,
}

/// The release of a frozen guest's all-zero pages, in slices.
///
/// Every resident, entirely zero page of each private anonymous linear
/// memory is given back with `madvise(MADV_DONTNEED)`. The guest cannot
/// tell: the next touch of such a page reads zeros again. The template keeps
/// less resident, `fork()` copies fewer page-table entries, and clones share
/// less. The scan only ever runs with the guest drained and this the only
/// thread; between slices the process is exactly as it was for a fork.
///
/// A shared file overlay inside a memory is not the guest's anonymous
/// memory: after the freeze it is a private mapping of the frozen file,
/// with no page in the template's page tables, which the runtime keeps out
/// of every fork and a clone replaces wholesale. The scan skips it. It
/// cannot even look: `mincore` reports the page cache for a file mapping,
/// so reading its "resident" pages would fault the frozen file into the
/// template's page tables, more for every fork to copy rather than less.
///
/// A 2 MiB-aligned block whose pages are all resident may be one transparent
/// huge page; dropping part of it would split it into 4 KiB pages, which is
/// more page-table entries for a fork, not fewer. While the mapping holds any
/// huge page, such a block is read once and dropped only when it is zero
/// throughout, and kept whole otherwise; a mapping without huge pages
/// (`AnonHugePages` in `smaps`) has nothing to split and every zero page
/// goes. A memory can span several mappings (its overlays split it,
/// and only some of the rest may have been given huge pages), so `smaps`
/// is read once, when the scan is prepared, and the answer kept for each
/// of them; a page in no known mapping counts as possibly huge, keeping a
/// few pages being the safe error.
#[derive(Debug)]
pub(super) struct Compaction {
    page: usize,
    huge_page: usize,
    memories: Vec<MemoryScan>,
    totals: ZeroPages,
    started: Instant,
    busy: Duration,
    /// Scratch for one block, reused: `mincore`'s byte per page, and which
    /// pages to drop. The template's heap stays as it was between slices.
    resident: Vec<u8>,
    drop: Vec<bool>,
}

impl Compaction {
    /// Prepares the scan of every private anonymous linear memory. For a
    /// drained, single-threaded process only: right after `freeze`. Reading
    /// `smaps` costs milliseconds for a large guest.
    pub(super) fn start() -> Self {
        let page = page_size();
        let huge_page = huge_page_size();
        let mappings = mapping_huge_pages().unwrap_or_default();
        // SAFETY: the process is single-threaded and the guest is drained:
        // nothing runs guest code, grows a memory or drops a store.
        let memories = unsafe { wasmer_vm::linear_memories() };
        let memories: Vec<MemoryScan> = memories
            .into_iter()
            .filter(|memory| memory.private_anonymous && memory.len > 0)
            .map(|memory| {
                let base = memory.base as usize;
                let pages = memory.len.div_ceil(page);
                let end = base + pages * page;
                let mappings = mappings
                    .iter()
                    .filter(|&&(start, stop, _)| start < end && stop > base)
                    .map(|&(start, stop, huge)| {
                        (
                            (start.max(base) - base) / page,
                            (stop.min(end) - base).div_ceil(page),
                            huge,
                        )
                    })
                    .collect();
                let mut overlays: Vec<(usize, usize)> = memory
                    .overlays
                    .iter()
                    .map(|&(addr, len)| ((addr - base) / page, (addr - base + len).div_ceil(page)))
                    .filter(|&(start, end)| start < end.min(pages))
                    .collect();
                overlays.sort_unstable();
                let mut extents = Vec::new();
                let mut from = 0;
                for (start, end) in overlays {
                    if from < start {
                        extents.push((from, start));
                    }
                    from = from.max(end);
                }
                if from < pages {
                    extents.push((from, pages));
                }
                MemoryScan {
                    base,
                    pages,
                    mappings,
                    extents,
                    next: 0,
                    pending: None,
                }
            })
            .collect();
        let scanned = memories
            .iter()
            .flat_map(|memory| memory.extents.iter())
            .map(|(start, end)| end - start)
            .sum();
        let totals = ZeroPages {
            memories: memories.len(),
            scanned,
            overlay: memories.iter().map(|memory| memory.pages).sum::<usize>() - scanned,
            ..ZeroPages::default()
        };
        tracing::debug!(
            memories = totals.memories,
            pages = totals.scanned,
            overlay = totals.overlay,
            "releasing zero pages in slices"
        );
        Self {
            page,
            huge_page,
            memories,
            totals,
            started: Instant::now(),
            busy: Duration::ZERO,
            resident: vec![0; huge_page / page],
            drop: vec![false; huge_page / page],
        }
    }

    /// Scans for about `budget`, block by block; `true` once every memory
    /// has been scanned.
    pub(super) fn step(&mut self, budget: Duration) -> bool {
        let started = Instant::now();
        while let Some(memory) = self
            .memories
            .iter_mut()
            .find(|memory| memory.next < memory.pages)
        {
            scan_block(
                memory,
                self.page,
                self.huge_page,
                &mut self.totals,
                &mut self.resident,
                &mut self.drop,
            );
            if started.elapsed() >= budget {
                break;
            }
        }
        self.busy += started.elapsed();
        tracing::trace!(
            pages = self.memories.iter().map(|memory| memory.next).sum::<usize>(),
            of = self.totals.scanned,
            released = self.totals.released,
            slice = ?started.elapsed(),
            "zero-page scan slice"
        );
        let done = self
            .memories
            .iter()
            .all(|memory| memory.next >= memory.pages);
        if done {
            let totals = self.totals;
            tracing::debug!(
                memories = totals.memories,
                scanned = totals.scanned,
                overlay = totals.overlay,
                resident = totals.resident,
                zero = totals.zero,
                released = totals.released,
                kept_blocks = totals.kept_blocks,
                runs = totals.runs,
                released_mb = (totals.released * self.page) >> 20,
                scan = ?self.busy,
                after = ?self.started.elapsed(),
                "zero pages released"
            );
        }
        done
    }
}

/// Scans the 2 MiB-aligned block at `memory.next` (clipped to the anonymous
/// extent it is in): marks its zero pages, keeps a fully resident block
/// that is not zero throughout when the mapping may hold huge pages, and
/// releases runs of zero pages, merging with the run left pending by the
/// previous block. Between extents it skips to the next one. `resident`
/// and `drop` are scratch of at least a block's pages.
fn scan_block(
    memory: &mut MemoryScan,
    page: usize,
    huge_page: usize,
    totals: &mut ZeroPages,
    resident: &mut [u8],
    drop: &mut [bool],
) {
    let Some(&(start, extent_end)) = memory
        .extents
        .iter()
        .find(|&&(_, extent_end)| memory.next < extent_end)
    else {
        memory.next = memory.pages;
        release_pending(memory, page, totals);
        return;
    };
    if memory.next < start {
        // Past an overlay: a run never spans one.
        release_pending(memory, page, totals);
        memory.next = start;
    }
    let base = memory.base;
    let end = base + extent_end * page;
    let addr = base + memory.next * page;
    let block_end = ((addr / huge_page) + 1).saturating_mul(huge_page).min(end);
    let first = memory.next;
    let last = (block_end - base) / page;
    let count = last - first;
    let spare_full_blocks = memory
        .mappings
        .iter()
        .find(|&&(start, stop, _)| (start..stop).contains(&first))
        .is_none_or(|&(_, _, huge)| huge);

    let resident = &mut resident[..count];
    let drop = &mut drop[..count];
    // SAFETY: a page-aligned subrange of a mapping of at least `len` bytes,
    // and `resident` has one byte per page of it.
    let rc = unsafe {
        libc::mincore(
            addr as *mut libc::c_void,
            count * page,
            resident.as_mut_ptr(),
        )
    };
    if rc != 0 {
        tracing::warn!(
            error = %std::io::Error::last_os_error(),
            "mincore failed; the rest of this memory's zero pages are kept"
        );
        memory.next = memory.pages;
        release_pending(memory, page, totals);
        return;
    }
    let full = spare_full_blocks
        && block_end - addr == huge_page
        && resident.iter().all(|&byte| byte & 1 != 0);

    if full {
        // The block goes whole or not at all: one read decides.
        totals.resident += count;
        // SAFETY: a resident block of the accessible range; nothing writes
        // it (the guest is drained and this is the only thread).
        let zero = unsafe { is_zero(addr, count * page) };
        if zero {
            totals.zero += count;
        } else {
            totals.kept_blocks += 1;
        }
        drop.fill(zero);
    } else {
        for (offset, &byte) in resident.iter().enumerate() {
            let mut zero = false;
            if byte & 1 != 0 {
                totals.resident += 1;
                // SAFETY: a resident page of the accessible range; nothing
                // writes it (the guest is drained and this is the only
                // thread).
                zero = unsafe { is_zero(addr + offset * page, page) };
                totals.zero += usize::from(zero);
            }
            drop[offset] = zero;
        }
    }

    for (offset, &dropped) in drop.iter().enumerate() {
        let index = first + offset;
        if !dropped {
            release_pending(memory, page, totals);
            continue;
        }
        match &mut memory.pending {
            Some((_, pending_end)) if *pending_end == index => *pending_end += 1,
            _ => {
                release_pending(memory, page, totals);
                memory.pending = Some((index, index + 1));
            }
        }
    }
    memory.next = last;
    if memory.next >= memory.pages {
        release_pending(memory, page, totals);
    }
}

/// Releases the pending run of zero pages, if any.
fn release_pending(memory: &mut MemoryScan, page: usize, totals: &mut ZeroPages) {
    let Some((start, end)) = memory.pending.take() else {
        return;
    };
    let run = end - start;
    // SAFETY: a page-aligned subrange of the guest's private anonymous
    // mapping, within one anonymous extent; a page refaults as fresh zeros.
    let rc = unsafe {
        libc::madvise(
            (memory.base + start * page) as *mut libc::c_void,
            run * page,
            libc::MADV_DONTNEED,
        )
    };
    if rc != 0 {
        tracing::warn!(
            error = %std::io::Error::last_os_error(),
            pages = run,
            "madvise(MADV_DONTNEED) failed"
        );
        return;
    }
    totals.released += run;
    totals.runs += 1;
}

/// The host's page size.
fn page_size() -> usize {
    // SAFETY: a plain query with no memory arguments.
    let size = unsafe { libc::sysconf(libc::_SC_PAGESIZE) };
    usize::try_from(size).unwrap_or(4096)
}

/// The unit transparent huge pages come in: the kernel's PMD size, from
/// sysfs; 2 MiB (x86-64, arm64 with 4 KiB pages) when it cannot be read.
fn huge_page_size() -> usize {
    std::fs::read_to_string("/sys/kernel/mm/transparent_hugepage/hpage_pmd_size")
        .ok()
        .and_then(|text| text.trim().parse().ok())
        .unwrap_or(2 << 20)
}

/// Every mapping of this process as `(start, end, has_huge_pages)`, from
/// `AnonHugePages` in `/proc/self/smaps`. `None` when that cannot be read.
fn mapping_huge_pages() -> Option<Vec<(usize, usize, bool)>> {
    let smaps = std::fs::read_to_string("/proc/self/smaps").ok()?;
    let mut mappings = Vec::new();
    let mut current = None;
    for line in smaps.lines() {
        if let Some(rest) = line.strip_prefix("AnonHugePages:") {
            if let Some((start, end)) = current.take() {
                let kb: usize = rest.split_whitespace().next()?.parse().ok()?;
                mappings.push((start, end, kb > 0));
            }
            continue;
        }
        // A mapping header: `start-end perms offset dev inode [path]`.
        if let Some((range, _)) = line.split_once(' ')
            && let Some((start, end)) = range.split_once('-')
            && let (Ok(start), Ok(end)) = (
                usize::from_str_radix(start, 16),
                usize::from_str_radix(end, 16),
            )
        {
            current = Some((start, end));
        }
    }
    Some(mappings)
}

/// Whether the `len` bytes at `addr` are all zero.
///
/// # Safety
///
/// `addr` must point to `len` readable bytes, 8-aligned, that nothing
/// writes meanwhile.
unsafe fn is_zero(addr: usize, len: usize) -> bool {
    // SAFETY: the caller's contract; the slice is read only.
    let words = unsafe { std::slice::from_raw_parts(addr as *const u64, len / 8) };
    words.iter().all(|&word| word == 0)
}
