//! Every built service comes up through `servicecache serve`: a client
//! asks the HTTP API on the manager's Unix socket for an instance, the
//! adapter checks it answers initialized, and destroying it frees the
//! endpoint — once through the client library, once through `servicecache
//! request`. Generic cases cover the problem replies, renewal and expiry.
//! A trial per built service and case, discovered at run time
//! (`libtest-mimic`); services without an adapter get none.

#[path = "support/service_adapter.rs"]
mod service_adapter;

use std::{
    io::{BufRead as _, Write as _},
    net::TcpStream,
    path::{Path, PathBuf},
    sync::atomic::{AtomicUsize, Ordering},
    time::{Duration, Instant},
};

use service_adapter::ServiceAdapter;
use servicecache::{
    manifest::Manifest,
    serve::{
        api,
        client::{ApiError, Client},
    },
};

fn repo_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../..")
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

/// A `servicecache serve` process on its own socket, killed when dropped.
struct Serve {
    child: std::process::Child,
    socket: PathBuf,
    /// Collects the server's stderr when started capturing.
    logs: Option<std::thread::JoinHandle<String>>,
}

static NEXT_SOCKET: AtomicUsize = AtomicUsize::new(0);

impl Serve {
    fn start(services_dir: &Path) -> Self {
        Self::start_with(services_dir, false)
    }

    /// Starts a server whose stderr — its log — is collected for
    /// [`Serve::end_and_logs`].
    fn start_capturing_logs(services_dir: &Path) -> Self {
        Self::start_with(services_dir, true)
    }

    fn start_with(services_dir: &Path, capture_logs: bool) -> Self {
        Self::start_configured(services_dir, capture_logs, &[])
    }

    fn start_configured(services_dir: &Path, capture_logs: bool, extra_args: &[&str]) -> Self {
        let socket = std::env::temp_dir().join(format!(
            "sc-serve-{}-{}.sock",
            std::process::id(),
            NEXT_SOCKET.fetch_add(1, Ordering::Relaxed)
        ));
        let mut command = std::process::Command::new(env!("CARGO_BIN_EXE_servicecache"));
        command
            .arg("--services-dir")
            .arg(services_dir)
            .arg("--socket")
            .arg(&socket)
            .arg("serve")
            .args(extra_args)
            // The log level under test is serve's own default.
            .env_remove("SERVICECACHE_LOG")
            .stdin(std::process::Stdio::null())
            .stdout(std::process::Stdio::piped());
        if capture_logs {
            command.stderr(std::process::Stdio::piped());
        }
        let mut child = command.spawn().expect("spawn servicecache serve");
        // Drained on a thread so a chatty guest never fills the pipe.
        let logs = capture_logs.then(|| {
            let mut stderr = child.stderr.take().expect("stderr");
            std::thread::spawn(move || {
                let mut text = String::new();
                let _ = std::io::Read::read_to_string(&mut stderr, &mut text);
                text
            })
        });
        let mut ready = String::new();
        std::io::BufReader::new(child.stdout.take().expect("stdout"))
            .read_line(&mut ready)
            .expect("read the ready line");
        assert!(
            ready.starts_with("listening on "),
            "not a ready line: {ready:?}"
        );
        Self {
            child,
            socket,
            logs,
        }
    }

    fn client(&self) -> Client {
        Client::new(self.socket.clone()).expect("client")
    }

    /// Ends the server and returns everything it logged.
    fn end_and_logs(&mut self) -> String {
        let _ = self.child.kill();
        let _ = self.child.wait();
        self.logs
            .take()
            .expect("started capturing logs")
            .join()
            .expect("the log reader")
    }
}

impl Drop for Serve {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
        let _ = std::fs::remove_file(&self.socket);
    }
}

fn create_request(manifest: &Manifest, adapter: &ServiceAdapter) -> api::CreateInstance {
    api::CreateInstance {
        service: manifest.service.name.clone(),
        version: Some(manifest.service.version.clone()),
        recipe: manifest
            .initializer
            .as_ref()
            .map(|_| api::encode_recipe(&adapter.recipe())),
        ..api::CreateInstance::default()
    }
}

fn assert_refused(error: &anyhow::Error, status: u16, slug: &str) {
    let problem = &error
        .downcast_ref::<ApiError>()
        .unwrap_or_else(|| panic!("not a problem reply: {error:#}"))
        .0;
    assert_eq!(problem.status, status, "problem status: {problem:?}");
    assert!(problem.is(slug), "problem type: {problem:?}");
}

fn wait_refusing(endpoint: std::net::SocketAddr, what: &str) {
    let gone_by = Instant::now() + Duration::from_secs(10);
    while TcpStream::connect(endpoint).is_ok() {
        assert!(Instant::now() < gone_by, "{what} still accepts connections");
        std::thread::sleep(Duration::from_millis(100));
    }
}

/// An instance created over the API answers as initialized and is
/// listed; a second instance for the same recipe forks off the same
/// template, isolated from the first; deleting frees the endpoints and
/// forgets the ids.
fn serves_and_destroys(manifest_path: &Path) {
    let manifest = Manifest::load(manifest_path).expect("load the manifest");
    let name = manifest.service.name.clone();
    let Some(adapter) = ServiceAdapter::find(&repo_root(), &name) else {
        eprintln!("skipped: {name} has no adapter");
        return;
    };
    let serve = Serve::start(manifest_path.parent().and_then(Path::parent).expect("dir"));
    let client = serve.client();

    let listed = client.services().expect("list services");
    assert!(
        listed
            .iter()
            .any(|entry| entry.name == name && entry.version == manifest.service.version),
        "{name}: not in the service listing: {listed:?}"
    );

    let instance = client
        .create(&create_request(&manifest, &adapter))
        .expect("create");
    let endpoint = instance.endpoint.socket_addr().expect("endpoint");
    assert_eq!(instance.state, api::InstanceState::Running);
    adapter.check_initialized(endpoint);

    let polled = client.instance(&instance.id).expect("poll");
    assert_eq!(polled.state, api::InstanceState::Running);
    assert!(
        client
            .instances()
            .expect("list instances")
            .iter()
            .any(|listed| listed.id == instance.id),
        "{name}: not in the instance listing"
    );

    // A second instance for the same recipe: forked off the same
    // template, on its own endpoint, its state its own.
    let second = client
        .create(&create_request(&manifest, &adapter))
        .expect("second create");
    let second_endpoint = second.endpoint.socket_addr().expect("endpoint");
    assert_ne!(
        second_endpoint, endpoint,
        "{name}: the second instance shares the first's endpoint"
    );
    adapter.check_initialized(second_endpoint);
    adapter.diverge(endpoint, 1);
    adapter.diverge(second_endpoint, 2);
    adapter.check_diverged(endpoint, 1);
    adapter.check_diverged(second_endpoint, 2);

    client.delete(&second.id).expect("delete the second");
    wait_refusing(
        second_endpoint,
        &format!("{name}: the destroyed second instance"),
    );
    client.delete(&instance.id).expect("delete");
    wait_refusing(endpoint, &format!("{name}: the destroyed instance"));
    let error = client.instance(&instance.id).expect_err("the id is gone");
    assert_refused(&error, 404, "unknown-instance");
}

/// `servicecache request` prints the endpoint and holds the instance;
/// closing its stdin destroys the instance and ends the command.
fn runs_through_request_cli(manifest_path: &Path) {
    let manifest = Manifest::load(manifest_path).expect("load the manifest");
    let name = manifest.service.name.clone();
    let Some(adapter) = ServiceAdapter::find(&repo_root(), &name) else {
        eprintln!("skipped: {name} has no adapter");
        return;
    };
    let serve = Serve::start(manifest_path.parent().and_then(Path::parent).expect("dir"));

    let mut command = std::process::Command::new(env!("CARGO_BIN_EXE_servicecache"));
    command
        .arg("--socket")
        .arg(&serve.socket)
        .arg("request")
        .arg(format!("{name}@{}", manifest.service.version))
        .stdin(std::process::Stdio::piped())
        .stdout(std::process::Stdio::piped());
    let recipe_path = std::env::temp_dir().join(format!(
        "servicecache-request-recipe-{}-{name}-{}",
        std::process::id(),
        manifest.service.version
    ));
    if manifest.initializer.is_some() {
        std::fs::File::create(&recipe_path)
            .and_then(|mut file| file.write_all(&adapter.recipe()))
            .expect("write the recipe");
        command.arg("--recipe").arg(&recipe_path);
    }
    let mut child = command.spawn().expect("spawn servicecache request");

    let mut endpoint = String::new();
    std::io::BufReader::new(child.stdout.take().expect("stdout"))
        .read_line(&mut endpoint)
        .expect("read the endpoint");
    let endpoint: std::net::SocketAddr = endpoint
        .trim()
        .parse()
        .unwrap_or_else(|_| panic!("{name}: not an endpoint: {endpoint:?}"));
    adapter.check_initialized(endpoint);

    // Closing stdin ends the hold: the command destroys the instance and
    // exits cleanly.
    drop(child.stdin.take());
    let done_by = Instant::now() + Duration::from_secs(10);
    let status = loop {
        if let Some(status) = child.try_wait().expect("wait") {
            break status;
        }
        assert!(Instant::now() < done_by, "{name}: request did not end");
        std::thread::sleep(Duration::from_millis(100));
    };
    assert!(status.success(), "{name}: request ended with {status}");
    wait_refusing(endpoint, &format!("{name}: the released instance"));
    let _ = std::fs::remove_file(&recipe_path);
}

/// An empty services directory serves an empty list and refuses unknown
/// names with a problem body.
fn refuses_unknown_services() {
    let dir = std::env::temp_dir().join(format!("sc-serve-empty-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).expect("temp services dir");
    let serve = Serve::start(&dir);
    let client = serve.client();

    assert!(client.services().expect("list").is_empty());
    let error = client
        .create(&api::CreateInstance {
            service: "no-such-thing".to_string(),
            ..api::CreateInstance::default()
        })
        .expect_err("an unknown service is refused");
    assert_refused(&error, 404, "unknown-service");
    let _ = std::fs::remove_dir_all(&dir);
}

/// The second request for a service is served by a fork: the template
/// fills and freezes once, and every instance is forked off it. Uses the
/// first service without a prepare step, the cheapest to bring up.
fn second_request_is_a_fork() {
    let Some((manifest_path, manifest)) = manifests().into_iter().find_map(|path| {
        let manifest = Manifest::load(&path).expect("load the manifest");
        manifest.prepare.is_none().then_some((path, manifest))
    }) else {
        eprintln!("skipped: every built service has a prepare step");
        return;
    };
    let name = manifest.service.name.clone();
    let mut serve =
        Serve::start_capturing_logs(manifest_path.parent().and_then(Path::parent).expect("dir"));
    let client = serve.client();

    // No recipe: the instances fork straight off the base template.
    let request = api::CreateInstance {
        service: name.clone(),
        version: Some(manifest.service.version.clone()),
        ..api::CreateInstance::default()
    };
    let first = client.create(&request).expect("first create");
    let second = client.create(&request).expect("second create");
    let first_endpoint = first.endpoint.socket_addr().expect("endpoint");
    let second_endpoint = second.endpoint.socket_addr().expect("endpoint");
    assert_ne!(first_endpoint, second_endpoint);
    TcpStream::connect(first_endpoint).expect("connect to the first");
    TcpStream::connect(second_endpoint).expect("connect to the second");

    let logs = serve.end_and_logs();
    assert_eq!(
        logs.matches("template frozen").count(),
        1,
        "{name}: expected exactly one template fill in the log:\n{logs}"
    );
    assert_eq!(
        logs.matches("instance forked").count(),
        2,
        "{name}: expected both instances forked in the log:\n{logs}"
    );
}

/// A template with no live descendant expires after its TTL — its frozen
/// host exits — and the next request fills a fresh one. Uses the first
/// service without a prepare step, the cheapest to bring up.
fn idle_templates_expire() {
    let Some((manifest_path, manifest)) = manifests().into_iter().find_map(|path| {
        let manifest = Manifest::load(&path).expect("load the manifest");
        manifest.prepare.is_none().then_some((path, manifest))
    }) else {
        eprintln!("skipped: every built service has a prepare step");
        return;
    };
    let name = manifest.service.name.clone();
    let mut serve = Serve::start_configured(
        manifest_path.parent().and_then(Path::parent).expect("dir"),
        true,
        &["--template-ttl", "2"],
    );
    let client = serve.client();

    let request = api::CreateInstance {
        service: name.clone(),
        version: Some(manifest.service.version.clone()),
        ..api::CreateInstance::default()
    };
    let first = client.create(&request).expect("first create");
    client.delete(&first.id).expect("delete");

    // With its only instance gone the template idles out: TTL 2 s, the
    // owner checks each second.
    std::thread::sleep(Duration::from_secs(6));
    let second = client.create(&request).expect("create after the expiry");
    let endpoint = second.endpoint.socket_addr().expect("endpoint");
    TcpStream::connect(endpoint).expect("connect to the refilled template's instance");

    let logs = serve.end_and_logs();
    assert!(
        logs.contains("template expired"),
        "{name}: no expiry in the server's log:\n{logs}"
    );
    assert_eq!(
        logs.matches("template frozen").count(),
        2,
        "{name}: expected a second fill after the expiry:\n{logs}"
    );
}

/// Without `--recipe-root`, `recipe_files` is refused outright — before
/// the service is even looked up.
fn recipe_files_are_refused_without_roots() {
    let dir = std::env::temp_dir().join(format!("sc-serve-noroots-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).expect("temp services dir");
    let serve = Serve::start(&dir);
    let client = serve.client();

    let error = client
        .create(&api::CreateInstance {
            service: "anything".to_string(),
            recipe_files: vec!["/etc/hostname".to_string()],
            ..api::CreateInstance::default()
        })
        .expect_err("recipe files are refused");
    assert_refused(&error, 403, "recipe-files-refused");
    let _ = std::fs::remove_dir_all(&dir);
}

/// With a root configured, a file outside it is refused and one inside
/// it is read: an instance created from recipe files matches one created
/// from the same bytes inline — the log shows a single template fill.
fn recipe_files_feed_the_initializer() {
    let Some((manifest_path, manifest)) = manifests().into_iter().find_map(|path| {
        let manifest = Manifest::load(&path).expect("load the manifest");
        (manifest.prepare.is_none() && manifest.initializer.is_some()).then_some((path, manifest))
    }) else {
        eprintln!("skipped: no built service has an initializer without a prepare step");
        return;
    };
    let name = manifest.service.name.clone();
    let adapter = ServiceAdapter::find(&repo_root(), &name).expect("adapter");

    let root = std::env::temp_dir().join(format!("sc-serve-reciperoot-{}", std::process::id()));
    let outside = std::env::temp_dir().join(format!("sc-serve-outside-{}", std::process::id()));
    for dir in [&root, &outside] {
        let _ = std::fs::remove_dir_all(dir);
        std::fs::create_dir_all(dir).expect("temp dir");
    }
    let recipe = adapter.recipe();
    let inside_file = root.join("recipe.sql");
    let outside_file = outside.join("recipe.sql");
    std::fs::write(&inside_file, &recipe).expect("write the recipe");
    std::fs::write(&outside_file, &recipe).expect("write the recipe");

    let mut serve = Serve::start_configured(
        manifest_path.parent().and_then(Path::parent).expect("dir"),
        true,
        &["--recipe-root", root.to_str().expect("utf-8 path")],
    );
    let client = serve.client();
    let request = |recipe: Option<String>, files: Vec<String>| api::CreateInstance {
        service: name.clone(),
        version: Some(manifest.service.version.clone()),
        recipe,
        recipe_files: files,
        ..api::CreateInstance::default()
    };

    let error = client
        .create(&request(
            None,
            vec![outside_file.to_str().expect("utf-8 path").to_owned()],
        ))
        .expect_err("a file outside the root is refused");
    assert_refused(&error, 403, "recipe-files-refused");

    let inline = client
        .create(&request(Some(api::encode_recipe(&recipe)), Vec::new()))
        .expect("create from the inline recipe");
    adapter.check_initialized(inline.endpoint.socket_addr().expect("endpoint"));
    let from_files = client
        .create(&request(
            None,
            vec![inside_file.to_str().expect("utf-8 path").to_owned()],
        ))
        .expect("create from recipe files");
    adapter.check_initialized(from_files.endpoint.socket_addr().expect("endpoint"));

    // Same bytes, same template key: the log shows the base and one
    // recipe template filled, and both instances forked.
    let logs = serve.end_and_logs();
    assert_eq!(
        logs.matches("template frozen").count(),
        2,
        "{name}: expected one shared recipe template:\n{logs}"
    );
    assert_eq!(
        logs.matches("instance forked").count(),
        2,
        "{name}: expected both instances forked:\n{logs}"
    );
    for dir in [&root, &outside] {
        let _ = std::fs::remove_dir_all(dir);
    }
}

/// The server logs every request by default: method, path, status and
/// timing on stderr.
fn logs_every_request() {
    let dir = std::env::temp_dir().join(format!("sc-serve-logs-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).expect("temp services dir");
    let mut serve = Serve::start_capturing_logs(&dir);
    let client = serve.client();

    client.services().expect("list");
    client
        .instance("absent")
        .expect_err("an unknown id is refused");

    let logs = serve.end_and_logs();
    for expected in [
        "method=GET path=/v1/services status=200",
        "method=GET path=/v1/instances/absent status=404",
    ] {
        assert!(
            logs.contains(expected),
            "no {expected:?} in the server's log:\n{logs}"
        );
    }
    let _ = std::fs::remove_dir_all(&dir);
}

/// A renewed-down instance expires: the sweeper destroys it and its
/// endpoint closes. Uses the first service without a prepare step, the
/// cheapest to bring up; skipped when every built service has one.
fn expires_after_its_ttl() {
    let Some((manifest_path, manifest)) = manifests().into_iter().find_map(|path| {
        let manifest = Manifest::load(&path).expect("load the manifest");
        manifest.prepare.is_none().then_some((path, manifest))
    }) else {
        eprintln!("skipped: every built service has a prepare step");
        return;
    };
    let name = manifest.service.name.clone();
    if ServiceAdapter::find(&repo_root(), &name).is_none() {
        eprintln!("skipped: {name} has no adapter");
        return;
    }
    let serve = Serve::start(manifest_path.parent().and_then(Path::parent).expect("dir"));
    let client = serve.client();

    // No recipe: expiry does not need an initialized instance.
    let instance = client
        .create(&api::CreateInstance {
            service: name.clone(),
            version: Some(manifest.service.version.clone()),
            ttl_seconds: Some(60),
            ..api::CreateInstance::default()
        })
        .expect("create");
    let endpoint = instance.endpoint.socket_addr().expect("endpoint");
    assert!(instance.expires_in_seconds > 30, "the TTL was not applied");

    let renewed = client.renew(&instance.id, Some(2)).expect("renew");
    assert!(renewed.expires_in_seconds <= 2, "the renewal did not stick");

    let gone_by = Instant::now() + Duration::from_secs(30);
    loop {
        match client.instance(&instance.id) {
            Ok(_) => {
                assert!(
                    Instant::now() < gone_by,
                    "{name}: the instance never expired"
                );
                std::thread::sleep(Duration::from_millis(200));
            }
            Err(error) => {
                assert_refused(&error, 404, "unknown-instance");
                break;
            }
        }
    }
    wait_refusing(endpoint, &format!("{name}: the expired instance"));
}

/// A case, given the manifest of the service under test.
type Case = fn(&Path);

const CASES: &[(&str, Case)] = &[
    ("serves_and_destroys", serves_and_destroys),
    ("runs_through_request_cli", runs_through_request_cli),
];

fn main() {
    let args = libtest_mimic::Arguments::from_args();
    let mut trials = Vec::new();
    for manifest in manifests() {
        let service = Manifest::load(&manifest)
            .expect("load the manifest")
            .service;
        let (name, version) = (service.name, service.version);
        if ServiceAdapter::find(&repo_root(), &name).is_none() {
            eprintln!("skipped: {name} has no adapter");
            continue;
        }
        for &(case, run) in CASES {
            let manifest = manifest.clone();
            trials.push(libtest_mimic::Trial::test(
                format!("{name}::{version}::{case}"),
                move || {
                    run(&manifest);
                    Ok(())
                },
            ));
        }
    }
    trials.push(libtest_mimic::Trial::test(
        "refuses_unknown_services",
        || {
            refuses_unknown_services();
            Ok(())
        },
    ));
    trials.push(libtest_mimic::Trial::test("logs_every_request", || {
        logs_every_request();
        Ok(())
    }));
    trials.push(libtest_mimic::Trial::test(
        "second_request_is_a_fork",
        || {
            second_request_is_a_fork();
            Ok(())
        },
    ));
    trials.push(libtest_mimic::Trial::test("expires_after_its_ttl", || {
        expires_after_its_ttl();
        Ok(())
    }));
    trials.push(libtest_mimic::Trial::test("idle_templates_expire", || {
        idle_templates_expire();
        Ok(())
    }));
    trials.push(libtest_mimic::Trial::test(
        "recipe_files_are_refused_without_roots",
        || {
            recipe_files_are_refused_without_roots();
            Ok(())
        },
    ));
    trials.push(libtest_mimic::Trial::test(
        "recipe_files_feed_the_initializer",
        || {
            recipe_files_feed_the_initializer();
            Ok(())
        },
    ));
    libtest_mimic::run(&args, trials).exit();
}
