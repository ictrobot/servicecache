use std::{
    env,
    ffi::{OsStr, OsString},
    io::{BufRead as _, IsTerminal as _, Read as _, Write as _},
    os::fd::AsFd as _,
    path::{Path, PathBuf},
    time::Instant,
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
    discovery::ServiceIndex,
    host::protocol::{Reply, Run},
    manager::HostProcess,
    manifest::Manifest,
    runtime::Runtime,
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

    #[command(subcommand)]
    command: Command,
}

#[derive(Debug, Subcommand)]
enum Command {
    /// Start the service manager.
    Serve,
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
    )
}

fn run_with(
    cli: Cli,
    environment_dirs: Option<OsString>,
    environment_cache: Option<&OsStr>,
) -> Result<()> {
    let cache_dir = || cache::directory(cli.cache_dir.as_deref(), environment_cache);
    match cli.command {
        Command::Serve => {
            println!("serve is not implemented yet");
            Ok(())
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
                ServicesCommand::List => {
                    print_services(&services);
                    Ok(())
                }
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

fn print_services(services: &ServiceIndex) {
    for package in services.iter() {
        println!(
            "{} {} {}",
            package.manifest.service.name,
            package.manifest.service.version,
            package.manifest.directory().display()
        );
        for file in &package.files {
            println!("  {}  {}", file.sha256, file.path.display());
        }
        for shadow in &package.shadowed {
            println!("  shadowed {}", shadow.directory.display());
            for file in &shadow.files {
                println!("    {}  {}", file.sha256, file.path.display());
            }
        }
    }
}

/// The manifest for `name` or `name@version`; the name alone selects the
/// only installed version.
fn find_service<'a>(services: &'a ServiceIndex, service: &str) -> Result<&'a Manifest> {
    let (name, version) = match service.split_once('@') {
        Some((name, version)) => (name, Some(version)),
        None => (service, None),
    };
    let mut candidates: Vec<&Manifest> = services
        .iter()
        .map(|package| &package.manifest)
        .filter(|manifest| manifest.service.name == name)
        .filter(|manifest| version.is_none_or(|version| manifest.service.version == version))
        .collect();
    match candidates.len() {
        0 => bail!("no installed service matches {service}"),
        1 => Ok(candidates.remove(0)),
        _ => {
            let versions: Vec<&str> = candidates
                .iter()
                .map(|manifest| manifest.service.version.as_str())
                .collect();
            bail!(
                "{name} is installed in several versions ({}); name one as {name}@<version>",
                versions.join(", ")
            )
        }
    }
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
    eprintln!(
        "\n==> {} is listening on host port {} ({endpoint}; guest port {}). Ctrl-C to stop.",
        manifest.service.name,
        endpoint.port(),
        manifest.guest.listen_port
    );
    if let Some(count) = clones {
        eprintln!(
            "==> Enter here, or `kill -USR1 {}`, freezes it and forks {count} clone{}.",
            std::process::id(),
            if count == 1 { "" } else { "s" }
        );
    }
    eprintln!();

    let status = match (clones, signals.as_mut()) {
        (Some(count), Some(signals)) => run_with_clones(&mut host, count, signals)?,
        _ => host.wait_exit()?,
    };
    if status != 0 {
        bail!("{} exited with status {status}", manifest.service.name);
    }
    Ok(())
}

/// A descriptor SIGUSR1 can be read from, the signal blocked so that it
/// goes there.
fn fork_signal() -> Result<SignalFd> {
    let mut mask = SigSet::empty();
    mask.add(Signal::SIGUSR1);
    pthread_sigmask(SigmaskHow::SIG_BLOCK, Some(&mask), None).context("failed to block SIGUSR1")?;
    SignalFd::with_flags(&mask, SfdFlags::SFD_CLOEXEC).context("failed to open a signal descriptor")
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
                    eprintln!("==> clone {pid} exited with status {status}");
                    if clones.is_empty() {
                        eprintln!("==> every clone has exited");
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

        if !frozen {
            let started = Instant::now();
            let threads = template.freeze()?;
            frozen = true;
            eprintln!(
                "==> frozen: {threads} guest thread{} in {:.1?}",
                if threads == 1 { "" } else { "s" },
                started.elapsed()
            );
        }
        for _ in 0..count {
            let started = Instant::now();
            let (clone, endpoint) = template.fork()?;
            let elapsed = started.elapsed();
            println!("{endpoint}");
            std::io::stdout()
                .flush()
                .context("failed to write the endpoint")?;
            eprintln!(
                "==> clone {} is listening on host port {} ({endpoint}), forked in {elapsed:.1?}",
                clone.pid(),
                endpoint.port()
            );
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
