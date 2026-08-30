//! The template cache: frozen host processes that requests fork instances
//! off. The base template for a service is brought up (prepare, start)
//! and frozen; a recipe's template is a fork of the base, initialized
//! with the recipe and frozen in turn, so copy-on-write sharing chains
//! from the base through every recipe template to the clones.
//!
//! Templates do not live forever: one expires when it has had no live
//! descendant for the TTL — counted from its freeze if it is never
//! forked. The process tree itself is the ledger: every descendant
//! (an instance clone, or a recipe template built on this one) is an OS
//! child of the template's host, which reaps it when it dies and reports
//! `exited (child)` on the control channel. The owner counts forks served
//! minus exits reported, so a template with a live descendant can never
//! expire, and chains unwind leaf-first — a base stays while a recipe
//! template stands on it.
//!
//! Every template is owned by a dedicated thread: the base's owner spawns
//! its host (a host dies with the thread that spawned it), a recipe
//! template's owner is handed the clone its base forked. The owner brings
//! the template to frozen, then serves fork commands, drains the exit
//! events of the clones its host reaps so the control channel never
//! fills, and expires the template when its time comes.

use std::{
    collections::HashMap,
    net::SocketAddr,
    path::Path,
    sync::{Arc, Mutex, mpsc},
    time::Duration,
};

use anyhow::Result;
use sha2::{Digest as _, Sha256};
use tokio::sync::oneshot;

use super::api;
use crate::{
    host::protocol::{Reply, Run},
    manager::HostProcess,
    manifest::Manifest,
};

/// What identifies a template. A fuller key would also name the package's
/// content digest and the runtime's identity, but both are constant
/// within one manager process — discovery is a startup snapshot and
/// templates die with the manager — so they stay implicit rather than
/// hashing gigabytes per service; they belong in the key if templates
/// ever outlive the process.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
struct Key {
    name: String,
    version: String,
    /// SHA-256 of the recipe bytes; `None` is the base template
    /// (prepared and started, initializer not run).
    recipe: Option<[u8; 32]>,
}

impl Key {
    fn new(manifest: &Manifest, recipe: Option<&[u8]>) -> Self {
        Self {
            name: manifest.service.name.clone(),
            version: manifest.service.version.clone(),
            recipe: recipe.map(|recipe| Sha256::digest(recipe).into()),
        }
    }
}

/// A command to a template's owner thread.
enum Command {
    /// Fork a clone; the reply carries its handle and endpoint.
    Fork(oneshot::Sender<Result<(HostProcess, SocketAddr)>>),
}

/// A handle on a frozen template.
#[derive(Clone)]
pub struct Template {
    commands: mpsc::Sender<Command>,
    /// Cleared by the owner when the template is gone — expired, failed
    /// or stopped.
    alive: Arc<std::sync::atomic::AtomicBool>,
}

impl Template {
    /// Forks an instance off the template.
    ///
    /// # Errors
    ///
    /// Returns a `template-failed` problem when the template is gone or
    /// the fork fails; the caller should forget the template and rebuild.
    pub async fn fork(&self) -> Result<(HostProcess, SocketAddr), api::Problem> {
        let (reply, answer) = oneshot::channel();
        self.commands
            .send(Command::Fork(reply))
            .map_err(|_| api::Problem::template_failed("the template is gone"))?;
        match answer.await {
            Ok(Ok(forked)) => Ok(forked),
            Ok(Err(error)) => Err(api::Problem::template_failed(format!("{error:#}"))),
            Err(_) => Err(api::Problem::template_failed("the template died forking")),
        }
    }

    /// Whether the template can still fork: not expired, failed or
    /// stopped.
    fn alive(&self) -> bool {
        self.alive.load(std::sync::atomic::Ordering::Relaxed)
    }
}

type Slot = Arc<tokio::sync::Mutex<Option<Template>>>;

/// The templates a serving manager holds, filled on demand.
pub struct Templates {
    slots: Mutex<HashMap<Key, Slot>>,
    /// How long a template lives with no live descendant.
    ttl: Duration,
}

impl Templates {
    #[must_use]
    pub fn new(ttl: Duration) -> Self {
        Self {
            slots: Mutex::new(HashMap::new()),
            ttl,
        }
    }
    /// The template a request forks from, filled through the fork chain
    /// on a miss: base = spawn, prepare, start, freeze; with a recipe =
    /// fork the base, initialize the clone, freeze it. Fills for one key
    /// run once, with concurrent requests waiting; a failed fill is
    /// retried by the next request.
    ///
    /// # Errors
    ///
    /// Returns the problem that stopped the fill.
    pub async fn obtain(
        &self,
        manifest: &Manifest,
        recipe: Option<&[u8]>,
        cache_dir: &Path,
    ) -> Result<Template, api::Problem> {
        let base_key = Key::new(manifest, None);
        let slot = self.slot(base_key);
        let base = {
            let mut slot = slot.lock().await;
            match &*slot {
                Some(template) if template.alive() => template.clone(),
                _ => {
                    let template = fill_base(manifest, cache_dir, self.ttl).await?;
                    *slot = Some(template.clone());
                    template
                }
            }
        };
        let Some(recipe) = recipe else {
            return Ok(base);
        };

        let recipe_key = Key::new(manifest, Some(recipe));
        let slot = self.slot(recipe_key);
        let mut slot = slot.lock().await;
        match &*slot {
            Some(template) if template.alive() => Ok(template.clone()),
            _ => {
                let template = fill_recipe(&base, manifest, recipe, self.ttl).await?;
                *slot = Some(template.clone());
                Ok(template)
            }
        }
    }

    /// Forgets the template for the request — after a failed fork, so the
    /// next `obtain` rebuilds it.
    pub fn forget(&self, manifest: &Manifest, recipe: Option<&[u8]>) {
        let key = Key::new(manifest, recipe);
        self.slots.lock().expect("slots lock poisoned").remove(&key);
    }

    /// Drops every template; their owners stop the hosts.
    pub fn clear(&self) {
        self.slots.lock().expect("slots lock poisoned").clear();
    }

    /// Removes the slots of expired templates, so keys never requested
    /// again do not accumulate. Slots someone holds or is filling are
    /// left alone.
    pub fn prune(&self) {
        self.slots
            .lock()
            .expect("slots lock poisoned")
            .retain(|_, slot| {
                if Arc::strong_count(slot) > 1 {
                    return true;
                }
                match slot.try_lock() {
                    Ok(guard) => guard.as_ref().is_some_and(Template::alive),
                    Err(_) => true,
                }
            });
    }

    fn slot(&self, key: Key) -> Slot {
        self.slots
            .lock()
            .expect("slots lock poisoned")
            .entry(key)
            .or_default()
            .clone()
    }
}

/// Brings the base template up on a fresh owner thread: spawn, prepare,
/// start, freeze.
async fn fill_base(
    manifest: &Manifest,
    cache_dir: &Path,
    ttl: Duration,
) -> Result<Template, api::Problem> {
    let service = manifest.service.name.clone();
    let version = manifest.service.version.clone();
    let manifest_path = manifest.directory().join("service.toml");
    let has_prepare = manifest.prepare.is_some();
    let cache_dir = cache_dir.to_path_buf();
    let alive = Arc::new(std::sync::atomic::AtomicBool::new(true));
    let owner_alive = Arc::clone(&alive);
    let (commands, commands_receive) = mpsc::channel();
    let (ready, ready_receive) = oneshot::channel();
    std::thread::Builder::new()
        .name(format!("template-{service}-{version}"))
        .spawn(move || {
            base_owner(
                &manifest_path,
                has_prepare,
                &cache_dir,
                ttl,
                &owner_alive,
                &commands_receive,
                ready,
            );
        })
        .map_err(|error| api::Problem::internal(format!("{error:#}")))?;
    match ready_receive.await {
        Ok(Ok(())) => Ok(Template { commands, alive }),
        Ok(Err(problem)) => Err(problem),
        Err(_) => Err(api::Problem::internal("the template's owner thread died")),
    }
}

/// Builds a recipe's template: fork the base, then initialize and freeze
/// the clone on a fresh owner thread. Until it expires it is the base's
/// live child process, so the base outlives it.
async fn fill_recipe(
    base: &Template,
    manifest: &Manifest,
    recipe: &[u8],
    ttl: Duration,
) -> Result<Template, api::Problem> {
    let (clone, _endpoint) = base.fork().await?;
    let service = manifest.service.name.clone();
    let version = manifest.service.version.clone();
    let recipe = recipe.to_vec();
    let alive = Arc::new(std::sync::atomic::AtomicBool::new(true));
    let owner_alive = Arc::clone(&alive);
    let (commands, commands_receive) = mpsc::channel();
    let (ready, ready_receive) = oneshot::channel();
    std::thread::Builder::new()
        .name(format!("template-{service}-{version}-recipe"))
        .spawn(move || {
            recipe_owner(clone, &recipe, ttl, &owner_alive, &commands_receive, ready);
        })
        .map_err(|error| api::Problem::internal(format!("{error:#}")))?;
    match ready_receive.await {
        Ok(Ok(())) => Ok(Template { commands, alive }),
        Ok(Err(problem)) => Err(problem),
        Err(_) => Err(api::Problem::internal("the template's owner thread died")),
    }
}

/// The base template's owner: brings its host to frozen and serves forks.
fn base_owner(
    manifest_path: &Path,
    has_prepare: bool,
    cache_dir: &Path,
    ttl: Duration,
    alive: &std::sync::atomic::AtomicBool,
    commands: &mpsc::Receiver<Command>,
    ready: oneshot::Sender<Result<(), api::Problem>>,
) {
    let mut host = match HostProcess::spawn(manifest_path, cache_dir) {
        Ok(host) => host,
        Err(error) => {
            ready.send(Err(api::Problem::bring_up_failed(&error))).ok();
            return;
        }
    };
    if has_prepare {
        match host.prepare() {
            Ok(0) => {}
            Ok(status) => {
                host.kill().ok();
                ready.send(Err(api::Problem::prepare_failed(status))).ok();
                return;
            }
            Err(error) => {
                host.kill().ok();
                ready.send(Err(api::Problem::bring_up_failed(&error))).ok();
                return;
            }
        }
    }
    if let Err(error) = host.start() {
        host.kill().ok();
        ready.send(Err(api::Problem::bring_up_failed(&error))).ok();
        return;
    }
    freeze_and_serve(host, ttl, alive, commands, ready);
}

/// A recipe template's owner: initializes the clone it was handed, then
/// freezes it and serves forks.
fn recipe_owner(
    mut host: HostProcess,
    recipe: &[u8],
    ttl: Duration,
    alive: &std::sync::atomic::AtomicBool,
    commands: &mpsc::Receiver<Command>,
    ready: oneshot::Sender<Result<(), api::Problem>>,
) {
    match host.initialize(recipe) {
        Ok(0) => {}
        Ok(status) => {
            host.kill().ok();
            ready
                .send(Err(api::Problem::initializer_failed(status)))
                .ok();
            return;
        }
        Err(error) => {
            host.kill().ok();
            ready.send(Err(api::Problem::bring_up_failed(&error))).ok();
            return;
        }
    }
    freeze_and_serve(host, ttl, alive, commands, ready);
}

fn freeze_and_serve(
    mut host: HostProcess,
    ttl: Duration,
    alive: &std::sync::atomic::AtomicBool,
    commands: &mpsc::Receiver<Command>,
    ready: oneshot::Sender<Result<(), api::Problem>>,
) {
    match host.freeze() {
        Ok(coroutines) => {
            tracing::info!(host = host.pid(), coroutines, "template frozen");
        }
        Err(error) => {
            // A failed freeze takes the host with it.
            ready.send(Err(api::Problem::bring_up_failed(&error))).ok();
            return;
        }
    }
    if ready.send(Ok(())).is_err() {
        // The creator went away; nothing holds the template.
        tracing::debug!(host = host.pid(), "the template's creator gave up");
        host.stop().ok();
        return;
    }
    serve_forks(host, ttl, alive, commands);
}

/// Serves fork commands until every handle is dropped, the template goes
/// `ttl` without a live descendant, or its host fails. Live descendants
/// are forks served minus the reaped-clone exits the host reports,
/// drained between commands so the control channel never fills.
fn serve_forks(
    mut host: HostProcess,
    ttl: Duration,
    alive: &std::sync::atomic::AtomicBool,
    commands: &mpsc::Receiver<Command>,
) {
    use std::sync::atomic::Ordering;

    let mut children: usize = 0;
    let mut idle_since = std::time::Instant::now();
    loop {
        match commands.recv_timeout(Duration::from_secs(1)) {
            Ok(Command::Fork(reply)) => {
                let result = host.fork();
                if let Err(error) = &result {
                    tracing::warn!(host = host.pid(), %error, "fork failed");
                    alive.store(false, Ordering::Relaxed);
                    reply.send(result).ok();
                    // The template is single-purpose: a failed fork means
                    // the frozen host is gone or wedged.
                    host.kill().ok();
                    return;
                }
                children += 1;
                for event in host.take_events() {
                    if logged_child_exit(&host, &event) {
                        children = children.saturating_sub(1);
                    }
                }
                if children == 0 {
                    idle_since = std::time::Instant::now();
                }
                reply.send(result).ok();
            }
            Err(mpsc::RecvTimeoutError::Timeout) => {
                let Some(exits) = drain_events(&mut host) else {
                    tracing::warn!(host = host.pid(), "the template's host went away");
                    alive.store(false, Ordering::Relaxed);
                    host.kill().ok();
                    return;
                };
                if exits > 0 {
                    children = children.saturating_sub(exits);
                    if children == 0 {
                        idle_since = std::time::Instant::now();
                    }
                }
                if children == 0 && idle_since.elapsed() >= ttl {
                    alive.store(false, Ordering::Relaxed);
                    tracing::info!(host = host.pid(), "template expired");
                    host.stop().ok();
                    return;
                }
            }
            Err(mpsc::RecvTimeoutError::Disconnected) => break,
        }
    }
    alive.store(false, Ordering::Relaxed);
    tracing::info!(host = host.pid(), "template stopped");
    host.stop().ok();
}

/// Logs one unsolicited event from the template's host; whether it is a
/// reaped clone's exit.
fn logged_child_exit(host: &HostProcess, event: &Reply) -> bool {
    tracing::debug!(host = host.pid(), ?event, "template event");
    matches!(
        event,
        Reply::Exited {
            run: Run::Child,
            ..
        }
    )
}

/// Reads whatever the host has sent and counts the reaped-clone exits;
/// `None` when the channel is gone.
fn drain_events(host: &mut HostProcess) -> Option<usize> {
    use std::os::fd::AsFd as _;

    use nix::poll::{PollFd, PollFlags, PollTimeout, poll};

    let mut exits = 0;
    loop {
        let mut fds = [PollFd::new(host.as_fd(), PollFlags::POLLIN)];
        match poll(&mut fds, PollTimeout::ZERO) {
            Ok(0) => return Some(exits),
            Ok(_) => {}
            Err(nix::errno::Errno::EINTR) => continue,
            Err(_) => return None,
        }
        match host.read_event() {
            Ok(event) => {
                if logged_child_exit(host, &event) {
                    exits += 1;
                }
            }
            Err(_) => return None,
        }
    }
}
