use std::{
    env,
    ffi::{OsStr, OsString},
    io::{BufRead as _, IsTerminal as _, Read as _, Write as _},
    os::fd::AsFd as _,
    path::{Path, PathBuf},
    time::{Duration, Instant},
};

use anyhow::{Context, Result, bail};
use clap::{Parser, Subcommand};
use nix::{
    poll::{PollFd, PollFlags, PollTimeout, poll},
    sys::{
        signal::{SigSet, SigmaskHow, Signal, pthread_sigmask},
        signalfd::{SfdFlags, SignalFd},
    },
};

use crate::{
    cache::{self, ModuleCache},
    discovery::{SelectError, ServiceIndex},
    host::protocol::{Reply, Run},
    manager::HostProcess,
    manifest::Manifest,
    runtime::Runtime,
    serve::{
        api,
        client::{ApiError, Client},
    },
};

const SYSTEM_DEFAULTS: [&str; 2] = [
    "/usr/local/share/servicecache/services",
    "/usr/share/servicecache/services",
];

#[derive(Debug, Parser)]
#[command(version, about)]
struct Cli {
    /// Replace the service search path. May be repeated.
    #[arg(long, value_name = "DIR", global = true)]
    services_dir: Vec<PathBuf>,

    /// Where compiled modules are cached (default: ~/.cache/servicecache).
    #[arg(long, value_name = "DIR", global = true)]
    cache_dir: Option<PathBuf>,

    /// The manager's Unix socket
    /// (default: $XDG_RUNTIME_DIR/servicecache/serve.sock).
    #[allow(clippy::doc_markdown)] // clap shows this text as is
    #[arg(long, value_name = "PATH", global = true)]
    socket: Option<PathBuf>,

    /// Log more, to stderr; repeat for more
    #[arg(short, long, action = clap::ArgAction::Count, global = true)]
    verbose: u8,

    /// Log filter directives, such as "warn,servicecache=debug".
    /// Overrides -v and the variable SERVICECACHE_LOG.
    #[allow(clippy::doc_markdown)] // clap shows this text as is
    #[arg(long, value_name = "DIRECTIVES", global = true)]
    log: Option<String>,

    #[command(subcommand)]
    command: Command,
}

#[derive(Debug, Subcommand)]
enum Command {
    /// Serve the manager's HTTP API on a Unix socket.
    Serve {
        /// Accept `recipe_files` in requests, for files under DIR, from
        /// connections by this user. May be repeated. Off by default; no
        /// environment variable on purpose, so the opt-in is always
        /// visible in the command line.
        #[arg(long = "recipe-root", value_name = "DIR")]
        recipe_roots: Vec<PathBuf>,
        /// Seconds an idle template lives (a testing hook; the default is
        /// the policy).
        #[arg(long, value_name = "SECONDS", hide = true)]
        template_ttl: Option<u64>,
    },
    /// Ask a serving manager for an instance and hold it: prints the
    /// endpoint, renews the instance until stdin closes or SIGINT/SIGTERM,
    /// then destroys it.
    Request {
        /// The service, as `name` or `name@version`.
        service: String,
        /// The initializer's stdin, a file or `-` for standard input.
        /// Without it the initializer does not run.
        #[arg(long, value_name = "FILE")]
        recipe: Option<PathBuf>,
    },
    /// Run one service and print its endpoint; runs until the service
    /// exits.
    Run {
        /// The service, as `name` or `name@version`.
        service: String,
        /// The initializer's stdin, a file or `-` for standard input.
        /// Without it the initializer does not run.
        #[arg(long, value_name = "FILE")]
        recipe: Option<PathBuf>,
        /// Wait for Enter on the terminal, or SIGUSR1, then freeze the
        /// service and fork this many clones, printing their endpoints;
        /// each further one forks as many again. Runs until the last
        /// clone exits.
        #[arg(long, value_name = "N")]
        clones: Option<std::num::NonZeroUsize>,
    },
    /// Inspect installed service packages.
    Services {
        #[command(subcommand)]
        command: ServicesCommand,
    },
    /// Manage the cache of compiled modules.
    Cache {
        #[command(subcommand)]
        command: CacheCommand,
    },
    /// Run one guest, driven by the manager over an inherited control
    /// channel (internal).
    #[command(hide = true)]
    Host {
        /// The service manifest to run.
        #[arg(long, value_name = "FILE")]
        manifest: PathBuf,
        /// The descriptor of the control channel.
        #[arg(long, value_name = "FD")]
        control_fd: i32,
    },
}

#[derive(Debug, Subcommand)]
enum ServicesCommand {
    /// List discovered service packages and their content digests.
    List,
    /// Load every discovered module with the embedded runtime.
    Check,
}

#[derive(Debug, Subcommand)]
enum CacheCommand {
    /// Remove the cache directory and everything in it.
    Clean,
}

/// Parse command-line arguments and run the requested command.
///
/// # Errors
///
/// Returns an error when service discovery, hashing, or module loading fails.
pub fn run() -> Result<()> {
    run_with(
        Cli::parse(),
        env::var_os("SERVICECACHE_SERVICES_DIR"),
        env::var_os("SERVICECACHE_CACHE_DIR").as_deref(),
        env::var_os("SERVICECACHE_SOCKET"),
    )
}

fn run_with(
    cli: Cli,
    environment_dirs: Option<OsString>,
    environment_cache: Option<&OsStr>,
    environment_socket: Option<OsString>,
) -> Result<()> {
    // A server prints its request log by default: `serve` starts at `-v`
    // unless a filter was chosen (`--log`, `-v`, `SERVICECACHE_LOG`).
    let verbose = if matches!(cli.command, Command::Serve { .. })
        && cli.verbose == 0
        && cli.log.is_none()
        && env::var_os("SERVICECACHE_LOG").is_none()
    {
        1
    } else {
        cli.verbose
    };
    crate::logging::init(verbose, cli.log.as_deref())?;
    let cache_dir = || cache::directory(cli.cache_dir.as_deref(), environment_cache);
    let socket = move || socket_path(cli.socket, environment_socket);
    match cli.command {
        Command::Serve {
            recipe_roots,
            template_ttl,
        } => {
            let search_dirs = service_dirs(cli.services_dir, environment_dirs);
            let services = ServiceIndex::discover(&search_dirs)?;
            crate::serve::run(crate::serve::Options {
                socket: socket(),
                services,
                cache_dir: cache_dir()?,
                template_ttl: template_ttl
                    .map_or(crate::serve::DEFAULT_TEMPLATE_TTL, Duration::from_secs),
                recipe_roots,
            })
        }
        Command::Request { service, recipe } => {
            let client = Client::new(socket())?;
            let recipe = recipe.map(|path| read_recipe(&path)).transpose()?;
            request_instance(&client, &service, recipe.as_deref())
        }
        Command::Run {
            service,
            recipe,
            clones,
        } => {
            let search_dirs = service_dirs(cli.services_dir, environment_dirs);
            let services = ServiceIndex::discover(&search_dirs)?;
            let manifest = find_service(&services, &service)?;
            let recipe = recipe.map(|path| read_recipe(&path)).transpose()?;
            run_service(
                manifest,
                recipe.as_deref(),
                &cache_dir()?,
                clones.map(std::num::NonZeroUsize::get),
            )
        }
        Command::Services { command } => {
            let search_dirs = service_dirs(cli.services_dir, environment_dirs);
            let services = ServiceIndex::discover(&search_dirs)?;
            match command {
                ServicesCommand::List => print_services(&services),
                ServicesCommand::Check => {
                    let runtime = Runtime::new().with_cache(ModuleCache::new(cache_dir()?));
                    check_services(&services, &runtime)
                }
            }
        }
        Command::Cache { command } => match command {
            CacheCommand::Clean => {
                let dir = cache_dir()?;
                if cache::clean(&dir)? {
                    println!("removed {}", dir.display());
                } else {
                    println!("nothing to remove at {}", dir.display());
                }
                Ok(())
            }
        },
        Command::Host {
            manifest,
            control_fd,
        } => crate::host::run(&crate::host::HostArgs {
            manifest,
            control_fd,
            cache_dir: cache_dir()?,
        }),
    }
}

fn service_dirs(flag_dirs: Vec<PathBuf>, environment_dirs: Option<OsString>) -> Vec<PathBuf> {
    if !flag_dirs.is_empty() {
        return flag_dirs;
    }
    if let Some(value) = environment_dirs {
        return env::split_paths(&value)
            .filter(|path| !path.as_os_str().is_empty())
            .collect();
    }

    let mut defaults = Vec::with_capacity(3);
    if let Some(home) = env::var_os("HOME") {
        defaults.push(
            PathBuf::from(home)
                .join(".local")
                .join("share")
                .join("servicecache")
                .join("services"),
        );
    }
    defaults.extend(SYSTEM_DEFAULTS.map(PathBuf::from));
    defaults
}

fn print_services(services: &ServiceIndex) -> Result<()> {
    for package in services.iter() {
        println!(
            "{} {} {}",
            package.manifest.service.name,
            package.manifest.service.version,
            package.manifest.directory().display()
        );
        for file in package.files()? {
            println!("  {}  {}", file.sha256, file.path.display());
        }
        for shadow in &package.shadowed {
            println!("  shadowed {}", shadow.directory.display());
            for file in shadow.files()? {
                println!("    {}  {}", file.sha256, file.path.display());
            }
        }
    }
    Ok(())
}

/// A `name` or `name@version` argument, split.
fn split_service(service: &str) -> (&str, Option<&str>) {
    match service.split_once('@') {
        Some((name, version)) => (name, Some(version)),
        None => (service, None),
    }
}

/// The manifest for `name` or `name@version`; the name alone selects the
/// only installed version.
fn find_service<'a>(services: &'a ServiceIndex, service: &str) -> Result<&'a Manifest> {
    let (name, version) = split_service(service);
    services.select(name, version).map_err(|error| match error {
        SelectError::NotFound => anyhow::anyhow!("no installed service matches {service}"),
        SelectError::Ambiguous(versions) => anyhow::anyhow!(
            "{name} is installed in several versions ({}); name one as {name}@<version>",
            versions.join(", ")
        ),
    })
}

/// The manager's socket: flag, then environment, then the runtime
/// directory, then a per-user path under the system temp directory.
fn socket_path(flag: Option<PathBuf>, environment: Option<OsString>) -> PathBuf {
    if let Some(path) = flag {
        return path;
    }
    if let Some(value) = environment
        && !value.is_empty()
    {
        return PathBuf::from(value);
    }
    if let Some(runtime_dir) = env::var_os("XDG_RUNTIME_DIR")
        && !runtime_dir.is_empty()
    {
        return PathBuf::from(runtime_dir)
            .join("servicecache")
            .join("serve.sock");
    }
    env::temp_dir()
        .join(format!("servicecache-{}", unsafe { libc::getuid() }))
        .join("serve.sock")
}

fn read_recipe(path: &Path) -> Result<Vec<u8>> {
    if path.as_os_str() == "-" {
        let mut recipe = Vec::new();
        std::io::stdin()
            .read_to_end(&mut recipe)
            .context("failed to read the recipe from standard input")?;
        return Ok(recipe);
    }
    std::fs::read(path).with_context(|| format!("failed to read the recipe {}", path.display()))
}

/// Brings a service up in a host — prepare, start, the initializer when a
/// recipe was given — prints its endpoint, and waits for the guest to exit.
fn run_service(
    manifest: &Manifest,
    recipe: Option<&[u8]>,
    cache_dir: &Path,
    clones: Option<usize>,
) -> Result<()> {
    // Taken before anything is printed, so a SIGUSR1 sent as soon as the
    // endpoint appears is queued rather than fatal.
    let mut signals = clones.map(|_| fork_signal()).transpose()?;
    let manifest_path = manifest.directory().join("service.toml");
    let mut host = HostProcess::spawn(&manifest_path, cache_dir)?;
    if manifest.prepare.is_some() {
        let status = host.prepare()?;
        if status != 0 {
            bail!("the prepare step exited with status {status}");
        }
    }
    let endpoint = host.start()?;
    match (recipe, manifest.initializer.is_some()) {
        (Some(recipe), true) => {
            let status = host.initialize(recipe)?;
            if status != 0 {
                bail!("the initializer exited with status {status}");
            }
        }
        (Some(_), false) => bail!(
            "{} has no initializer to give the recipe to",
            manifest.service.name
        ),
        (None, true) => eprintln!("no --recipe: the initializer was not run"),
        (None, false) => {}
    }
    // The bare endpoint on stdout for scripts, and a labelled line on
    // stderr, where the guest's own output goes, so it stands out there.
    println!("{endpoint}");
    std::io::stdout()
        .flush()
        .context("failed to write the endpoint")?;
    let mut banner = Lines::new();
    banner.line("").line(format_args!(
        "==> {} is listening on host port {} ({endpoint}; guest port {}). Ctrl-C to stop.",
        manifest.service.name,
        endpoint.port(),
        manifest.guest.listen_port
    ));
    if let Some(count) = clones {
        banner.line(format_args!(
            "==> Enter here, or `kill -USR1 {}`, freezes it and forks {count} clone{}.",
            std::process::id(),
            if count == 1 { "" } else { "s" }
        ));
    }
    banner.line("");
    drop(banner);

    let status = match (clones, signals.as_mut()) {
        (Some(count), Some(signals)) => run_with_clones(&mut host, count, signals)?,
        _ => host.wait_exit()?,
    };
    if status != 0 {
        bail!("{} exited with status {status}", manifest.service.name);
    }
    Ok(())
}

/// Lines for stderr, collected and written in one call when dropped, so
/// that a group of them never interleaves with what a host writes there at
/// the same time.
struct Lines(String);

impl Lines {
    fn new() -> Self {
        Self(String::new())
    }

    fn line(&mut self, line: impl std::fmt::Display) -> &mut Self {
        use std::fmt::Write as _;
        let _ = writeln!(self.0, "{line}");
        self
    }
}

impl Drop for Lines {
    fn drop(&mut self) {
        let mut stderr = std::io::stderr().lock();
        let _ = stderr.write_all(self.0.as_bytes());
        let _ = stderr.flush();
    }
}

/// A descriptor SIGUSR1 can be read from, the signal blocked so that it
/// goes there.
fn fork_signal() -> Result<SignalFd> {
    let mut mask = SigSet::empty();
    mask.add(Signal::SIGUSR1);
    pthread_sigmask(SigmaskHow::SIG_BLOCK, Some(&mask), None).context("failed to block SIGUSR1")?;
    SignalFd::with_flags(&mask, SfdFlags::SFD_CLOEXEC).context("failed to open a signal descriptor")
}

/// A descriptor SIGINT and SIGTERM can be read from, the signals blocked
/// so that they go there.
fn end_signals() -> Result<SignalFd> {
    let mut mask = SigSet::empty();
    mask.add(Signal::SIGINT);
    mask.add(Signal::SIGTERM);
    pthread_sigmask(SigmaskHow::SIG_BLOCK, Some(&mask), None)
        .context("failed to block SIGINT and SIGTERM")?;
    SignalFd::with_flags(&mask, SfdFlags::SFD_CLOEXEC).context("failed to open a signal descriptor")
}

/// The lease `request` asks for: short, because it renews often — an
/// instance whose holder dies is gone within half a minute.
const REQUEST_TTL: Duration = Duration::from_secs(30);
/// How often `request` renews its instance.
const REQUEST_RENEW_INTERVAL: Duration = Duration::from_secs(10);

/// Asks the serving manager for an instance, prints its endpoint, and
/// holds it — renewing on a timer — until stdin closes or SIGINT/SIGTERM,
/// then destroys it.
fn request_instance(client: &Client, service: &str, recipe: Option<&[u8]>) -> Result<()> {
    // Taken before the request so an early signal is queued, not fatal.
    let mut signals = end_signals()?;
    let (name, version) = split_service(service);
    let instance = client.create(&api::CreateInstance {
        service: name.to_string(),
        version: version.map(str::to_string),
        recipe: recipe.map(api::encode_recipe),
        recipe_files: Vec::new(),
        ttl_seconds: Some(REQUEST_TTL.as_secs()),
    })?;
    let endpoint = instance
        .endpoint
        .socket_addr()
        .context("bad endpoint from the manager")?;

    println!("{endpoint}");
    std::io::stdout()
        .flush()
        .context("failed to write the endpoint")?;
    let mut banner = Lines::new();
    banner
        .line("")
        .line(format_args!(
            "==> instance {} of {} {} is listening on {endpoint}.",
            instance.id, instance.service, instance.version
        ))
        .line("==> Held and renewed until stdin closes or Ctrl-C, then destroyed.")
        .line("");
    drop(banner);

    match hold_instance(client, &instance, &mut signals)? {
        HoldEnd::Exited(status) => {
            client.delete(&instance.id).ok();
            bail!(
                "the {} instance exited with status {}",
                instance.service,
                status.map_or_else(|| "unknown".to_string(), |status| status.to_string())
            );
        }
        HoldEnd::Released => client
            .delete(&instance.id)
            .context("failed to destroy the instance"),
    }
}

/// How a held instance's stay ended.
enum HoldEnd {
    /// stdin closed or SIGINT/SIGTERM arrived.
    Released,
    /// The guest exited, with its status when the manager knew it.
    Exited(Option<i32>),
}

/// Renews `instance` every [`REQUEST_RENEW_INTERVAL`] until stdin closes,
/// a signal arrives, or the guest exits.
fn hold_instance(
    client: &Client,
    instance: &api::Instance,
    signals: &mut SignalFd,
) -> Result<HoldEnd> {
    let stdin = std::io::stdin();
    let timeout = PollTimeout::try_from(REQUEST_RENEW_INTERVAL).unwrap_or(PollTimeout::MAX);
    loop {
        let (renewed, signal_ready, stdin_ready) = {
            let mut fds = [
                PollFd::new(signals.as_fd(), PollFlags::POLLIN),
                PollFd::new(stdin.as_fd(), PollFlags::POLLIN),
            ];
            let count = match poll(&mut fds, timeout) {
                Ok(count) => count,
                Err(nix::errno::Errno::EINTR) => continue,
                Err(error) => return Err(error).context("poll failed"),
            };
            let ready = |fd: &PollFd| fd.revents().is_some_and(|events| !events.is_empty());
            (count == 0, ready(&fds[0]), ready(&fds[1]))
        };

        if renewed {
            if let Err(error) = client.renew(&instance.id, None) {
                // Renewal refused: the guest exited, or the instance is
                // gone; report which.
                if error.downcast_ref::<ApiError>().is_none() {
                    return Err(error).context("failed to renew the instance");
                }
                if let Ok(current) = client.instance(&instance.id)
                    && current.state == api::InstanceState::Exited
                {
                    return Ok(HoldEnd::Exited(current.exit_status));
                }
                return Err(error).context("failed to renew the instance");
            }
            continue;
        }
        if signal_ready {
            signals.read_signal().context("failed to read the signal")?;
            return Ok(HoldEnd::Released);
        }
        if stdin_ready {
            let mut line = String::new();
            if stdin
                .lock()
                .read_line(&mut line)
                .context("failed to read stdin")?
                == 0
            {
                return Ok(HoldEnd::Released);
            }
            // Lines on stdin are ignored; only its end matters.
        }
    }
}

/// Serves `template`, freezing it and forking `count` clones each time a
/// line arrives on a terminal stdin or a signal on `signals`; the clones'
/// endpoints go to stdout. Runs until the guest exits, or once frozen
/// until the last clone has: the exit status, non-zero if any clone's was.
fn run_with_clones(
    template: &mut HostProcess,
    count: usize,
    signals: &mut SignalFd,
) -> Result<i32> {
    let stdin = std::io::stdin();
    let mut terminal = stdin.is_terminal();
    let mut clones: Vec<HostProcess> = Vec::new();
    let mut frozen = false;
    let mut clone_failed = false;
    loop {
        let (template_ready, signal_ready, stdin_ready) = {
            let mut fds = vec![
                PollFd::new(template.as_fd(), PollFlags::POLLIN),
                PollFd::new(signals.as_fd(), PollFlags::POLLIN),
            ];
            if terminal {
                fds.push(PollFd::new(stdin.as_fd(), PollFlags::POLLIN));
            }
            match poll(&mut fds, PollTimeout::NONE) {
                Ok(_) => {}
                Err(nix::errno::Errno::EINTR) => continue,
                Err(error) => return Err(error).context("poll failed"),
            }
            let ready = |fd: &PollFd| fd.revents().is_some_and(|events| !events.is_empty());
            (
                ready(&fds[0]),
                ready(&fds[1]),
                fds.get(2).is_some_and(ready),
            )
        };

        if template_ready {
            match template.read_event()? {
                Reply::Exited {
                    run: Run::Guest,
                    status,
                    ..
                } => return Ok(status),
                Reply::Exited {
                    status,
                    pid: Some(pid),
                    ..
                } => {
                    clones.retain(|clone| clone.pid() != pid);
                    clone_failed |= status != 0;
                    let mut lines = Lines::new();
                    lines.line(format_args!("==> clone {pid} exited with status {status}"));
                    if clones.is_empty() {
                        lines.line("==> every clone has exited");
                        return Ok(i32::from(clone_failed));
                    }
                }
                other => bail!("unexpected event from the template: {other:?}"),
            }
        }

        let mut fork = false;
        if signal_ready {
            signals.read_signal().context("failed to read the signal")?;
            fork = true;
        }
        if stdin_ready {
            let mut line = String::new();
            if stdin
                .lock()
                .read_line(&mut line)
                .context("failed to read stdin")?
                == 0
            {
                // End of input: stop watching it.
                terminal = false;
            } else {
                fork = true;
            }
        }
        if !fork {
            continue;
        }

        let mut lines = Lines::new();
        if !frozen {
            let started = Instant::now();
            let threads = template.freeze()?;
            frozen = true;
            lines.line(format_args!(
                "==> frozen: {threads} guest thread{} in {:.1?}",
                if threads == 1 { "" } else { "s" },
                started.elapsed()
            ));
        }
        for _ in 0..count {
            let started = Instant::now();
            let (clone, endpoint) = template.fork()?;
            let elapsed = started.elapsed();
            println!("{endpoint}");
            std::io::stdout()
                .flush()
                .context("failed to write the endpoint")?;
            lines.line(format_args!(
                "==> clone {} is listening on host port {} ({endpoint}), forked in {elapsed:.1?}",
                clone.pid(),
                endpoint.port()
            ));
            clones.push(clone);
        }
    }
}

fn check_services(services: &ServiceIndex, runtime: &Runtime) -> Result<()> {
    for (manifest, directory) in services.all_packages() {
        for module in manifest.modules() {
            runtime.load(module).with_context(|| {
                format!(
                    "service {} {} in {} failed its module check",
                    manifest.service.name,
                    manifest.service.version,
                    directory.display()
                )
            })?;
        }
        println!(
            "checked {} {} {}",
            manifest.service.name,
            manifest.service.version,
            directory.display()
        );
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use std::ffi::OsStr;

    use super::*;

    #[test]
    fn flags_replace_environment() {
        let directories = service_dirs(
            vec![PathBuf::from("flag-a"), PathBuf::from("flag-b")],
            Some(OsString::from("env-a:env-b")),
        );
        assert_eq!(
            directories,
            [PathBuf::from("flag-a"), PathBuf::from("flag-b")]
        );
    }

    #[test]
    fn socket_flag_replaces_environment() {
        assert_eq!(
            socket_path(
                Some(PathBuf::from("flag.sock")),
                Some(OsString::from("env.sock"))
            ),
            PathBuf::from("flag.sock")
        );
        assert_eq!(
            socket_path(None, Some(OsString::from("env.sock"))),
            PathBuf::from("env.sock")
        );
        // Without either, some per-user default; its name is stable.
        assert!(socket_path(None, None).ends_with("serve.sock"));
    }

    #[test]
    fn environment_replaces_defaults_and_splits_paths() {
        let directories = service_dirs(Vec::new(), Some(OsString::from("env-a:env-b")));
        assert_eq!(
            directories,
            [PathBuf::from("env-a"), PathBuf::from("env-b")]
        );
        assert!(
            directories
                .iter()
                .all(|path| path.as_os_str() != OsStr::new(SYSTEM_DEFAULTS[0]))
        );
    }
}
