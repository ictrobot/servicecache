//! A service's test adapter, `services/<name>/smoke/adapter` in the
//! repository, found from the manifest's service name. The crate knows
//! nothing about any service: the adapter speaks the service's protocol and
//! the tests only run its verbs. Not a test file; included by the tests that
//! need it.

#![allow(dead_code, clippy::must_use_candidate, clippy::missing_panics_doc)]

use std::{
    net::SocketAddr,
    path::{Path, PathBuf},
    process::Command,
};

pub struct ServiceAdapter {
    path: PathBuf,
}

impl ServiceAdapter {
    /// The adapter for `service_name`, if the repository has one.
    pub fn find(repo_root: &Path, service_name: &str) -> Option<Self> {
        let path = repo_root
            .join("services")
            .join(service_name)
            .join("smoke")
            .join("adapter");
        path.is_file().then_some(Self { path })
    }

    fn run(&self, verb: &str, args: &[String]) -> String {
        let output = Command::new("python3")
            .arg(&self.path)
            .arg(verb)
            .args(args)
            .output()
            .expect("run the adapter");
        assert!(
            output.status.success(),
            "{} {verb} {} failed: {}{}",
            self.path.display(),
            args.join(" "),
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        );
        String::from_utf8_lossy(&output.stdout).into_owned()
    }

    fn endpoint_args(endpoint: SocketAddr) -> Vec<String> {
        vec![endpoint.ip().to_string(), endpoint.port().to_string()]
    }

    /// The initializer's stdin.
    pub fn recipe(&self) -> Vec<u8> {
        self.run("recipe", &[]).into_bytes()
    }

    pub fn check_initialized(&self, endpoint: SocketAddr) {
        self.run("check-initialized", &Self::endpoint_args(endpoint));
    }
}
