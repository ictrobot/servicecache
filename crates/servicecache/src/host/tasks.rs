//! The host's task manager: every guest thread is one OS thread driving a
//! suspendable coroutine, and every timer belongs to the host.
//!
//! wasmer-wasix asks its `VirtualTaskManager` for guest threads, background
//! tasks and sleeps. This one:
//!
//! - runs each `task_wasm` (and `task_dedicated`) on a dedicated OS thread
//!   through `wasmer_vm::run_guest_thread`, so that the thread holds no guest
//!   state and can end at a freeze;
//! - implements `sleep_now` with a timer that re-arms itself on the current
//!   tokio runtime whenever the fork generation changed, so a timer created
//!   in the parent fires in the child;
//! - counts `task_shared` futures in flight, so that a freeze can refuse
//!   while host-side work exists that a forked child would lose.

use std::{
    future::Future,
    pin::Pin,
    sync::{
        Arc, OnceLock, RwLock,
        atomic::{AtomicU64, AtomicUsize, Ordering},
    },
    task::{Context, Poll},
    time::{Duration, Instant},
};

use tokio::runtime::Handle;
use wasmer_wasix::{
    WasiThreadError,
    runtime::task_manager::{TaskWasm, VirtualTaskManager, tokio::run_task_wasm},
};

/// Stack of the top-level coroutine that runs a guest thread's body: the
/// instance creation and the host frames around the Wasm call. Only touched
/// pages are resident.
const TASK_STACK_SIZE: usize = 8 << 20;

/// Stack of the OS thread driving a coroutine. It holds nothing but the
/// driving loop and the frames of a future poll.
pub(super) const DRIVER_STACK_SIZE: usize = 1 << 20;

/// The tokio runtime behind the task manager, replaceable in a forked child.
#[derive(Debug)]
struct Shared {
    handle: RwLock<Handle>,
    /// Incremented in every forked child; timers re-arm when it changes.
    generation: AtomicU64,
    tasks_in_flight: AtomicUsize,
}

/// See the module documentation.
#[derive(Debug, Clone)]
pub struct HostTaskManager {
    shared: Arc<Shared>,
}

static SLEEP_SOURCE: OnceLock<HostTaskManager> = OnceLock::new();

impl HostTaskManager {
    /// A task manager spawning its async work on `handle`.
    #[must_use]
    pub fn new(handle: Handle) -> Self {
        Self {
            shared: Arc::new(Shared {
                handle: RwLock::new(handle),
                generation: AtomicU64::new(0),
                tasks_in_flight: AtomicUsize::new(0),
            }),
        }
    }

    /// Makes this task manager the process's timer source for the waits
    /// wasmer-vm implements itself. Only the first call takes effect.
    pub fn install_as_sleep_source(&self) {
        let _ = SLEEP_SOURCE.set(self.clone());
    }

    /// The sleep hook for `wasmer_vm::suspend::enable`.
    ///
    /// # Panics
    ///
    /// Panics if no task manager was installed as the sleep source.
    pub fn sleep_hook(time: Duration) -> Pin<Box<dyn Future<Output = ()> + Send + Sync + 'static>> {
        SLEEP_SOURCE
            .get()
            .expect("a host task manager is installed as the sleep source")
            .sleep_now(time)
    }

    /// The current runtime handle.
    #[must_use]
    pub fn handle(&self) -> Handle {
        self.shared
            .handle
            .read()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .clone()
    }

    /// In a forked child: switches to a fresh runtime and starts a new fork
    /// generation, so that every timer re-arms on it.
    pub fn replace_runtime(&self, handle: Handle) {
        *self
            .shared
            .handle
            .write()
            .unwrap_or_else(std::sync::PoisonError::into_inner) = handle;
        self.shared.generation.fetch_add(1, Ordering::SeqCst);
    }

    /// The fork generation.
    #[must_use]
    pub fn generation(&self) -> u64 {
        self.shared.generation.load(Ordering::SeqCst)
    }

    /// `task_shared` futures spawned and not yet finished.
    #[must_use]
    pub fn shared_tasks_in_flight(&self) -> usize {
        self.shared.tasks_in_flight.load(Ordering::SeqCst)
    }

    fn spawn_guest_thread(
        name: &str,
        body: impl FnOnce() + Send + 'static,
    ) -> Result<(), WasiThreadError> {
        std::thread::Builder::new()
            .name(name.to_owned())
            .stack_size(DRIVER_STACK_SIZE)
            .spawn(move || wasmer_vm::run_guest_thread(TASK_STACK_SIZE, body))
            .map(|_| ())
            .map_err(|_| WasiThreadError::Unsupported)
    }
}

impl VirtualTaskManager for HostTaskManager {
    fn sleep_now(&self, time: Duration) -> Pin<Box<dyn Future<Output = ()> + Send + Sync>> {
        Box::pin(ForkAwareSleep {
            tasks: self.clone(),
            deadline: Instant::now() + time,
            generation: self.generation(),
            timer: None,
        })
    }

    fn task_shared(
        &self,
        task: Box<
            dyn FnOnce() -> Pin<Box<dyn Future<Output = ()> + Send + 'static>> + Send + 'static,
        >,
    ) -> Result<(), WasiThreadError> {
        let shared = self.shared.clone();
        shared.tasks_in_flight.fetch_add(1, Ordering::SeqCst);
        self.handle().spawn(async move {
            task().await;
            shared.tasks_in_flight.fetch_sub(1, Ordering::SeqCst);
        });
        Ok(())
    }

    fn task_wasm(&self, task: TaskWasm) -> Result<(), WasiThreadError> {
        let (ready_tx, ready_rx) = std::sync::mpsc::channel();
        Self::spawn_guest_thread("guest", move || {
            run_task_wasm(task, move |ready| {
                ready_tx.send(ready).ok();
            });
        })?;
        ready_rx
            .recv()
            .map_err(|_| WasiThreadError::InvalidWasmContext)?
    }

    fn task_dedicated(
        &self,
        task: Box<dyn FnOnce() + Send + 'static>,
    ) -> Result<(), WasiThreadError> {
        Self::spawn_guest_thread("guest-task", task)
    }

    fn thread_parallelism(&self) -> Result<usize, WasiThreadError> {
        Ok(std::thread::available_parallelism().map_or(1, usize::from))
    }
}

/// A sleep registered with the runtime current at each poll. When the fork
/// generation changes, the old timer (which belongs to the parent's
/// abandoned runtime) is forgotten and a new one is armed for the remaining
/// time. Polling the timer directly avoids making a Tokio task and scheduling
/// it twice for every guest timeout.
struct ForkAwareSleep {
    tasks: HostTaskManager,
    deadline: Instant,
    generation: u64,
    timer: Option<Pin<Box<tokio::time::Sleep>>>,
}

impl Future for ForkAwareSleep {
    type Output = ();

    fn poll(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<()> {
        let generation = self.tasks.generation();
        if self.timer.is_none() || self.generation != generation {
            if let Some(old) = self.timer.take() {
                // Never touch the parent's runtime from the child.
                std::mem::forget(old);
            }
            self.generation = generation;
            let deadline = tokio::time::Instant::from_std(self.deadline);
            // `Sleep::new_timeout` finds its timer driver through the current
            // runtime context. Polling after construction does not need the
            // guest thread to remain entered on the runtime.
            let timer = {
                let handle = self.tasks.handle();
                let _entered = handle.enter();
                Box::pin(tokio::time::sleep_until(deadline))
            };
            self.timer = Some(timer);
        }
        let timer = self.timer.as_mut().expect("armed above");
        timer.as_mut().poll(cx)
    }
}

#[cfg(test)]
mod tests {
    use std::{
        sync::Arc,
        task::{Wake, Waker},
    };

    use super::*;

    struct Unpark(std::thread::Thread);

    impl Wake for Unpark {
        fn wake(self: Arc<Self>) {
            self.0.unpark();
        }
    }

    /// A guest thread polls its sleep from outside the Tokio runtime, so the
    /// timer must be constructable there (it finds its driver through the
    /// runtime the sleep enters briefly) and must wake that thread's waker
    /// when it fires, rather than a task of the runtime's own. Polls from a
    /// plain thread with a waker that unparks it; a lost wake fails through
    /// the deadline rather than hanging.
    #[test]
    fn a_timer_is_polled_outside_the_tokio_runtime() {
        let runtime = tokio::runtime::Builder::new_multi_thread()
            .worker_threads(1)
            .enable_time()
            .build()
            .expect("runtime");
        let tasks = HostTaskManager::new(runtime.handle().clone());
        let mut sleep = tasks.sleep_now(Duration::from_millis(5));
        let waker = Waker::from(Arc::new(Unpark(std::thread::current())));
        let mut context = Context::from_waker(&waker);
        let deadline = Instant::now() + Duration::from_secs(1);

        loop {
            if sleep.as_mut().poll(&mut context).is_ready() {
                break;
            }
            assert!(
                Instant::now() < deadline,
                "timer did not wake its guest thread"
            );
            std::thread::park_timeout(Duration::from_millis(20));
        }
    }
}
