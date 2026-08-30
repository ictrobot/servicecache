//! The instances a serving manager holds. Each is one host process owned
//! by a dedicated thread that brings it up, watches it and stops it: a
//! host dies with the thread that spawned it, so the owner thread must
//! live exactly as long as the instance. Dropping a registry entry closes
//! the stop pipe and the owner shuts its host down.

use std::{
    collections::HashMap,
    net::SocketAddr,
    os::fd::{AsFd as _, OwnedFd},
    path::PathBuf,
    sync::{Arc, Mutex},
    time::{Duration, Instant},
};

use anyhow::{Context as _, Result};
use nix::poll::{PollFd, PollFlags, PollTimeout, poll};
use tokio::sync::oneshot;

use super::api;
use crate::{
    host::protocol::{Reply, Run},
    manager::HostProcess,
};

/// The guest's state, shared between the registry entry and the owner.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub enum GuestState {
    #[default]
    Running,
    /// The guest exited; `None` when the host went away without reporting
    /// a status.
    Exited(Option<i32>),
}

#[derive(Debug, Default)]
struct Shared {
    state: Mutex<GuestState>,
}

/// The lease on an instance: renewing restarts `ttl`.
#[derive(Debug)]
struct Lease {
    ttl: Duration,
    expires_at: Instant,
}

/// One held instance.
#[derive(Debug)]
pub struct Entry {
    pub id: String,
    pub service: String,
    pub version: String,
    pub endpoint: SocketAddr,
    lease: Mutex<Lease>,
    shared: Arc<Shared>,
    /// The write end of the owner's stop pipe; dropping it stops the
    /// instance.
    _stop: OwnedFd,
}

impl Entry {
    /// Restarts the lease, with a new TTL when one is given.
    pub fn renew(&self, ttl: Option<Duration>) {
        let mut lease = self.lease.lock().expect("lease lock poisoned");
        if let Some(ttl) = ttl {
            lease.ttl = ttl;
        }
        lease.expires_at = Instant::now() + lease.ttl;
    }

    fn expired(&self, now: Instant) -> bool {
        self.lease.lock().expect("lease lock poisoned").expires_at <= now
    }

    /// The guest's state.
    #[must_use]
    pub fn state(&self) -> GuestState {
        *self.shared.state.lock().expect("state lock poisoned")
    }

    /// The instance as the API describes it.
    #[must_use]
    pub fn describe(&self) -> api::Instance {
        let (state, exit_status) = match self.state() {
            GuestState::Running => (api::InstanceState::Running, None),
            GuestState::Exited(status) => (api::InstanceState::Exited, status),
        };
        let expires_at = self.lease.lock().expect("lease lock poisoned").expires_at;
        api::Instance {
            id: self.id.clone(),
            service: self.service.clone(),
            version: self.version.clone(),
            endpoint: api::Endpoint::from(self.endpoint),
            state,
            exit_status,
            expires_in_seconds: expires_at
                .saturating_duration_since(Instant::now())
                .as_secs(),
        }
    }
}

/// The held instances, by id.
#[derive(Debug, Default)]
pub struct Registry {
    entries: Mutex<HashMap<String, Arc<Entry>>>,
}

impl Registry {
    pub fn insert(&self, entry: Arc<Entry>) {
        self.entries
            .lock()
            .expect("registry lock poisoned")
            .insert(entry.id.clone(), entry);
    }

    #[must_use]
    pub fn get(&self, id: &str) -> Option<Arc<Entry>> {
        self.entries
            .lock()
            .expect("registry lock poisoned")
            .get(id)
            .cloned()
    }

    pub fn remove(&self, id: &str) -> Option<Arc<Entry>> {
        self.entries
            .lock()
            .expect("registry lock poisoned")
            .remove(id)
    }

    /// Every held instance, in id order.
    #[must_use]
    pub fn list(&self) -> Vec<Arc<Entry>> {
        let mut entries: Vec<Arc<Entry>> = self
            .entries
            .lock()
            .expect("registry lock poisoned")
            .values()
            .cloned()
            .collect();
        entries.sort_by(|left, right| left.id.cmp(&right.id));
        entries
    }

    /// Removes and returns every expired instance; dropping them stops
    /// their hosts.
    pub fn remove_expired(&self) -> Vec<Arc<Entry>> {
        let now = Instant::now();
        let mut entries = self.entries.lock().expect("registry lock poisoned");
        let expired: Vec<String> = entries
            .values()
            .filter(|entry| entry.expired(now))
            .map(|entry| entry.id.clone())
            .collect();
        expired.iter().filter_map(|id| entries.remove(id)).collect()
    }

    pub fn clear(&self) {
        self.entries.lock().expect("registry lock poisoned").clear();
    }
}

/// What the owner thread runs for an instance.
pub struct BringUp {
    pub manifest_path: PathBuf,
    pub has_prepare: bool,
    /// The initializer's stdin; the initializer runs only when this is
    /// set.
    pub recipe: Option<Vec<u8>>,
    pub cache_dir: PathBuf,
}

/// An instance being brought up on its owner thread.
pub struct Pending {
    /// Resolves to the endpoint once the instance serves, or to the
    /// problem that stopped it. Dropping it abandons the bring-up: the
    /// owner stops the host when it finds no receiver.
    pub ready: oneshot::Receiver<Result<SocketAddr, api::Problem>>,
    shared: Arc<Shared>,
    stop: OwnedFd,
}

impl Pending {
    /// The registry entry for the now-serving instance.
    #[must_use]
    pub fn into_entry(
        self,
        id: String,
        service: String,
        version: String,
        endpoint: SocketAddr,
        ttl: Duration,
    ) -> Entry {
        Entry {
            id,
            service,
            version,
            endpoint,
            lease: Mutex::new(Lease {
                ttl,
                expires_at: Instant::now() + ttl,
            }),
            shared: self.shared,
            _stop: self.stop,
        }
    }
}

/// Starts an owner thread bringing an instance up.
///
/// # Errors
///
/// Fails when the stop pipe or the thread cannot be created.
pub fn spawn(id: &str, bring_up: BringUp) -> Result<Pending> {
    let (stop_read, stop_write) =
        nix::unistd::pipe2(nix::fcntl::OFlag::O_CLOEXEC).context("failed to create a stop pipe")?;
    let (ready_send, ready) = oneshot::channel();
    let shared = Arc::new(Shared::default());
    let owner_shared = Arc::clone(&shared);
    std::thread::Builder::new()
        .name(format!("instance-{id}"))
        .spawn(move || owner(&bring_up, &owner_shared, &stop_read, ready_send))
        .context("failed to start the instance's owner thread")?;
    Ok(Pending {
        ready,
        shared,
        stop: stop_write,
    })
}

/// The owner thread: brings the host up, reports the endpoint, then
/// watches until the guest exits or the stop pipe closes.
fn owner(
    bring: &BringUp,
    shared: &Shared,
    stop: &OwnedFd,
    ready: oneshot::Sender<Result<SocketAddr, api::Problem>>,
) {
    let (host, endpoint) = match bring_up(bring) {
        Ok(brought_up) => brought_up,
        Err(problem) => {
            ready.send(Err(problem)).ok();
            return;
        }
    };
    if ready.send(Ok(endpoint)).is_err() {
        // The creator went away; nothing will register the instance.
        tracing::debug!(host = host.pid(), "the instance's creator gave up");
        host.stop().ok();
        return;
    }
    watch(host, shared, stop);
}

fn bring_up(bring: &BringUp) -> Result<(HostProcess, SocketAddr), api::Problem> {
    let mut host = HostProcess::spawn(&bring.manifest_path, &bring.cache_dir)
        .map_err(|error| api::Problem::bring_up_failed(&error))?;
    if bring.has_prepare {
        match host.prepare() {
            Ok(0) => {}
            Ok(status) => {
                host.kill().ok();
                return Err(api::Problem::prepare_failed(status));
            }
            Err(error) => {
                host.kill().ok();
                return Err(api::Problem::bring_up_failed(&error));
            }
        }
    }
    let endpoint = match host.start() {
        Ok(endpoint) => endpoint,
        Err(error) => {
            host.kill().ok();
            return Err(api::Problem::bring_up_failed(&error));
        }
    };
    if let Some(recipe) = &bring.recipe {
        match host.initialize(recipe) {
            Ok(0) => {}
            Ok(status) => {
                host.kill().ok();
                return Err(api::Problem::initializer_failed(status));
            }
            Err(error) => {
                host.kill().ok();
                return Err(api::Problem::bring_up_failed(&error));
            }
        }
    }
    Ok((host, endpoint))
}

fn watch(mut host: HostProcess, shared: &Shared, stop: &OwnedFd) {
    loop {
        let (host_ready, stop_ready) = {
            let mut fds = [
                PollFd::new(host.as_fd(), PollFlags::POLLIN),
                PollFd::new(stop.as_fd(), PollFlags::POLLIN),
            ];
            match poll(&mut fds, PollTimeout::NONE) {
                Ok(_) => {}
                Err(nix::errno::Errno::EINTR) => continue,
                Err(error) => {
                    tracing::warn!(host = host.pid(), %error, "poll on the instance failed");
                    break;
                }
            }
            let ready = |fd: &PollFd| fd.revents().is_some_and(|events| !events.is_empty());
            (ready(&fds[0]), ready(&fds[1]))
        };

        if host_ready {
            match host.read_event() {
                Ok(Reply::Exited {
                    run: Run::Guest,
                    status,
                    ..
                }) => {
                    *shared.state.lock().expect("state lock poisoned") =
                        GuestState::Exited(Some(status));
                    tracing::info!(host = host.pid(), status, "the guest exited");
                    host.stop().ok();
                    return;
                }
                Ok(event) => tracing::debug!(host = host.pid(), ?event, "event"),
                Err(error) => {
                    let mut state = shared.state.lock().expect("state lock poisoned");
                    if *state == GuestState::Running {
                        *state = GuestState::Exited(None);
                    }
                    drop(state);
                    tracing::debug!(host = host.pid(), %error, "the host went away");
                    host.kill().ok();
                    return;
                }
            }
        }
        if stop_ready {
            break;
        }
    }
    host.stop().ok();
}
