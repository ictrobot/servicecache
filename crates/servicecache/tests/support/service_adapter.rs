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
    time::Duration,
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

    pub fn check_working(&self, endpoint: SocketAddr) {
        self.run("check-working", &Self::endpoint_args(endpoint));
    }

    pub fn diverge(&self, endpoint: SocketAddr, tag: usize) {
        let mut args = Self::endpoint_args(endpoint);
        args.push(tag.to_string());
        self.run("diverge", &args);
    }

    pub fn check_diverged(&self, endpoint: SocketAddr, tag: usize) {
        let mut args = Self::endpoint_args(endpoint);
        args.push(tag.to_string());
        self.run("check-diverged", &args);
    }

    /// Starts, on another thread, a request that blocks in the guest.
    pub fn start_blocking_request(&self, endpoint: SocketAddr) -> PendingRequest {
        let path = self.path.clone();
        let args = Self::endpoint_args(endpoint);
        PendingRequest {
            thread: std::thread::spawn(move || {
                let output = Command::new("python3")
                    .arg(&path)
                    .arg("blocking-request")
                    .args(&args)
                    .output()
                    .expect("run the adapter");
                format!(
                    "{}{}",
                    String::from_utf8_lossy(&output.stdout).trim(),
                    String::from_utf8_lossy(&output.stderr).trim()
                )
            }),
        }
    }
}

/// A request in flight on another thread.
pub struct PendingRequest {
    thread: std::thread::JoinHandle<String>,
}

impl PendingRequest {
    /// Waits for the request to end and describes how it ended.
    pub fn finish(self, timeout: Duration) -> String {
        let deadline = std::time::Instant::now() + timeout;
        while !self.thread.is_finished() && std::time::Instant::now() < deadline {
            std::thread::sleep(Duration::from_millis(50));
        }
        assert!(
            self.thread.is_finished(),
            "the request in flight at the freeze never ended"
        );
        self.thread.join().unwrap_or_else(|_| "panicked".into())
    }
}
