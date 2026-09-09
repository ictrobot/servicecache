//! The manager's side of a host process: spawn it, drive the control
//! channel, reap it. Used by the tests; the manager proper builds on it.

use std::{
    net::{SocketAddr, TcpListener},
    os::{
        fd::{AsFd, AsRawFd, BorrowedFd, IntoRawFd},
        unix::process::CommandExt,
    },
    path::Path,
    process::{Child, Command, Stdio},
    time::Instant,
};

use anyhow::{Context as _, Result, bail};

use crate::host::{
    protocol::{Channel, Frame, Reply, Request, Run},
    title,
};

/// The descriptor number the host finds its control channel on.
const HOST_CONTROL_FD: i32 = 3;

/// A host process and its control channel.
#[derive(Debug)]
pub struct HostProcess {
    pid: u32,
    channel: Channel,
    /// Present for a host this manager spawned; a forked clone is a child
    /// of its template, not of the manager.
    child: Option<Child>,
    /// Unsolicited events received while waiting for a reply.
    events: Vec<Reply>,
    /// Where the guest serves, once it does.
    endpoint: Option<SocketAddr>,
}

impl HostProcess {
    /// Spawns `servicecache host` for `manifest` by re-executing this
    /// binary, with compiled modules cached under `cache_dir`. The host
    /// dies with the calling thread.
    ///
    /// # Errors
    ///
    /// Fails if the channel or the process cannot be created.
    pub fn spawn(manifest: &Path, cache_dir: &Path) -> Result<Self> {
        let binary = std::env::current_exe().context("failed to locate this binary")?;
        Self::spawn_with_binary(&binary, manifest, cache_dir)
    }

    /// Spawns `<binary> host` for `manifest`; for callers that are not the
    /// `servicecache` binary themselves, such as tests.
    ///
    /// # Errors
    ///
    /// Fails if the channel or the process cannot be created.
    pub fn spawn_with_binary(binary: &Path, manifest: &Path, cache_dir: &Path) -> Result<Self> {
        let (ours, theirs) = Channel::pair()?;
        let theirs_fd = theirs.as_raw_fd();
        let parent = std::process::id();

        let mut command = Command::new(binary);
        command
            .arg("host")
            .arg("--manifest")
            .arg(manifest)
            .arg("--control-fd")
            .arg(HOST_CONTROL_FD.to_string())
            .arg("--cache-dir")
            .arg(cache_dir)
            // Room for the host to write its title over these arguments.
            .arg(title::BUFFER_ARG)
            .stdin(Stdio::null());
        if let Some(directives) = crate::logging::directives() {
            command.arg("--log").arg(directives);
        }
        // Runs in the child between fork and exec: only async-signal-safe
        // calls, no allocation.
        unsafe {
            command.pre_exec(move || {
                if libc::dup2(theirs_fd, HOST_CONTROL_FD) < 0 {
                    return Err(std::io::Error::last_os_error());
                }
                if libc::prctl(libc::PR_SET_PDEATHSIG, libc::SIGKILL) < 0 {
                    return Err(std::io::Error::last_os_error());
                }
                if libc::getppid() != parent as libc::pid_t {
                    // The manager died between fork and prctl.
                    libc::_exit(1);
                }
                Ok(())
            });
        }
        let child = command.spawn().context("failed to spawn the host")?;
        drop(theirs);
        tracing::debug!(pid = child.id(), manifest = %manifest.display(), "spawned a host");
        Ok(Self {
            pid: child.id(),
            channel: ours,
            child: Some(child),
            events: Vec::new(),
            endpoint: None,
        })
    }

    /// The host's process id.
    #[must_use]
    pub fn pid(&self) -> u32 {
        self.pid
    }

    /// Runs the manifest's prepare step; its exit status.
    ///
    /// # Errors
    ///
    /// Fails on a refused request or a dead host.
    pub fn prepare(&mut self) -> Result<i32> {
        match self.request(Request::Prepare, &[], &[])? {
            Reply::Exited {
                run: Run::Prepare,
                status,
                ..
            } => Ok(status),
            other => bail!("unexpected reply to prepare: {other:?}"),
        }
    }

    /// Starts the guest on a fresh loopback socket; the endpoint it serves.
    ///
    /// # Errors
    ///
    /// Fails if the guest exits before it is ready or the request is refused.
    pub fn start(&mut self) -> Result<SocketAddr> {
        let listener = TcpListener::bind("127.0.0.1:0").context("failed to bind a listener")?;
        let reply = self.request(Request::Start, &[], &[listener.as_raw_fd()])?;
        drop(listener);
        match reply {
            Reply::Ready { endpoint } => {
                let endpoint = endpoint
                    .parse()
                    .with_context(|| format!("bad endpoint from the host: {endpoint}"))?;
                self.endpoint = Some(endpoint);
                Ok(endpoint)
            }
            other => bail!("unexpected reply to start: {other:?}"),
        }
    }

    /// Where the guest serves.
    ///
    /// # Errors
    ///
    /// Fails before `start` (or, for a clone, before it announced itself).
    pub fn endpoint(&self) -> Result<SocketAddr> {
        self.endpoint
            .with_context(|| format!("host {} has no endpoint yet", self.pid))
    }

    /// Freezes the guest: terminal, the host can then only be forked or
    /// stopped. The number of guest threads frozen.
    ///
    /// # Errors
    ///
    /// Fails if the guest cannot reach quiescence; the host is then gone.
    pub fn freeze(&mut self) -> Result<usize> {
        match self.request(Request::Freeze, &[], &[])? {
            Reply::Frozen { coroutines } => Ok(coroutines),
            other => bail!("unexpected reply to freeze: {other:?}"),
        }
    }

    /// Forks the frozen guest into a clone serving on a fresh loopback
    /// socket, with its own control channel.
    ///
    /// # Errors
    ///
    /// Fails if the host is not frozen or the clone does not come up.
    pub fn fork(&mut self) -> Result<(Self, SocketAddr)> {
        let started = Instant::now();
        let (ours, theirs) = Channel::pair()?;
        let listener = TcpListener::bind("127.0.0.1:0").context("failed to bind a listener")?;
        let sockets_made = started.elapsed();
        let reply = self.request(
            Request::Fork,
            &[],
            &[theirs.as_raw_fd(), listener.as_raw_fd()],
        )?;
        let replied = started.elapsed();
        drop(theirs);
        drop(listener);
        let Reply::Forked { pid, endpoint } = reply else {
            bail!("unexpected reply to fork: {reply:?}");
        };
        let endpoint: SocketAddr = endpoint
            .parse()
            .with_context(|| format!("bad endpoint from the host: {endpoint}"))?;
        let mut child = Self {
            pid,
            channel: ours,
            child: None,
            events: Vec::new(),
            endpoint: Some(endpoint),
        };
        match child.reply()? {
            Reply::Forked { .. } => {
                tracing::debug!(
                    host = self.pid,
                    clone = pid,
                    %endpoint,
                    sockets = ?sockets_made,
                    replied = ?replied,
                    announced = ?started.elapsed(),
                    "clone forked"
                );
                Ok((child, endpoint))
            }
            other => bail!("unexpected announcement from clone {pid}: {other:?}"),
        }
    }

    /// Runs the initializer with `recipe` on its stdin; its exit status.
    ///
    /// # Errors
    ///
    /// Fails on a refused request or a dead host.
    pub fn initialize(&mut self, recipe: &[u8]) -> Result<i32> {
        match self.request(Request::Initialize, recipe, &[])? {
            Reply::Exited {
                run: Run::Initializer,
                status,
                ..
            } => Ok(status),
            other => bail!("unexpected reply to initialize: {other:?}"),
        }
    }

    /// Sends a request and returns its reply, keeping unsolicited events.
    ///
    /// # Errors
    ///
    /// Fails if the host answered `error`, exited, or the channel broke.
    pub fn request(&mut self, request: Request, payload: &[u8], fds: &[i32]) -> Result<Reply> {
        tracing::trace!(
            host = self.pid,
            ?request,
            payload = payload.len(),
            fds = fds.len(),
            "request"
        );
        self.channel.send(&request, payload, fds)?;
        self.reply()
    }

    /// The next reply that is not an unsolicited event.
    ///
    /// # Errors
    ///
    /// Fails on `error`, on the guest exiting, or on a closed channel.
    pub fn reply(&mut self) -> Result<Reply> {
        loop {
            let Some(Frame { message, .. }) = self.channel.recv::<Reply>()? else {
                bail!("host {} closed its control channel", self.pid);
            };
            match message {
                Reply::Error { text } => bail!("host {} refused: {text}", self.pid),
                Reply::Exited {
                    run: Run::Guest,
                    status,
                    ..
                } => bail!("the guest in host {} exited with status {status}", self.pid),
                Reply::Exited {
                    run: Run::Child, ..
                } => {
                    tracing::debug!(host = self.pid, event = ?message, "event while waiting");
                    self.events.push(message);
                }
                other => {
                    tracing::trace!(host = self.pid, reply = ?other, "reply");
                    return Ok(other);
                }
            }
        }
    }

    /// Reads one message the host sent unprompted: `Exited`, for the guest
    /// or for a clone the host reaped. Blocks until one arrives; the host
    /// can be polled first (`AsFd`).
    ///
    /// # Errors
    ///
    /// Fails on `error`, on a closed channel, or on a reply that is not an
    /// event.
    pub fn read_event(&mut self) -> Result<Reply> {
        let Some(Frame { message, .. }) = self.channel.recv::<Reply>()? else {
            bail!("host {} closed its control channel", self.pid);
        };
        match message {
            Reply::Error { text } => bail!("host {} refused: {text}", self.pid),
            Reply::Exited { .. } => {
                tracing::debug!(host = self.pid, event = ?message, "event");
                Ok(message)
            }
            other => bail!("unexpected reply from host {}: {other:?}", self.pid),
        }
    }

    /// Waits for the guest to exit; its exit status.
    ///
    /// # Errors
    ///
    /// As `read_event`.
    pub fn wait_exit(&mut self) -> Result<i32> {
        loop {
            match self.read_event()? {
                Reply::Exited {
                    run: Run::Guest,
                    status,
                    ..
                } => return Ok(status),
                event => self.events.push(event),
            }
        }
    }

    /// Events received so far (clones reaped by a template).
    #[must_use]
    pub fn events(&self) -> &[Reply] {
        &self.events
    }

    /// Takes the events received so far, leaving none behind.
    pub fn take_events(&mut self) -> Vec<Reply> {
        std::mem::take(&mut self.events)
    }

    /// Asks the host to stop and waits for it to go.
    ///
    /// # Errors
    ///
    /// Fails if the process cannot be waited for.
    pub fn stop(mut self) -> Result<()> {
        self.channel.send(&Request::Stop, &[], &[]).ok();
        self.wait_gone()
    }

    /// Kills the host outright and waits for it to go.
    ///
    /// # Errors
    ///
    /// Fails if the process cannot be waited for.
    pub fn kill(mut self) -> Result<()> {
        unsafe { libc::kill(self.pid as libc::pid_t, libc::SIGKILL) };
        self.wait_gone()
    }

    fn wait_gone(&mut self) -> Result<()> {
        if let Some(mut child) = self.child.take() {
            child.wait().context("failed to wait for the host")?;
        } else {
            // A clone is reaped by its template; its channel closing is the
            // end we can observe.
            while self.channel.recv::<Reply>()?.is_some() {}
        }
        Ok(())
    }

    /// Takes the channel's descriptor out, for passing on.
    #[must_use]
    pub fn into_raw_fd(self) -> i32 {
        let Self { channel, .. } = self;
        let fd: std::os::fd::OwnedFd = channel.into();
        fd.into_raw_fd()
    }
}

impl AsFd for HostProcess {
    fn as_fd(&self) -> BorrowedFd<'_> {
        self.channel.as_fd()
    }
}
