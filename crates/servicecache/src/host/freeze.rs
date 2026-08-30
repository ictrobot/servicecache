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
//! waiting on a guest that never runs again, and a clone inherits no live
//! connection.
//!
//! `fork` runs on that one thread. The child rebuilds what the parent
//! dismantled — a new tokio runtime (a new fork generation, so every timer
//! re-arms), a new epoll instance for the selector, its own listening socket
//! in place of the inherited one — and gives every registered coroutine a
//! fresh OS thread that re-creates its wait and resumes it. The parent
//! closes its copies of the child's descriptors and stays frozen.

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

    wasmer_vm::suspend::close_gate();
    let quiescence = wasmer_vm::suspend::drain(DRAIN_TIMEOUT)
        .map_err(|err| anyhow::anyhow!("{err}"))
        .context("draining the guest")?;

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
        std::thread::sleep(Duration::from_millis(1));
    }
    host.networking.shut_down_sockets()?;
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
    // SAFETY: the process is single-threaded (verified by `freeze`), so the
    // child inherits no lock held or state half-changed by another thread.
    let pid = unsafe { libc::fork() };
    if pid < 0 {
        return Err(std::io::Error::last_os_error()).context("fork failed");
    }
    if pid == 0 {
        let rebuilt = rebuild(host, listener);
        return Ok(Forked::Child {
            control: child_control,
            rebuilt,
        });
    }
    drop(child_control);
    drop(listener);
    Ok(Forked::Parent {
        pid: pid.unsigned_abs(),
        endpoint,
    })
}

/// In the child: rebuild the host machinery the parent dismantled and
/// resume every coroutine.
fn rebuild(host: &mut Host, listener: TcpListener) -> Result<()> {
    // The parent-death signal does not survive a fork; the template is
    // this clone's parent.
    die_with_parent()?;

    TOKIO_EXIT.store(false, Ordering::SeqCst);
    let runtime = build_tokio()?;
    host.tasks.replace_runtime(runtime.handle().clone());
    // The parent's runtime: its threads do not exist here and its state is
    // never touched again (`ManuallyDrop`).
    host.tokio = std::mem::ManuallyDrop::new(runtime);

    host.networking
        .selector()
        .rebuild_after_fork()
        .context("failed to rebuild the selector")?;
    host.networking.replace_listener(listener)?;

    wasmer_vm::resurrect_all(&mut |body| {
        std::thread::Builder::new()
            .name("guest".to_owned())
            .stack_size(super::tasks::DRIVER_STACK_SIZE)
            .spawn(body)
            .map(|_| ())
    })
    .map_err(|err| anyhow::anyhow!("{err}"))
    .context("resurrecting the guest threads")?;
    Ok(())
}
