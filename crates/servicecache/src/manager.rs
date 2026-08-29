//! The manager's side of a host process: spawn it, drive the control
//! channel, reap it. Used by the tests; the manager proper builds on it.

use std::{
    net::{SocketAddr, TcpListener},
    os::{
        fd::{AsRawFd, IntoRawFd},
        unix::process::CommandExt,
    },
    path::Path,
    process::{Child, Command, Stdio},
};

use anyhow::{Context as _, Result, bail};

use crate::host::protocol::{Channel, Frame, Reply, Request, Run};

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
}

impl HostProcess {
    /// Spawns `servicecache host` for `manifest` by re-executing this
    /// binary. The host dies with the calling thread.
    ///
    /// # Errors
    ///
    /// Fails if the channel or the process cannot be created.
    pub fn spawn(manifest: &Path) -> Result<Self> {
        let binary = std::env::current_exe().context("failed to locate this binary")?;
        Self::spawn_with_binary(&binary, manifest)
    }

    /// Spawns `<binary> host` for `manifest`; for callers that are not the
    /// `servicecache` binary themselves, such as tests.
    ///
    /// # Errors
    ///
    /// Fails if the channel or the process cannot be created.
    pub fn spawn_with_binary(binary: &Path, manifest: &Path) -> Result<Self> {
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
            .stdin(Stdio::null());
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
        Ok(Self {
            pid: child.id(),
            channel: ours,
            child: Some(child),
            events: Vec::new(),
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
    /// Fails if the guest exits before listening or the request is refused.
    pub fn start(&mut self) -> Result<SocketAddr> {
        let listener = TcpListener::bind("127.0.0.1:0").context("failed to bind a listener")?;
        let reply = self.request(Request::Start, &[], &[listener.as_raw_fd()])?;
        drop(listener);
        match reply {
            Reply::Ready { endpoint } => endpoint
                .parse()
                .with_context(|| format!("bad endpoint from the host: {endpoint}")),
            other => bail!("unexpected reply to start: {other:?}"),
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
                } => self.events.push(message),
                other => return Ok(other),
            }
        }
    }

    /// Events received so far (clones reaped by a template).
    #[must_use]
    pub fn events(&self) -> &[Reply] {
        &self.events
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
