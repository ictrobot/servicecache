//! The instances a serving manager holds. Each is a clone forked off a
//! template — a running host process, child of its template's — watched
//! by a thread of its own until the guest exits or the stop pipe closes.
//! Dropping a registry entry closes the stop pipe and the watcher shuts
//! its host down.

use std::{
    collections::HashMap,
    net::SocketAddr,
    os::fd::{AsFd as _, OwnedFd},
    sync::{Arc, Mutex},
    time::{Duration, Instant},
};

use anyhow::{Context as _, Result};
use nix::poll::{PollFd, PollFlags, PollTimeout, poll};

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

/// Adopts a running host — a clone just forked off a template — as an
/// instance: a watcher thread observes it until the guest exits or the
/// entry is dropped. The clone is its template's child, not this
/// thread's, so the watcher only observes and stops it.
///
/// # Errors
///
/// Fails when the stop pipe or the thread cannot be created.
pub fn adopt(
    id: String,
    service: String,
    version: String,
    host: HostProcess,
    endpoint: SocketAddr,
    ttl: Duration,
) -> Result<Entry> {
    let (stop_read, stop_write) =
        nix::unistd::pipe2(nix::fcntl::OFlag::O_CLOEXEC).context("failed to create a stop pipe")?;
    let shared = Arc::new(Shared::default());
    let watcher_shared = Arc::clone(&shared);
    std::thread::Builder::new()
        .name(format!("instance-{id}"))
        .spawn(move || watch(host, &watcher_shared, &stop_read))
        .context("failed to start the instance's watcher thread")?;
    Ok(Entry {
        id,
        service,
        version,
        endpoint,
        lease: Mutex::new(Lease {
            ttl,
            expires_at: Instant::now() + ttl,
        }),
        shared,
        _stop: stop_write,
    })
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
