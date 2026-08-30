//! `servicecache host`: one guest in one process, driven over a control
//! channel by the manager. See `protocol` for the messages.
//!
//! The control loop, `Host::serve` on the process's main thread, is
//! synchronous: it polls the channel and an event pipe with a short tick and
//! never enters the tokio runtime, so that a fork can happen from plain code
//! on this thread and the child continues the same loop. The tokio runtime
//! only serves timers and the few async tasks wasmer-wasix spawns.

mod freeze;
pub mod guest;
pub mod net;
pub mod protocol;
pub mod tasks;

use std::{
    net::TcpListener,
    os::fd::{AsFd, AsRawFd, FromRawFd, OwnedFd, RawFd},
    path::PathBuf,
    sync::Arc,
    time::Duration,
};

use anyhow::{Context as _, Result, bail};
use nix::{
    poll::{PollFd, PollFlags, PollTimeout, poll},
    sys::wait::{WaitPidFlag, WaitStatus, waitpid},
    unistd::Pid,
};
use wasmer_wasix::os::task::TaskJoinHandle;

use self::{
    guest::{GuestRun, GuestRuntime, exit_status},
    net::HostNetworking,
    protocol::{Channel, Frame, Reply, Request, Run},
    tasks::HostTaskManager,
};
use crate::{cache::ModuleCache, manifest::Manifest, runtime::ReadOnlyMount};

/// Coroutine stack for Wasm calls. Host imports run on it too, so it is
/// sized for the deepest syscall path rather than for Wasm alone.
const WASM_STACK_SIZE: usize = 16 << 20;

/// How often the control loop checks the guest and reaps children.
const TICK: Duration = Duration::from_millis(100);

/// How long one slice of a frozen guest's zero-page scan runs: the most a
/// fork request waits for it. Forks come first; the scan may take seconds.
const COMPACTION_SLICE: Duration = Duration::from_millis(1);

/// How long the control channel must be quiet before the next slice: a
/// burst of requests, such as forks right after the freeze, comes first.
const COMPACTION_PAUSE: Duration = Duration::from_millis(50);

/// Arguments of the `host` subcommand.
#[derive(Debug)]
pub struct HostArgs {
    pub manifest: PathBuf,
    pub control_fd: RawFd,
    /// Where compiled modules are cached.
    pub cache_dir: PathBuf,
}

/// Runs a host process to completion.
///
/// # Errors
///
/// Returns an error when the manifest cannot be loaded or the control
/// channel fails; a guest failure is reported over the channel instead.
pub fn run(args: &HostArgs) -> Result<()> {
    die_with_parent()?;
    enable_suspension();
    let manifest = Manifest::load(&args.manifest)?;
    tracing::info!(
        pid = std::process::id(),
        service = %manifest.service.name,
        manifest = %args.manifest.display(),
        cache = %args.cache_dir.display(),
        "host started"
    );
    // The descriptor was inherited from the manager and is ours to close.
    let channel = Channel::from_fd(unsafe { OwnedFd::from_raw_fd(args.control_fd) });
    let host = Host::new(manifest, ModuleCache::new(args.cache_dir.clone()))?;
    host.serve(channel)
}

/// Makes the kernel kill this process when the thread that spawned it dies.
fn die_with_parent() -> Result<()> {
    nix::sys::prctl::set_pdeathsig(nix::sys::signal::Signal::SIGKILL)
        .context("failed to set the parent-death signal")
}

/// Switches the embedded runtime to suspendable coroutines: blocking waits
/// suspend the guest's coroutine, host imports run on the coroutine stack,
/// and timers come from the host task manager. Process-wide and
/// irreversible; the `host` subcommand is the only one that calls it.
fn enable_suspension() {
    wasmer_vm::set_stack_size(WASM_STACK_SIZE);
    virtual_mio::set_suspend_hook(wasmer_vm::try_suspend_on_block);
    wasmer::install_suspend_thread_state_hooks();
    wasmer_vm::suspend::enable(HostTaskManager::sleep_hook);
}

/// Where the host is in a guest's life.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Phase {
    /// Nothing has run.
    Fresh,
    /// The prepare step has completed.
    Prepared,
    /// The guest is running (and, once `ready`, listening).
    Running { ready: bool },
    /// The guest is frozen; only `fork` and `stop` are accepted.
    Frozen,
}

/// The self-pipe that wakes the control loop from other threads: the guest
/// thread writes to it when its listen completes, and a task on the host
/// runtime when a run ends. Each byte says which.
struct EventPipe {
    read: OwnedFd,
    write: Arc<OwnedFd>,
}

/// What a byte in the event pipe announces.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u8)]
enum Event {
    /// The guest's listen completed.
    Listening = 1,
    /// A run ended.
    RunEnded = 2,
}

impl TryFrom<u8> for Event {
    type Error = anyhow::Error;

    fn try_from(byte: u8) -> Result<Self> {
        match byte {
            1 => Ok(Self::Listening),
            2 => Ok(Self::RunEnded),
            other => bail!("unexpected byte {other} in the event pipe"),
        }
    }
}

/// What was written to the event pipe since it was last drained.
#[derive(Debug, Clone, Copy, Default)]
struct Events {
    /// The guest's listen completed.
    listening: bool,
    /// A run ended. The loop re-reads the run's status, so a stale byte
    /// costs nothing.
    run_ended: bool,
}

impl EventPipe {
    fn new() -> Result<Self> {
        let (read, write) =
            nix::unistd::pipe2(nix::fcntl::OFlag::O_CLOEXEC | nix::fcntl::OFlag::O_NONBLOCK)
                .context("failed to create the event pipe")?;
        Ok(Self {
            read,
            write: Arc::new(write),
        })
    }

    /// A function that announces `event` from any thread.
    fn notifier(&self, event: Event) -> Arc<dyn Fn() + Send + Sync> {
        let write = self.write.clone();
        Arc::new(move || {
            let _ = nix::unistd::write(&*write, &[event as u8]);
        })
    }

    /// Drains the pipe. The read end is non-blocking, so this returns as
    /// soon as the pipe is empty. Only this process writes the pipe, so a
    /// byte that is not an event is an error.
    fn drain(&self) -> Result<Events> {
        let mut buffer = [0_u8; 64];
        let mut events = Events::default();
        while let Ok(n) = nix::unistd::read(self.read.as_raw_fd(), &mut buffer) {
            if n == 0 {
                break;
            }
            for &byte in &buffer[..n] {
                match Event::try_from(byte)? {
                    Event::Listening => events.listening = true,
                    Event::RunEnded => events.run_ended = true,
                }
            }
        }
        Ok(events)
    }
}

/// What handling a request decided about the loop.
enum Outcome {
    /// Keep serving on the same channel.
    Continue,
    /// End the process.
    Exit,
    /// This process is now a forked child: serve on its own channel.
    Child(Channel),
}

struct Host {
    manifest: Manifest,
    /// The runtime behind the task manager. Never blocked on by the host,
    /// never dropped: a freeze ends its threads, after which tokio's drop
    /// would wait forever for them, and a forked child replaces it.
    tokio: std::mem::ManuallyDrop<tokio::runtime::Runtime>,
    tasks: HostTaskManager,
    networking: Arc<HostNetworking>,
    guests: GuestRuntime,
    events: EventPipe,
    guest: Option<TaskJoinHandle>,
    phase: Phase,
    /// The zero-page scan of a frozen guest, until it is done.
    compaction: Option<freeze::Compaction>,
}

impl Host {
    fn new(manifest: Manifest, cache: ModuleCache) -> Result<Self> {
        let tokio = freeze::build_tokio()?;
        let tasks = HostTaskManager::new(tokio.handle().clone());
        tasks.install_as_sleep_source();

        let events = EventPipe::new()?;
        let networking = Arc::new(HostNetworking::new(
            manifest.guest.listen_port,
            events.notifier(Event::Listening),
        ));
        let mounts: Vec<ReadOnlyMount> = manifest
            .prepare
            .as_ref()
            .map(|prepare| {
                prepare
                    .fs
                    .iter()
                    .map(|(guest, host)| ReadOnlyMount {
                        guest: guest.clone(),
                        host: host.clone(),
                    })
                    .collect()
            })
            .unwrap_or_default();
        let guests = GuestRuntime::new(tasks.clone(), &mounts, networking.clone(), cache)?;

        Ok(Self {
            manifest,
            tokio: std::mem::ManuallyDrop::new(tokio),
            tasks,
            networking,
            guests,
            events,
            guest: None,
            phase: Phase::Fresh,
            compaction: None,
        })
    }

    fn serve(mut self, mut channel: Channel) -> Result<()> {
        loop {
            // While a scan is under way, a slice runs whenever the channel
            // has been quiet for a moment.
            let timeout = if self.compaction.is_some() {
                COMPACTION_PAUSE
            } else {
                TICK
            };
            let readable = self.wait(&channel, timeout)?;
            if self.tick(&channel)? {
                return Ok(());
            }
            if !readable {
                self.compact();
                continue;
            }
            let Some(frame) = channel.recv::<Request>()? else {
                // The manager is gone; so is the reason to exist.
                return Ok(());
            };
            match self.handle(&channel, frame)? {
                Outcome::Continue => {}
                Outcome::Exit => return Ok(()),
                Outcome::Child(own) => {
                    // The guest runs again here: no scan of its memory.
                    self.compaction = None;
                    // The inherited copy of the template's channel closes
                    // here; the template keeps its own.
                    channel = own;
                    channel.send(&self.forked_reply(std::process::id())?, &[], &[])?;
                }
            }
        }
    }

    /// One slice of the frozen guest's zero-page scan, if one is under way.
    fn compact(&mut self) {
        if let Some(compaction) = &mut self.compaction
            && compaction.step(COMPACTION_SLICE)
        {
            self.compaction = None;
        }
    }

    /// Waits for a request or an event, at most `timeout`; `true` if a
    /// request can be read.
    fn wait(&self, channel: &Channel, timeout: Duration) -> Result<bool> {
        let mut fds = [
            PollFd::new(channel.as_fd(), PollFlags::POLLIN),
            PollFd::new(self.events.read.as_fd(), PollFlags::POLLIN),
        ];
        let timeout = PollTimeout::try_from(timeout).context("poll timeout")?;
        match poll(&mut fds, timeout) {
            Ok(_) | Err(nix::errno::Errno::EINTR) => {}
            Err(err) => return Err(err).context("poll in the control loop"),
        }
        Ok(fds[0]
            .revents()
            .is_some_and(|revents| revents.intersects(PollFlags::POLLIN | PollFlags::POLLHUP)))
    }

    /// Wakes the control loop as soon as the run behind `handle` ends: a
    /// task on the host runtime awaits it and writes the event pipe, so the
    /// loop does not wait for its tick to notice. In a forked child the
    /// task belongs to the template's abandoned runtime; the child watches
    /// again on its own.
    fn watch_run(&self, handle: &TaskJoinHandle) {
        let mut handle = handle.clone();
        let notify = self.events.notifier(Event::RunEnded);
        self.tasks.handle().spawn(async move {
            let _ = handle.wait_finished().await;
            notify();
        });
    }

    /// Reports what happened since the last tick: the guest listening or
    /// exiting, clones exiting. Returns `true` when the host should end.
    fn tick(&mut self, channel: &Channel) -> Result<bool> {
        if self.events.drain()?.listening
            && let Phase::Running { ready: false } = self.phase
        {
            self.phase = Phase::Running { ready: true };
            channel.send(&self.ready_reply()?, &[], &[])?;
        }
        if self.phase != Phase::Frozen
            && let Some(status) = self.guest.as_ref().and_then(exit_status)
        {
            tracing::info!(status, "guest exited");
            channel.send(
                &Reply::Exited {
                    run: Run::Guest,
                    status,
                    pid: None,
                },
                &[],
                &[],
            )?;
            return Ok(true);
        }
        loop {
            match waitpid(Pid::from_raw(-1), Some(WaitPidFlag::WNOHANG)) {
                Ok(WaitStatus::Exited(pid, status)) => {
                    tracing::info!(clone = pid.as_raw(), status, "clone exited");
                    channel.send(
                        &Reply::Exited {
                            run: Run::Child,
                            status,
                            pid: Some(pid.as_raw().unsigned_abs()),
                        },
                        &[],
                        &[],
                    )?;
                }
                Ok(WaitStatus::Signaled(pid, signal, _)) => {
                    tracing::info!(clone = pid.as_raw(), ?signal, "clone killed");
                    channel.send(
                        &Reply::Exited {
                            run: Run::Child,
                            status: 128 + signal as i32,
                            pid: Some(pid.as_raw().unsigned_abs()),
                        },
                        &[],
                        &[],
                    )?;
                }
                _ => break,
            }
        }
        Ok(false)
    }

    fn ready_reply(&self) -> Result<Reply> {
        let endpoint = self.networking.endpoint()?;
        tracing::info!(%endpoint, "guest listening");
        Ok(Reply::Ready {
            endpoint: endpoint.to_string(),
        })
    }

    fn forked_reply(&self, pid: u32) -> Result<Reply> {
        Ok(Reply::Forked {
            pid,
            endpoint: self.networking.endpoint()?.to_string(),
        })
    }

    /// Handles one request.
    fn handle(&mut self, channel: &Channel, frame: Frame<Request>) -> Result<Outcome> {
        tracing::debug!(request = ?frame.message, fds = frame.fds.len(), phase = ?self.phase, "request");
        let reply = match frame.message {
            Request::Prepare => self.prepare(channel),
            Request::Start => self.start(channel, frame.fds),
            Request::Initialize => self.initialize(channel, &frame.payload),
            Request::Freeze => return self.freeze(channel),
            Request::Fork => return self.fork(channel, frame.fds),
            Request::Stop => return Ok(Outcome::Exit),
        };
        match reply {
            Ok(Some(reply)) => channel.send(&reply, &[], &[])?,
            Ok(None) => return Ok(Outcome::Exit),
            Err(error) => {
                tracing::warn!(error = format!("{error:#}"), "request failed");
                channel.send(
                    &Reply::Error {
                        text: format!("{error:#}"),
                    },
                    &[],
                    &[],
                )?;
            }
        }
        Ok(Outcome::Continue)
    }

    /// Answers a request with `error` and keeps serving.
    fn refuse(channel: &Channel, text: String) -> Result<Outcome> {
        tracing::warn!(%text, "request refused");
        channel.send(&Reply::Error { text }, &[], &[])?;
        Ok(Outcome::Continue)
    }

    fn prepare(&mut self, channel: &Channel) -> Result<Option<Reply>> {
        if self.phase != Phase::Fresh {
            bail!("prepare is only accepted before anything has run");
        }
        let status = match &self.manifest.prepare {
            Some(prepare) if prepare.module.is_some() => {
                let module = prepare.module.clone().expect("checked");
                let stdin = prepare.read_stdin()?;
                let handle = self.guests.spawn(&GuestRun {
                    module: &module,
                    args: prepare.args.clone(),
                    stdin: &stdin,
                    network: false,
                })?;
                self.watch_run(&handle);
                match self.wait_run(channel, &handle, Run::Prepare)? {
                    Some(status) => status,
                    None => return Ok(None),
                }
            }
            _ => 0,
        };
        tracing::info!(status, "prepare finished");
        self.phase = Phase::Prepared;
        Ok(Some(Reply::Exited {
            run: Run::Prepare,
            status,
            pid: None,
        }))
    }

    fn start(&mut self, channel: &Channel, mut fds: Vec<OwnedFd>) -> Result<Option<Reply>> {
        if !matches!(self.phase, Phase::Fresh | Phase::Prepared) {
            bail!("start is only accepted once, before the guest runs");
        }
        if fds.len() != 1 {
            bail!("start needs exactly one descriptor, the listening socket");
        }
        let listener = TcpListener::from(fds.remove(0));
        self.networking.set_listener(listener)?;

        let guest = self.manifest.guest.clone();
        let handle = self.guests.spawn(&GuestRun {
            module: &guest.module,
            args: guest.args,
            stdin: &[],
            network: true,
        })?;
        self.watch_run(&handle);
        self.guest = Some(handle);
        self.phase = Phase::Running { ready: false };
        tracing::info!(module = %guest.module.display(), "guest started");

        // Ready, or dead before it listened.
        loop {
            let readable = self.wait(channel, TICK)?;
            if self.events.drain()?.listening {
                self.phase = Phase::Running { ready: true };
                return Ok(Some(self.ready_reply()?));
            }
            if let Some(status) = self.guest.as_ref().and_then(exit_status) {
                return Ok(Some(Reply::Exited {
                    run: Run::Guest,
                    status,
                    pid: None,
                }));
            }
            if readable && !Self::refuse_while_busy(channel, "the guest is starting")? {
                return Ok(None);
            }
        }
    }

    fn initialize(&mut self, channel: &Channel, recipe: &[u8]) -> Result<Option<Reply>> {
        if self.phase != (Phase::Running { ready: true }) {
            bail!("initialize is only accepted while the guest is listening");
        }
        let Some(initializer) = self.manifest.initializer.clone() else {
            bail!("the manifest has no initializer");
        };
        let endpoint = self.networking.endpoint()?;
        let args = initializer
            .args
            .iter()
            .map(|arg| {
                arg.replace("{host}", &endpoint.ip().to_string())
                    .replace("{port}", &endpoint.port().to_string())
            })
            .collect();
        let handle = self.guests.spawn(&GuestRun {
            module: &initializer.module,
            args,
            stdin: recipe,
            network: true,
        })?;
        self.watch_run(&handle);
        match self.wait_run(channel, &handle, Run::Initializer)? {
            Some(status) => {
                tracing::info!(status, "initializer finished");
                Ok(Some(Reply::Exited {
                    run: Run::Initializer,
                    status,
                    pid: None,
                }))
            }
            None => Ok(None),
        }
    }

    fn freeze(&mut self, channel: &Channel) -> Result<Outcome> {
        if self.phase != (Phase::Running { ready: true }) {
            return Self::refuse(
                channel,
                "freeze is only accepted while the guest is listening".to_owned(),
            );
        }
        // Terminal from here, whatever happens.
        self.phase = Phase::Frozen;
        match freeze::freeze(self) {
            Ok(coroutines) => {
                // The guest never runs again in this process: its memory is
                // quiescent, which the scan requires.
                self.compaction = Some(freeze::Compaction::start());
                channel.send(&Reply::Frozen { coroutines }, &[], &[])?;
                Ok(Outcome::Continue)
            }
            Err(error) => {
                // A failed freeze is not recoverable.
                channel.send(
                    &Reply::Error {
                        text: format!("{error:#}"),
                    },
                    &[],
                    &[],
                )?;
                Ok(Outcome::Exit)
            }
        }
    }

    fn fork(&mut self, channel: &Channel, mut fds: Vec<OwnedFd>) -> Result<Outcome> {
        if self.phase != Phase::Frozen {
            return Self::refuse(channel, "fork is only accepted on a frozen host".to_owned());
        }
        if fds.len() != 2 {
            return Self::refuse(
                channel,
                "fork needs two descriptors: the child's control end and its listening socket"
                    .to_owned(),
            );
        }
        let listener = fds.pop().expect("two descriptors");
        let control = fds.pop().expect("two descriptors");
        match freeze::fork(self, control, listener) {
            Ok(freeze::Forked::Parent { pid, endpoint }) => {
                tracing::info!(clone = pid, %endpoint, "forked a clone");
                channel.send(
                    &Reply::Forked {
                        pid,
                        endpoint: endpoint.to_string(),
                    },
                    &[],
                    &[],
                )?;
                Ok(Outcome::Continue)
            }
            Ok(freeze::Forked::Child {
                control,
                rebuilt: Ok(()),
            }) => {
                self.phase = Phase::Running { ready: true };
                if let Some(guest) = &self.guest {
                    self.watch_run(guest);
                }
                Ok(Outcome::Child(Channel::from_fd(control)))
            }
            Ok(freeze::Forked::Child {
                control,
                rebuilt: Err(error),
            }) => {
                tracing::error!(error = format!("{error:#}"), "the clone failed to rebuild");
                // A child with nothing to serve: say so on its own channel
                // and end.
                Channel::from_fd(control)
                    .send(
                        &Reply::Error {
                            text: format!("{error:#}"),
                        },
                        &[],
                        &[],
                    )
                    .ok();
                Ok(Outcome::Exit)
            }
            Err(error) => Self::refuse(channel, format!("{error:#}")),
        }
    }

    /// Waits for a run to end, answering requests with `error` meanwhile
    /// except `stop`. Returns `None` when the host should end.
    fn wait_run(
        &mut self,
        channel: &Channel,
        handle: &TaskJoinHandle,
        run: Run,
    ) -> Result<Option<i32>> {
        loop {
            if let Some(status) = exit_status(handle) {
                return Ok(Some(status));
            }
            let readable = self.wait(channel, TICK)?;
            if self.tick(channel)? {
                return Ok(None);
            }
            if readable && !Self::refuse_while_busy(channel, &format!("{run:?} is running"))? {
                return Ok(None);
            }
        }
    }

    /// Answers a request that arrives during a run. Returns `false` if it
    /// was `stop` or the manager is gone.
    fn refuse_while_busy(channel: &Channel, why: &str) -> Result<bool> {
        let Some(frame) = channel.recv::<Request>()? else {
            return Ok(false);
        };
        if frame.message == Request::Stop {
            return Ok(false);
        }
        channel.send(
            &Reply::Error {
                text: format!("busy: {why}"),
            },
            &[],
            &[],
        )?;
        Ok(true)
    }
}
