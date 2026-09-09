//! The lifecycle tests: freeze-is-terminal and resume, proven on every
//! assembled service. A trial per service and case, discovered at run time
//! (`libtest-mimic`, so `cargo test`'s filters and thread count and nextest
//! apply): `make lifecycle-tests` runs the matrix, `make lifecycle-tests-long`
//! includes the ignored trials with thousands of forks; a name filter such
//! as `cargo test --test lifecycle <service>` selects trials. Without
//! `SERVICECACHE_LIFECYCLE` set there are no trials, so `make test` skips
//! the matrix.
//!
//! The matrix, per service: freeze; fork N children sequentially; live
//! siblings at once; a chain (child → freeze → fork); freeze while a client
//! is mid-request; kill the host at every phase. State, background work and
//! divergence are checked through the service's own adapter
//! (`services/<name>/smoke/adapter`); memory sharing from `smaps_rollup`.

#[path = "support/process.rs"]
mod process;
#[path = "support/service_adapter.rs"]
mod service_adapter;

use std::{
    net::SocketAddr,
    path::{Path, PathBuf},
    time::{Duration, Instant},
};

use service_adapter::ServiceAdapter;
use servicecache::{manager::HostProcess, manifest::Manifest};

fn repo_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../..")
}

fn binary() -> &'static Path {
    Path::new(env!("CARGO_BIN_EXE_servicecache"))
}

fn cache_dir() -> PathBuf {
    servicecache::cache::directory(None, std::env::var_os("SERVICECACHE_CACHE_DIR").as_deref())
        .expect("a cache directory")
}

fn manifests() -> Vec<PathBuf> {
    let root = repo_root().join("work/services");
    let Ok(entries) = std::fs::read_dir(&root) else {
        eprintln!(
            "skipped: {} is not built (run `make services`)",
            root.display()
        );
        return Vec::new();
    };
    let mut manifests: Vec<PathBuf> = entries
        .filter_map(Result::ok)
        .map(|entry| entry.path().join("service.toml"))
        .filter(|path| path.is_file())
        .collect();
    manifests.sort();
    manifests
}

/// Latencies of the runtime's own operations, in microseconds.
#[derive(Default)]
struct Timings {
    /// `freeze` request → `frozen` reply.
    freeze: Vec<u128>,
    /// `fork` request → the clone's `forked` announcement: `fork()` plus
    /// the child's rebuild and resurrection.
    fork: Vec<u128>,
    /// `fork` request → first successful raw TCP connect to the clone's
    /// endpoint. The kernel accepts on a listening socket before the guest
    /// does, so this is a lower bound on the clone answering.
    connect: Vec<u128>,
}

#[allow(clippy::cast_precision_loss)]
fn summary(samples: &[u128]) -> String {
    if samples.is_empty() {
        return "no samples".to_owned();
    }
    let mut sorted = samples.to_vec();
    sorted.sort_unstable();
    let ms = |us: u128| us as f64 / 1000.0;
    format!(
        "min {:.1} ms, median {:.1} ms, max {:.1} ms over {}",
        ms(sorted[0]),
        ms(sorted[sorted.len() / 2]),
        ms(sorted[sorted.len() - 1]),
        sorted.len()
    )
}

fn profile() -> &'static str {
    if cfg!(debug_assertions) {
        "debug"
    } else {
        "release"
    }
}

/// A service under test: its manifest and its adapter.
struct Subject {
    manifest: Manifest,
    path: PathBuf,
    adapter: ServiceAdapter,
    name: String,
    timings: std::cell::RefCell<Timings>,
}

impl Subject {
    fn load(manifest_path: &Path) -> Option<Self> {
        let manifest = Manifest::load(manifest_path).expect("load the manifest");
        let name = manifest.service.name.clone();
        let adapter = ServiceAdapter::find(&repo_root(), &name)?;
        Some(Self {
            manifest,
            path: manifest_path.to_path_buf(),
            adapter,
            name,
            timings: std::cell::RefCell::default(),
        })
    }

    fn report_timings(&self, what: &str) {
        let timings = self.timings.borrow();
        eprintln!(
            "{} {what} ({} build): freeze {}; fork {}; fork to first connect {}",
            self.name,
            profile(),
            summary(&timings.freeze),
            summary(&timings.fork),
            summary(&timings.connect)
        );
    }

    /// A host brought up and initialized.
    fn bring_up(&self) -> HostProcess {
        let mut host =
            HostProcess::spawn_with_binary(binary(), &self.path, &cache_dir()).expect("spawn");
        if self.manifest.prepare.is_some() {
            assert_eq!(
                host.prepare().expect("prepare"),
                0,
                "{}: prepare",
                self.name
            );
        }
        let endpoint = host.start().expect("start");
        if self.manifest.initializer.is_some() {
            assert_eq!(
                host.initialize(&self.adapter.recipe()).expect("initialize"),
                0,
                "{}: initializer",
                self.name
            );
        }
        self.adapter.check_initialized(endpoint);
        let titled = process::title(host.pid());
        assert!(
            titled.starts_with("servicecache instance ")
                && titled.ends_with(&format!(" listening on {endpoint}")),
            "{}: the host's title while serving: {titled:?}",
            self.name
        );
        host
    }

    /// A template: brought up, initialized and frozen.
    fn template(&self) -> HostProcess {
        let mut host = self.bring_up();
        let coroutines = self.freeze(&mut host);
        assert!(coroutines >= 1, "{}: no coroutines were frozen", self.name);
        let titled = process::title(host.pid());
        assert!(
            titled.starts_with("servicecache template ") && !titled.contains("listening"),
            "{}: the host's title once frozen: {titled:?}",
            self.name
        );
        assert_eq!(
            thread_count(host.pid()),
            1,
            "{}: a frozen host must have one thread",
            self.name
        );
        host
    }

    fn freeze(&self, host: &mut HostProcess) -> usize {
        let started = Instant::now();
        let coroutines = host.freeze().expect("freeze");
        self.timings
            .borrow_mut()
            .freeze
            .push(started.elapsed().as_micros());
        coroutines
    }

    fn fork(&self, template: &mut HostProcess) -> (HostProcess, SocketAddr) {
        let started = Instant::now();
        let (child, endpoint) = template.fork().expect("fork");
        let forked = started.elapsed();
        let deadline = started + Duration::from_secs(10);
        while std::net::TcpStream::connect_timeout(&endpoint, Duration::from_millis(50)).is_err() {
            assert!(
                Instant::now() < deadline,
                "{}: no connect to the clone",
                self.name
            );
            std::thread::sleep(Duration::from_millis(2));
        }
        let connected = started.elapsed();
        {
            let mut timings = self.timings.borrow_mut();
            timings.fork.push(forked.as_micros());
            timings.connect.push(connected.as_micros());
        }
        assert_eq!(
            thread_count(template.pid()),
            1,
            "{}: the template grew threads after a fork",
            self.name
        );
        let titled = process::title(child.pid());
        assert!(
            titled.starts_with("servicecache instance ")
                && titled.ends_with(&format!(" listening on {endpoint}")),
            "{}: the clone's title: {titled:?}",
            self.name
        );
        (child, endpoint)
    }
}

fn thread_count(pid: u32) -> usize {
    let status = std::fs::read_to_string(format!("/proc/{pid}/status")).expect("read status");
    status
        .lines()
        .find_map(|line| line.strip_prefix("Threads:"))
        .and_then(|value| value.trim().parse().ok())
        .expect("Threads: in status")
}

/// `smaps_rollup` fields in kB.
#[derive(Debug, Clone, Copy, Default)]
struct Smaps {
    pss: u64,
    shared_dirty: u64,
    private_dirty: u64,
}

impl Smaps {
    fn read(pid: u32) -> Self {
        let text = std::fs::read_to_string(format!("/proc/{pid}/smaps_rollup"))
            .expect("read smaps_rollup");
        let field = |name: &str| -> u64 {
            text.lines()
                .find_map(|line| line.strip_prefix(name))
                .and_then(|rest| rest.trim().split(' ').next())
                .and_then(|value| value.parse().ok())
                .unwrap_or(0)
        };
        Self {
            pss: field("Pss:"),
            shared_dirty: field("Shared_Dirty:"),
            private_dirty: field("Private_Dirty:"),
        }
    }
}

fn report_sharing(name: &str, what: &str, parent: u32, child: u32) {
    let parent = Smaps::read(parent);
    let child = Smaps::read(child);
    eprintln!(
        "{name} {what}: parent pss {} MB (private dirty {} MB); child pss {} MB, private dirty {} MB, shared dirty {} MB",
        parent.pss / 1024,
        parent.private_dirty / 1024,
        child.pss / 1024,
        child.private_dirty / 1024,
        child.shared_dirty / 1024
    );
    assert!(
        child.shared_dirty >= child.private_dirty,
        "{name} {what}: the child shares less than it owns ({child:?})"
    );
}

// --- the matrix -----------------------------------------------------------

fn case_freeze_and_fork(subject: &Subject) {
    let mut template = subject.template();
    let (child, endpoint) = subject.fork(&mut template);
    subject.adapter.check_initialized(endpoint);
    subject.adapter.check_working(endpoint);
    report_sharing(&subject.name, "one child", template.pid(), child.pid());
    child.stop().expect("stop the child");
    template.stop().expect("stop the template");
}

fn case_sequential_children(subject: &Subject, count: usize) {
    let mut template = subject.template();
    let started = Instant::now();
    for i in 0..count {
        let (child, endpoint) = subject.fork(&mut template);
        subject.adapter.check_initialized(endpoint);
        if i % 100 == 0 {
            subject.adapter.check_working(endpoint);
        }
        child.stop().expect("stop the child");
        if count > 100 && i % 100 == 99 {
            eprintln!(
                "{}: {} children so far, {:.1?} each",
                subject.name,
                i + 1,
                started.elapsed() / u32::try_from(i + 1).expect("count fits")
            );
        }
    }
    eprintln!(
        "{}: {count} sequential children in {:.1?} ({:.1?} each, including the adapter's checks)",
        subject.name,
        started.elapsed(),
        started.elapsed() / u32::try_from(count).expect("count fits")
    );
    template.stop().expect("stop the template");
}

fn case_live_siblings(subject: &Subject, count: usize) {
    let mut template = subject.template();
    let siblings: Vec<(HostProcess, SocketAddr)> =
        (0..count).map(|_| subject.fork(&mut template)).collect();
    // Each sibling starts from the same state and diverges on its own.
    for (i, (_, endpoint)) in siblings.iter().enumerate() {
        subject.adapter.check_initialized(*endpoint);
        subject.adapter.diverge(*endpoint, i);
    }
    for (i, (_, endpoint)) in siblings.iter().enumerate() {
        subject.adapter.check_diverged(*endpoint, i);
        subject.adapter.check_working(*endpoint);
    }
    report_sharing(
        &subject.name,
        "sibling",
        template.pid(),
        siblings[0].0.pid(),
    );
    for (child, _) in siblings {
        child.stop().expect("stop a sibling");
    }
    template.stop().expect("stop the template");
}

fn case_chain(subject: &Subject) {
    let mut template = subject.template();
    let (mut child, endpoint) = subject.fork(&mut template);
    subject.adapter.check_initialized(endpoint);
    subject.adapter.diverge(endpoint, 7);
    let coroutines = subject.freeze(&mut child);
    assert!(coroutines >= 1);
    assert_eq!(
        thread_count(child.pid()),
        1,
        "{}: frozen child",
        subject.name
    );
    let (grandchild, endpoint) = subject.fork(&mut child);
    subject.adapter.check_initialized(endpoint);
    subject.adapter.check_diverged(endpoint, 7);
    subject.adapter.check_working(endpoint);
    report_sharing(&subject.name, "grandchild", child.pid(), grandchild.pid());
    grandchild.stop().expect("stop the grandchild");
    child.stop().expect("stop the child");
    template.stop().expect("stop the template");
}

fn case_freeze_mid_request(subject: &Subject) {
    let mut host = subject.bring_up();
    let endpoint = host.endpoint().expect("the guest's endpoint");
    let pending = subject.adapter.start_blocking_request(endpoint);
    std::thread::sleep(Duration::from_millis(300));
    subject.freeze(&mut host);
    assert_eq!(
        thread_count(host.pid()),
        1,
        "{}: frozen mid-request",
        subject.name
    );
    let (child, endpoint) = subject.fork(&mut host);
    subject.adapter.check_initialized(endpoint);
    subject.adapter.check_working(endpoint);
    // The pending client belongs to the frozen template, which disconnected
    // it at the freeze: the request has failed by now rather than being
    // served by the child through the inherited connection, and it must
    // never wedge the child.
    let waited = Instant::now();
    let outcome = pending.finish(Duration::from_secs(30));
    assert!(
        waited.elapsed() < Duration::from_secs(2),
        "{}: the request in flight at the freeze was still pending: {outcome}",
        subject.name
    );
    eprintln!(
        "{}: the request in flight at the freeze: {outcome}",
        subject.name
    );
    child.stop().expect("stop the child");
    host.stop().expect("stop the template");
}

fn case_kill_at_every_phase(subject: &Subject) {
    let phases = [
        "spawned",
        "prepared",
        "started",
        "initialized",
        "frozen",
        "forked",
    ];
    for phase in phases {
        let mut host =
            HostProcess::spawn_with_binary(binary(), &subject.path, &cache_dir()).expect("spawn");
        let mut children = Vec::new();
        'phases: {
            if phase == "spawned" {
                break 'phases;
            }
            if subject.manifest.prepare.is_some() {
                assert_eq!(
                    host.prepare().expect("prepare"),
                    0,
                    "{}: prepare",
                    subject.name
                );
            }
            if phase == "prepared" {
                break 'phases;
            }
            let endpoint = host.start().expect("start");
            if phase == "started" {
                break 'phases;
            }
            if subject.manifest.initializer.is_some() {
                assert_eq!(
                    host.initialize(&subject.adapter.recipe())
                        .expect("initialize"),
                    0
                );
            }
            subject.adapter.check_initialized(endpoint);
            if phase == "initialized" {
                break 'phases;
            }
            subject.freeze(&mut host);
            if phase == "frozen" {
                break 'phases;
            }
            let (child, endpoint) = subject.fork(&mut host);
            subject.adapter.check_initialized(endpoint);
            children.push(child);
        }
        let pid = host.pid();
        host.kill().expect("kill");
        assert!(
            !process_exists(pid),
            "{}: host killed at {phase} lingers",
            subject.name
        );
        for child in children {
            // A clone dies with its template.
            let pid = child.pid();
            wait_until(Duration::from_secs(5), || !process_exists(pid));
            assert!(
                !process_exists(pid),
                "{}: clone of a killed template lingers",
                subject.name
            );
            drop(child);
        }
        eprintln!("{}: killed at {phase}, nothing lingers", subject.name);
    }
}

fn process_exists(pid: u32) -> bool {
    match std::fs::read_to_string(format!("/proc/{pid}/status")) {
        Ok(status) => !status.contains("State:\tZ"),
        Err(_) => false,
    }
}

fn wait_until(timeout: Duration, mut condition: impl FnMut() -> bool) {
    let deadline = Instant::now() + timeout;
    while !condition() && Instant::now() < deadline {
        std::thread::sleep(Duration::from_millis(20));
    }
}

/// A case of the matrix, given the service under test.
type Case = fn(&Subject);

/// The matrix: name, case, and whether it is a long case, run only with
/// `--include-ignored`.
const CASES: &[(&str, Case, bool)] = &[
    ("freeze_and_fork", case_freeze_and_fork, false),
    (
        "sequential_children",
        |s| case_sequential_children(s, 5),
        false,
    ),
    ("live_siblings", |s| case_live_siblings(s, 3), false),
    ("chain", case_chain, false),
    ("freeze_mid_request", case_freeze_mid_request, false),
    ("kill_at_every_phase", case_kill_at_every_phase, false),
    (
        "sequential_children_long",
        |s| case_sequential_children(s, 2000),
        true,
    ),
    ("live_siblings_long", |s| case_live_siblings(s, 8), true),
];

fn main() {
    let args = libtest_mimic::Arguments::from_args();
    let mut trials = Vec::new();
    if std::env::var_os("SERVICECACHE_LIFECYCLE").is_some() {
        for manifest in manifests() {
            let Some(subject) = Subject::load(&manifest) else {
                eprintln!("skipped: {} has no adapter", manifest.display());
                continue;
            };
            let id = format!("{}::{}", subject.name, subject.manifest.service.version);
            for &(case, run, long) in CASES {
                let manifest = manifest.clone();
                let trial = libtest_mimic::Trial::test(format!("{id}::{case}"), move || {
                    let subject = Subject::load(&manifest).expect("the adapter was found");
                    run(&subject);
                    subject.report_timings(case);
                    Ok(())
                });
                trials.push(trial.with_ignored_flag(long));
            }
        }
    } else {
        eprintln!("skipped: set SERVICECACHE_LIFECYCLE=1 (make lifecycle-tests)");
    }
    libtest_mimic::run(&args, trials).exit();
}
