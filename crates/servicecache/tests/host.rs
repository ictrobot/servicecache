//! Every assembled service comes up through `servicecache host`: prepare,
//! start on a socket the manager passed, initialize with the recipe its
//! adapter provides, answer the adapter's check, stop — once driven from
//! this process, once through `servicecache run`, once forking a clone. A
//! trial per built service and case, discovered at run time
//! (`libtest-mimic`); services without an adapter get none.

#[path = "support/process.rs"]
mod process;
#[path = "support/service_adapter.rs"]
mod service_adapter;

use std::path::{Path, PathBuf};

use service_adapter::ServiceAdapter;
use servicecache::{manager::HostProcess, manifest::Manifest};

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

fn run_through_host(manifest_path: &Path) {
    let manifest = Manifest::load(manifest_path).expect("load the manifest");
    let name = manifest.service.name.clone();
    let Some(adapter) = ServiceAdapter::find(&repo_root(), &name) else {
        eprintln!("skipped: {name} has no adapter");
        return;
    };

    let binary = Path::new(env!("CARGO_BIN_EXE_servicecache"));
    let cache_dir =
        servicecache::cache::directory(None, std::env::var_os("SERVICECACHE_CACHE_DIR").as_deref())
            .expect("a cache directory");
    let mut host =
        HostProcess::spawn_with_binary(binary, manifest_path, &cache_dir).expect("spawn the host");
    if manifest.prepare.is_some() {
        assert_eq!(host.prepare().expect("prepare"), 0, "{name}: prepare");
    }
    let endpoint = host.start().expect("start");
    let expected = format!("servicecache instance {name}@{}", manifest.service.version);
    assert_eq!(
        process::title(host.pid()),
        format!("{expected} listening on {endpoint}"),
        "{name}: the host's title after start"
    );
    if manifest.initializer.is_some() {
        assert_eq!(
            host.initialize(&adapter.recipe()).expect("initialize"),
            0,
            "{name}: initializer"
        );
        let titled = process::title(host.pid());
        assert!(
            titled.starts_with(&format!("{expected} recipe "))
                && titled.ends_with(&format!(" listening on {endpoint}")),
            "{name}: the host's title after initialize: {titled:?}"
        );
    }
    adapter.check_initialized(endpoint);
    host.stop().expect("stop");
}

/// `servicecache run` brings the service up, prints its endpoint and keeps
/// serving until it is killed.
/// A spawned `servicecache run`, killed when dropped so that a failed
/// assertion leaves no host behind.
struct RunCommand(std::process::Child);

impl Drop for RunCommand {
    fn drop(&mut self) {
        let _ = self.0.kill();
        let _ = self.0.wait();
    }
}

fn run_through_cli(manifest_path: &Path) {
    use std::io::{BufRead as _, Write as _};

    let manifest = Manifest::load(manifest_path).expect("load the manifest");
    let name = manifest.service.name.clone();
    let Some(adapter) = ServiceAdapter::find(&repo_root(), &name) else {
        eprintln!("skipped: {name} has no adapter");
        return;
    };
    // Several versions of a service can be installed at once, so name the
    // exact one under test.
    let spec = format!("{name}@{}", manifest.service.version);
    let services_dir = manifest_path
        .parent()
        .and_then(Path::parent)
        .expect("the services directory");

    let mut command = std::process::Command::new(env!("CARGO_BIN_EXE_servicecache"));
    command
        .arg("--services-dir")
        .arg(services_dir)
        .arg("run")
        .arg(&spec)
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::piped());
    let recipe_path = std::env::temp_dir().join(format!(
        "servicecache-recipe-{}-{name}-{}",
        std::process::id(),
        manifest.service.version
    ));
    if manifest.initializer.is_some() {
        std::fs::File::create(&recipe_path)
            .and_then(|mut file| file.write_all(&adapter.recipe()))
            .expect("write the recipe");
        command.arg("--recipe").arg(&recipe_path);
    }
    let mut child = RunCommand(command.spawn().expect("spawn servicecache run"));

    let mut endpoint = String::new();
    std::io::BufReader::new(child.0.stdout.take().expect("stdout"))
        .read_line(&mut endpoint)
        .expect("read the endpoint");
    let endpoint: std::net::SocketAddr = endpoint
        .trim()
        .parse()
        .unwrap_or_else(|_| panic!("{name}: not an endpoint: {endpoint:?}"));
    adapter.check_initialized(endpoint);

    drop(child);
    let _ = std::fs::remove_file(&recipe_path);
}

/// `run --clones 1`, sent SIGUSR1 once the endpoint is out: the clone's
/// endpoint follows and answers as initialized; a connection opened to the
/// template before the freeze ends and its port refuses new ones; the
/// clone dies with the command.
fn fork_a_clone_through_cli(manifest_path: &Path) {
    use std::io::{BufRead as _, Write as _};

    let manifest = Manifest::load(manifest_path).expect("load the manifest");
    let name = manifest.service.name.clone();
    let Some(adapter) = ServiceAdapter::find(&repo_root(), &name) else {
        eprintln!("skipped: {name} has no adapter");
        return;
    };
    let spec = format!("{name}@{}", manifest.service.version);
    let services_dir = manifest_path
        .parent()
        .and_then(Path::parent)
        .expect("the services directory");

    let mut command = std::process::Command::new(env!("CARGO_BIN_EXE_servicecache"));
    command
        .arg("--services-dir")
        .arg(services_dir)
        .arg("run")
        .arg(&spec)
        .arg("--clones")
        .arg("1")
        .arg("--log")
        .arg("servicecache=info")
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped());
    let recipe_path = std::env::temp_dir().join(format!(
        "servicecache-clone-recipe-{}-{name}-{}",
        std::process::id(),
        manifest.service.version
    ));
    if manifest.initializer.is_some() {
        std::fs::File::create(&recipe_path)
            .and_then(|mut file| file.write_all(&adapter.recipe()))
            .expect("write the recipe");
        command.arg("--recipe").arg(&recipe_path);
    }
    let mut child = RunCommand(command.spawn().expect("spawn servicecache run"));
    let mut stdout = std::io::BufReader::new(child.0.stdout.take().expect("stdout"));
    // The hosts log to the command's stderr; drained on a thread so that
    // the guest's own output never fills the pipe.
    let mut stderr = child.0.stderr.take().expect("stderr");
    let logs = std::thread::spawn(move || {
        let mut text = String::new();
        let _ = std::io::Read::read_to_string(&mut stderr, &mut text);
        text
    });
    let read_endpoint = |stdout: &mut std::io::BufReader<std::process::ChildStdout>| {
        let mut line = String::new();
        stdout.read_line(&mut line).expect("read an endpoint");
        line.trim()
            .parse::<std::net::SocketAddr>()
            .unwrap_or_else(|_| panic!("{name}: not an endpoint: {line:?}"))
    };
    let endpoint = read_endpoint(&mut stdout);
    adapter.check_initialized(endpoint);
    let mut before_freeze =
        std::net::TcpStream::connect(endpoint).expect("connect to the template");
    before_freeze
        .set_read_timeout(Some(std::time::Duration::from_secs(5)))
        .expect("read timeout");

    let pid = nix::unistd::Pid::from_raw(i32::try_from(child.0.id()).expect("a pid"));
    nix::sys::signal::kill(pid, nix::sys::signal::Signal::SIGUSR1).expect("send SIGUSR1");
    let clone_endpoint = read_endpoint(&mut stdout);
    assert_ne!(
        clone_endpoint, endpoint,
        "{name}: the clone has its own endpoint"
    );
    adapter.check_initialized(clone_endpoint);

    // The template's connection ends (after whatever it had already sent)
    // and its port refuses: nothing waits on a frozen guest, and the clone
    // did not inherit the connection.
    let mut buffer = [0; 4096];
    loop {
        match std::io::Read::read(&mut before_freeze, &mut buffer) {
            Ok(0) | Err(_) => break,
            Ok(_) => {}
        }
    }
    assert!(
        std::net::TcpStream::connect(endpoint).is_err(),
        "{name}: the frozen template still accepts connections"
    );

    drop(child);
    let _ = std::fs::remove_file(&recipe_path);
    let logs = logs.join().expect("the log reader");
    for expected in ["host started", "frozen", "forked a clone", "clone running"] {
        assert!(
            logs.contains(expected),
            "{name}: no {expected:?} in the hosts' logs:\n{logs}"
        );
    }
    let gone_by = std::time::Instant::now() + std::time::Duration::from_secs(5);
    while std::net::TcpStream::connect(clone_endpoint).is_ok() {
        assert!(
            std::time::Instant::now() < gone_by,
            "{name}: the clone outlived the command"
        );
        std::thread::sleep(std::time::Duration::from_millis(100));
    }
}

/// The toolchain smoke fixture `netprobe.wasm` as a package of its own, in a
/// fresh directory named for `tag`: its manifest, or None when the fixture
/// is not built and the test is skipped.
fn netprobe_package(tag: &str) -> Option<PathBuf> {
    let fixture = repo_root().join("work/build/toolchain-smoke/netprobe.wasm");
    if !fixture.is_file() {
        eprintln!(
            "skipped: {} is not built (run `make smoke-toolchain`)",
            fixture.display()
        );
        return None;
    }
    let dir = std::env::temp_dir().join(format!(
        "servicecache-netprobe-{tag}-{}",
        std::process::id()
    ));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).expect("temp dir");
    // Copied, not symlinked: a manifest path must resolve inside the
    // package.
    std::fs::copy(&fixture, dir.join("netprobe.wasm")).expect("copy the fixture");
    std::fs::write(
        dir.join("service.toml"),
        "[service]\nname = \"netprobe\"\nversion = \"0\"\n\n[guest]\nmodule = \"netprobe.wasm\"\nargs = [\"4000\"]\nlisten_port = 4000\n",
    )
    .expect("write the manifest");
    Some(dir.join("service.toml"))
}

/// Spawns a host for `manifest` from the binary under test.
fn spawn_host(manifest: &Path) -> HostProcess {
    let binary = Path::new(env!("CARGO_BIN_EXE_servicecache"));
    let cache_dir =
        servicecache::cache::directory(None, std::env::var_os("SERVICECACHE_CACHE_DIR").as_deref())
            .expect("a cache directory");
    HostProcess::spawn_with_binary(binary, manifest, &cache_dir).expect("spawn the host")
}

/// A guest reads ports back the way it bound and the client connected
/// (wasix-libc probes the port byte order with a throwaway bind, which the
/// host must answer). Uses the toolchain smoke fixture `netprobe.wasm`.
fn guest_sees_correct_ports() {
    use std::io::Read as _;

    let Some(manifest) = netprobe_package("ports") else {
        return;
    };
    let dir = manifest.parent().expect("the package directory").to_owned();
    let mut host = spawn_host(&manifest);
    let endpoint = host.start().expect("start");

    let mut stream = std::net::TcpStream::connect(endpoint).expect("connect");
    let client_port = stream.local_addr().expect("local addr").port();
    let mut line = String::new();
    stream
        .read_to_string(&mut line)
        .expect("read the guest's report");
    assert_eq!(
        line.trim(),
        format!("local={} peer={client_port}", endpoint.port()),
        "the guest's view of the ports"
    );
    assert_eq!(host.wait_exit().expect("the guest exits"), 0);
    let _ = std::fs::remove_dir_all(&dir);
}

/// A clone forked from a guest frozen in a blocking `accept()` answers its
/// first connection at once. The clone resumes that accept on a thread and
/// a task of its own, so the listening socket has to wake whoever polled it
/// last rather than the template's task, which is gone. Uses `netprobe.wasm`,
/// which blocks in `accept()` as soon as it listens.
fn clone_answers_from_a_frozen_accept() {
    use std::io::Read as _;
    use std::time::{Duration, Instant};

    let Some(manifest) = netprobe_package("clone") else {
        return;
    };
    let dir = manifest.parent().expect("the package directory").to_owned();
    let mut template = spawn_host(&manifest);
    template.start().expect("start");
    // The guest is serving once start returns; give it the moment it needs
    // to get from listen() into accept(), so that the freeze finds it there.
    std::thread::sleep(Duration::from_millis(200));
    template.freeze().expect("freeze");
    let (mut clone, endpoint) = template.fork().expect("fork a clone");

    let asked = Instant::now();
    let mut stream = std::net::TcpStream::connect(endpoint).expect("connect to the clone");
    // A lost wakeup leaves the accept waiting for a timeout, or for ever;
    // the read gives up first, so the test fails rather than hangs.
    stream
        .set_read_timeout(Some(Duration::from_secs(10)))
        .expect("read timeout");
    let client_port = stream.local_addr().expect("local addr").port();
    let mut line = String::new();
    if let Err(error) = stream.read_to_string(&mut line) {
        panic!(
            "the clone did not answer its first connection in {:?}: {error}",
            asked.elapsed()
        );
    }
    let waited = asked.elapsed();
    assert_eq!(
        line.trim(),
        format!("local={} peer={client_port}", endpoint.port()),
        "the clone's report"
    );
    assert!(
        waited < Duration::from_secs(5),
        "the clone answered its first connection after {waited:?}"
    );
    assert_eq!(clone.wait_exit().expect("the clone's guest exits"), 0);
    let _ = std::fs::remove_dir_all(&dir);
}

/// A case, given the manifest of the service under test.
type Case = fn(&Path);

const CASES: &[(&str, Case)] = &[
    ("comes_up_through_the_host", run_through_host),
    ("runs_through_the_cli", run_through_cli),
    ("forks_a_clone_through_the_cli", fork_a_clone_through_cli),
];

/// The linker gates extensions: a module importing `ictrobot_shm_v1` only
/// instantiates when the manifest declares the namespace. The demo runs in
/// child mode with no object created for it, so with the declaration it
/// instantiates and exits 1 from `shm_open`; without it, it never links.
/// The full exchange runs under the extension smoke's CLI.
fn extension_declarations_gate_instantiation(declare: bool) {
    let demo =
        repo_root().join("work/build/extension-smoke/ictrobot_shm_v1/ictrobot-shm-demo.wasm");
    if !demo.is_file() {
        eprintln!(
            "skipped: the extension demo is not built (run `make smoke-extension-ictrobot_shm_v1`)"
        );
        return;
    }
    let dir = std::env::temp_dir().join(format!(
        "servicecache-extension-gate-{}-{declare}",
        std::process::id()
    ));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).expect("test package dir");
    std::fs::copy(&demo, dir.join("ictrobot-shm-demo.wasm")).expect("copy the demo");
    let extensions = if declare {
        "\nextensions = [\"ictrobot_shm_v1\"]"
    } else {
        ""
    };
    std::fs::write(
        dir.join("service.toml"),
        format!(
            r#"[service]
name = "extension-gate"
version = "1"{extensions}

[prepare]
module = "ictrobot-shm-demo.wasm"
args = ["--child"]

[guest]
module = "ictrobot-shm-demo.wasm"
listen_port = 1234
"#
        ),
    )
    .expect("write the manifest");

    let binary = Path::new(env!("CARGO_BIN_EXE_servicecache"));
    let cache_dir =
        servicecache::cache::directory(None, std::env::var_os("SERVICECACHE_CACHE_DIR").as_deref())
            .expect("a cache directory");
    let mut host = HostProcess::spawn_with_binary(binary, &dir.join("service.toml"), &cache_dir)
        .expect("spawn the host");
    let outcome = host.prepare();
    let _ = host.stop();
    let _ = std::fs::remove_dir_all(&dir);
    if declare {
        // Exit 1 from the demo's own shm_open failure: it instantiated and
        // ran, which is what the declaration grants.
        assert_eq!(outcome.expect("prepare with the declaration"), 1);
    } else {
        match outcome {
            Err(error) => assert!(error.to_string().contains("ictrobot_shm_v1"), "{error}"),
            Ok(code) => assert_ne!(code, 0, "an undeclared extension import must fail"),
        }
    }
}

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
        "guest_sees_correct_ports",
        || {
            guest_sees_correct_ports();
            Ok(())
        },
    ));
    trials.push(libtest_mimic::Trial::test(
        "clone_answers_from_a_frozen_accept",
        || {
            clone_answers_from_a_frozen_accept();
            Ok(())
        },
    ));
    trials.push(libtest_mimic::Trial::test(
        "extension_gate::undeclared_import_fails",
        || {
            extension_declarations_gate_instantiation(false);
            Ok(())
        },
    ));
    trials.push(libtest_mimic::Trial::test(
        "extension_gate::declared_import_instantiates",
        || {
            extension_declarations_gate_instantiation(true);
            Ok(())
        },
    ));
    libtest_mimic::run(&args, trials).exit();
}
