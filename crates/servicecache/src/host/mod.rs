//! `servicecache host`: one guest in one process, driven over a control
//! channel by the manager. See `protocol` for the messages.
//!
//! The control loop, `Host::serve` on the process's main thread, is
//! synchronous: it polls the channel and an event pipe with a short tick and
//! never enters the tokio runtime, so that a fork can happen from plain code
//! on this thread and the child continues the same loop. The tokio runtime
//! only serves timers and the few async tasks wasmer-wasix spawns.

pub mod guest;
pub mod net;
pub mod protocol;

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
use wasmer_wasix::{os::task::TaskJoinHandle, runtime::task_manager::tokio::TokioTaskManager};

use self::{
    guest::{GuestRun, GuestRuntime, exit_status},
    net::HostNetworking,
    protocol::{Channel, Frame, Reply, Request, Run},
};
use crate::{manifest::Manifest, runtime::ReadOnlyMount};

/// How often the control loop checks the guest and reaps children.
const TICK: Duration = Duration::from_millis(100);

/// Arguments of the `host` subcommand.
#[derive(Debug)]
pub struct HostArgs {
    pub manifest: PathBuf,
    pub control_fd: RawFd,
}

/// Runs a host process to completion.
///
/// # Errors
///
/// Returns an error when the manifest cannot be loaded or the control
/// channel fails; a guest failure is reported over the channel instead.
pub fn run(args: &HostArgs) -> Result<()> {
    die_with_parent()?;
    let manifest = Manifest::load(&args.manifest)?;
    // The descriptor was inherited from the manager and is ours to close.
    let channel = Channel::from_fd(unsafe { OwnedFd::from_raw_fd(args.control_fd) });
    let mut host = Host::new(manifest)?;
    host.serve(&channel)
}

/// Makes the kernel kill this process when the thread that spawned it dies.
fn die_with_parent() -> Result<()> {
    nix::sys::prctl::set_pdeathsig(nix::sys::signal::Signal::SIGKILL)
        .context("failed to set the parent-death signal")
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
}

/// The self-pipe the guest thread writes to when its listen completes.
struct EventPipe {
    read: OwnedFd,
    write: Arc<OwnedFd>,
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

    fn notifier(&self) -> Arc<dyn Fn() + Send + Sync> {
        let write = self.write.clone();
        Arc::new(move || {
            let _ = nix::unistd::write(&*write, &[1]);
        })
    }

    /// Drains the pipe; `true` if anything was written. The read end is
    /// non-blocking, so this returns as soon as the pipe is empty.
    fn drain(&self) -> bool {
        let mut buffer = [0_u8; 64];
        let mut any = false;
        while let Ok(n) = nix::unistd::read(self.read.as_raw_fd(), &mut buffer) {
            if n == 0 {
                break;
            }
            any = true;
        }
        any
    }
}

struct Host {
    manifest: Manifest,
    /// Kept for its lifetime only: the host never blocks on it.
    _tokio: tokio::runtime::Runtime,
    networking: Arc<HostNetworking>,
    guests: GuestRuntime,
    events: EventPipe,
    guest: Option<TaskJoinHandle>,
    phase: Phase,
}

impl Host {
    fn new(manifest: Manifest) -> Result<Self> {
        let tokio = tokio::runtime::Builder::new_multi_thread()
            .worker_threads(1)
            .thread_name("tokio")
            .enable_all()
            .build()
            .context("failed to create the tokio runtime")?;
        let tasks = Arc::new(TokioTaskManager::new(tokio.handle().clone()));

        let events = EventPipe::new()?;
        // Stock networking and stdio capture the current tokio runtime when
        // they are constructed; build them inside one.
        let guard = tokio.enter();
        let networking = Arc::new(HostNetworking::new(
            manifest.guest.listen_port,
            events.notifier(),
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
        let guests = GuestRuntime::new(tasks, &mounts, networking.clone())?;
        drop(guard);

        Ok(Self {
            manifest,
            _tokio: tokio,
            networking,
            guests,
            events,
            guest: None,
            phase: Phase::Fresh,
        })
    }

    fn serve(&mut self, channel: &Channel) -> Result<()> {
        loop {
            let readable = self.wait(channel, TICK)?;
            if self.tick(channel)? {
                return Ok(());
            }
            if !readable {
                continue;
            }
            let Some(frame) = channel.recv::<Request>()? else {
                // The manager is gone; so is the reason to exist.
                return Ok(());
            };
            if self.handle(channel, frame)? {
                return Ok(());
            }
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

    /// Reports what happened since the last tick: the guest listening or
    /// exiting, clones exiting. Returns `true` when the host should end.
    fn tick(&mut self, channel: &Channel) -> Result<bool> {
        if self.events.drain()
            && let Phase::Running { ready: false } = self.phase
        {
            self.phase = Phase::Running { ready: true };
            channel.send(&self.ready_reply()?, &[], &[])?;
        }
        if let Some(status) = self.guest.as_ref().and_then(exit_status) {
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
                Ok(WaitStatus::Exited(pid, status)) => channel.send(
                    &Reply::Exited {
                        run: Run::Child,
                        status,
                        pid: Some(pid.as_raw().unsigned_abs()),
                    },
                    &[],
                    &[],
                )?,
                Ok(WaitStatus::Signaled(pid, signal, _)) => channel.send(
                    &Reply::Exited {
                        run: Run::Child,
                        status: 128 + signal as i32,
                        pid: Some(pid.as_raw().unsigned_abs()),
                    },
                    &[],
                    &[],
                )?,
                _ => break,
            }
        }
        Ok(false)
    }

    fn ready_reply(&self) -> Result<Reply> {
        Ok(Reply::Ready {
            endpoint: self.networking.endpoint()?.to_string(),
        })
    }

    /// Handles one request. Returns `true` when the host should end.
    fn handle(&mut self, channel: &Channel, frame: Frame<Request>) -> Result<bool> {
        let reply = match frame.message {
            Request::Prepare => self.prepare(channel),
            Request::Start => self.start(channel, frame.fds),
            Request::Initialize => self.initialize(channel, &frame.payload),
            Request::Freeze | Request::Fork => Err(anyhow::anyhow!("not implemented")),
            Request::Stop => return Ok(true),
        };
        match reply {
            Ok(Some(reply)) => channel.send(&reply, &[], &[])?,
            Ok(None) => return Ok(true),
            Err(error) => channel.send(
                &Reply::Error {
                    text: format!("{error:#}"),
                },
                &[],
                &[],
            )?,
        }
        Ok(false)
    }

    fn prepare(&mut self, channel: &Channel) -> Result<Option<Reply>> {
        if self.phase != Phase::Fresh {
            bail!("prepare is only accepted before anything has run");
        }
        let status = match &self.manifest.prepare {
            Some(prepare) if prepare.module.is_some() => {
                let module = prepare.module.clone().expect("checked");
                let handle = self.guests.spawn(&GuestRun {
                    module: &module,
                    args: prepare.args.clone(),
                    stdin: &[],
                    network: false,
                })?;
                match self.wait_run(channel, &handle, Run::Prepare)? {
                    Some(status) => status,
                    None => return Ok(None),
                }
            }
            _ => 0,
        };
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
        self.guest = Some(handle);
        self.phase = Phase::Running { ready: false };

        // Ready, or dead before it listened.
        loop {
            let readable = self.wait(channel, TICK)?;
            if self.events.drain() {
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
        match self.wait_run(channel, &handle, Run::Initializer)? {
            Some(status) => Ok(Some(Reply::Exited {
                run: Run::Initializer,
                status,
                pid: None,
            })),
            None => Ok(None),
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
