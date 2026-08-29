use std::{env, ffi::OsString, path::PathBuf};

use anyhow::{Context, Result};
use clap::{Parser, Subcommand};

use crate::{discovery::ServiceIndex, runtime::Runtime};

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

    #[command(subcommand)]
    command: Command,
}

#[derive(Debug, Subcommand)]
enum Command {
    /// Start the service manager.
    Serve,
    /// Inspect installed service packages.
    Services {
        #[command(subcommand)]
        command: ServicesCommand,
    },
}

#[derive(Debug, Subcommand)]
enum ServicesCommand {
    /// List discovered service packages and their content digests.
    List,
    /// Load every discovered module with the embedded runtime.
    Check,
}

/// Parse command-line arguments and run the requested command.
///
/// # Errors
///
/// Returns an error when service discovery, hashing, or module loading fails.
pub fn run() -> Result<()> {
    run_with(Cli::parse(), env::var_os("SERVICECACHE_SERVICES_DIR"))
}

fn run_with(cli: Cli, environment_dirs: Option<OsString>) -> Result<()> {
    match cli.command {
        Command::Serve => {
            println!("serve is not implemented yet");
            Ok(())
        }
        Command::Services { command } => {
            let search_dirs = service_dirs(cli.services_dir, environment_dirs);
            let services = ServiceIndex::discover(&search_dirs)?;
            match command {
                ServicesCommand::List => {
                    print_services(&services);
                    Ok(())
                }
                ServicesCommand::Check => check_services(&services),
            }
        }
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

fn check_services(services: &ServiceIndex) -> Result<()> {
    let runtime = Runtime::new();
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
