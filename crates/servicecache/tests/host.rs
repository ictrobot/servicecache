//! Every assembled service comes up through `servicecache host`: prepare,
//! start on a socket the manager passed, initialize with the recipe its
//! adapter provides, answer the adapter's check, stop — once driven from
//! this process, once through `servicecache run`. Skipped for services that
//! are not built or have no adapter.

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
    if manifest.initializer.is_some() {
        assert_eq!(
            host.initialize(&adapter.recipe()).expect("initialize"),
            0,
            "{name}: initializer"
        );
    }
    adapter.check_initialized(endpoint);
    host.stop().expect("stop");
}

#[test]
fn every_built_service_comes_up_through_the_host() {
    for manifest in manifests() {
        run_through_host(&manifest);
    }
}

/// `servicecache run` brings the service up, prints its endpoint and keeps
/// serving until it is killed.
fn run_through_cli(manifest_path: &Path) {
    use std::io::{BufRead as _, Write as _};

    let manifest = Manifest::load(manifest_path).expect("load the manifest");
    let name = manifest.service.name.clone();
    let Some(adapter) = ServiceAdapter::find(&repo_root(), &name) else {
        eprintln!("skipped: {name} has no adapter");
        return;
    };
    let services_dir = manifest_path
        .parent()
        .and_then(Path::parent)
        .expect("the services directory");

    let mut command = std::process::Command::new(env!("CARGO_BIN_EXE_servicecache"));
    command
        .arg("--services-dir")
        .arg(services_dir)
        .arg("run")
        .arg(&name)
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::piped());
    let recipe_path =
        std::env::temp_dir().join(format!("servicecache-recipe-{}", std::process::id()));
    if manifest.initializer.is_some() {
        std::fs::File::create(&recipe_path)
            .and_then(|mut file| file.write_all(&adapter.recipe()))
            .expect("write the recipe");
        command.arg("--recipe").arg(&recipe_path);
    }
    let mut child = command.spawn().expect("spawn servicecache run");

    let mut endpoint = String::new();
    std::io::BufReader::new(child.stdout.take().expect("stdout"))
        .read_line(&mut endpoint)
        .expect("read the endpoint");
    let endpoint: std::net::SocketAddr = endpoint
        .trim()
        .parse()
        .unwrap_or_else(|_| panic!("{name}: not an endpoint: {endpoint:?}"));
    adapter.check_initialized(endpoint);

    child.kill().expect("kill");
    child.wait().expect("wait");
    let _ = std::fs::remove_file(&recipe_path);
}

#[test]
fn every_built_service_runs_through_the_cli() {
    for manifest in manifests() {
        run_through_cli(&manifest);
    }
}

/// `run --clones 1`, sent SIGUSR1 once the endpoint is out: the clone's
/// endpoint follows and answers as initialized, and the clone dies with
/// the command.
fn fork_a_clone_through_cli(manifest_path: &Path) {
    use std::io::{BufRead as _, Write as _};

    let manifest = Manifest::load(manifest_path).expect("load the manifest");
    let name = manifest.service.name.clone();
    let Some(adapter) = ServiceAdapter::find(&repo_root(), &name) else {
        eprintln!("skipped: {name} has no adapter");
        return;
    };
    let services_dir = manifest_path
        .parent()
        .and_then(Path::parent)
        .expect("the services directory");

    let mut command = std::process::Command::new(env!("CARGO_BIN_EXE_servicecache"));
    command
        .arg("--services-dir")
        .arg(services_dir)
        .arg("run")
        .arg(&name)
        .arg("--clones")
        .arg("1")
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::piped());
    let recipe_path =
        std::env::temp_dir().join(format!("servicecache-clone-recipe-{}", std::process::id()));
    if manifest.initializer.is_some() {
        std::fs::File::create(&recipe_path)
            .and_then(|mut file| file.write_all(&adapter.recipe()))
            .expect("write the recipe");
        command.arg("--recipe").arg(&recipe_path);
    }
    let mut child = command.spawn().expect("spawn servicecache run");
    let mut stdout = std::io::BufReader::new(child.stdout.take().expect("stdout"));
    let read_endpoint = |stdout: &mut std::io::BufReader<std::process::ChildStdout>| {
        let mut line = String::new();
        stdout.read_line(&mut line).expect("read an endpoint");
        line.trim()
            .parse::<std::net::SocketAddr>()
            .unwrap_or_else(|_| panic!("{name}: not an endpoint: {line:?}"))
    };
    let endpoint = read_endpoint(&mut stdout);
    adapter.check_initialized(endpoint);

    let pid = nix::unistd::Pid::from_raw(i32::try_from(child.id()).expect("a pid"));
    nix::sys::signal::kill(pid, nix::sys::signal::Signal::SIGUSR1).expect("send SIGUSR1");
    let clone_endpoint = read_endpoint(&mut stdout);
    assert_ne!(
        clone_endpoint, endpoint,
        "{name}: the clone has its own endpoint"
    );
    adapter.check_initialized(clone_endpoint);

    child.kill().expect("kill");
    child.wait().expect("wait");
    let _ = std::fs::remove_file(&recipe_path);
    let gone_by = std::time::Instant::now() + std::time::Duration::from_secs(5);
    while std::net::TcpStream::connect(clone_endpoint).is_ok() {
        assert!(
            std::time::Instant::now() < gone_by,
            "{name}: the clone outlived the command"
        );
        std::thread::sleep(std::time::Duration::from_millis(100));
    }
}

#[test]
fn every_built_service_forks_a_clone_through_the_cli() {
    for manifest in manifests() {
        fork_a_clone_through_cli(&manifest);
    }
}

/// A guest reads ports back the way it bound and the client connected
/// (wasix-libc probes the port byte order with a throwaway bind, which the
/// host must answer). Uses the toolchain smoke fixture `netprobe.wasm`.
#[test]
fn guest_sees_correct_ports() {
    use std::io::Read as _;

    let fixture = repo_root().join("work/build/toolchain-smoke/netprobe.wasm");
    if !fixture.is_file() {
        eprintln!(
            "skipped: {} is not built (run `make smoke-toolchain`)",
            fixture.display()
        );
        return;
    }
    let dir = std::env::temp_dir().join(format!("servicecache-netprobe-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).expect("temp dir");
    std::os::unix::fs::symlink(&fixture, dir.join("netprobe.wasm")).expect("symlink the fixture");
    std::fs::write(
        dir.join("service.toml"),
        "[service]\nname = \"netprobe\"\nversion = \"0\"\n\n[guest]\nmodule = \"netprobe.wasm\"\nargs = [\"4000\"]\nlisten_port = 4000\n",
    )
    .expect("write the manifest");

    let binary = Path::new(env!("CARGO_BIN_EXE_servicecache"));
    let cache_dir =
        servicecache::cache::directory(None, std::env::var_os("SERVICECACHE_CACHE_DIR").as_deref())
            .expect("a cache directory");
    let mut host = HostProcess::spawn_with_binary(binary, &dir.join("service.toml"), &cache_dir)
        .expect("spawn the host");
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
