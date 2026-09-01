//! The manifest's readiness probe, run against the guest's endpoint.
//!
//! A server can listen before it serves: connections in that window are
//! accepted and turned away at the protocol level, which binding alone
//! cannot see. The probe writes the manifest's bytes to the endpoint and
//! reads until the response matches the manifest's pattern, so ready means
//! the server answered as a serving guest does.

use std::{
    io::{Read, Write as _},
    net::{SocketAddr, TcpStream},
    sync::{Arc, OnceLock},
    time::{Duration, Instant},
};

use crate::manifest::ReadyProbe;

/// How long one connection attempt may take to open.
const CONNECT_TIMEOUT: Duration = Duration::from_secs(1);

/// How long one read may block before the attempt re-checks its deadline.
const READ_TIMEOUT: Duration = Duration::from_millis(500);

/// How long one connection gets for the response to match.
const ATTEMPT_DEADLINE: Duration = Duration::from_secs(2);

/// The first pause between attempts: readiness gates bring-up, so it is
/// seen moments after it happens rather than a polling period later.
const INITIAL_INTERVAL: Duration = Duration::from_millis(2);

/// The backoff cap, so a slow start does not fill the guest's log with
/// rejected connections while the deadline runs.
const MAX_INTERVAL: Duration = Duration::from_millis(100);

/// How long the guest gets to answer the probe before ready fails.
pub(super) const DEADLINE: Duration = Duration::from_secs(30);

/// The most response bytes one attempt accumulates for matching.
const RESPONSE_CAP: usize = 4096;

/// One connection: send the probe's bytes and read until the response
/// matches within the attempt's deadline. The error is a one-line summary
/// of how the attempt fell short, for the trace of every attempt and for
/// the bring-up error when the last one runs out the deadline.
fn attempt(endpoint: SocketAddr, probe: &ReadyProbe) -> Result<(), String> {
    let mut stream = TcpStream::connect_timeout(&endpoint, CONNECT_TIMEOUT)
        .map_err(|error| format!("could not connect: {error}"))?;
    stream
        .set_read_timeout(Some(READ_TIMEOUT))
        .and_then(|()| stream.write_all(&probe.send))
        .and_then(|()| stream.flush())
        .map_err(|error| format!("could not send the probe: {error}"))?;
    let deadline = Instant::now() + ATTEMPT_DEADLINE;
    let mut response = Vec::new();
    let mut buffer = [0_u8; 1024];
    let mut ended = "the attempt deadline passed";
    while Instant::now() < deadline && response.len() < RESPONSE_CAP {
        match stream.read(&mut buffer) {
            Ok(0) => {
                ended = "the connection closed";
                break;
            }
            Ok(read) => {
                response.extend_from_slice(&buffer[..read]);
                if probe.matches.is_match(&response) {
                    return Ok(());
                }
            }
            Err(error)
                if matches!(
                    error.kind(),
                    std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut
                ) => {}
            Err(_) => {
                ended = "the read failed";
                break;
            }
        }
    }
    if probe.matches.is_match(&response) {
        return Ok(());
    }
    if response.is_empty() {
        Err(format!("{ended} without a response"))
    } else {
        Err(format!(
            "{ended} after {} unmatched bytes, starting {}",
            response.len(),
            preview(&response)
        ))
    }
}

/// The first bytes of a response in the manifest's own byte-string
/// notation, so a failed probe can be compared with the pattern directly.
fn preview(bytes: &[u8]) -> String {
    use std::fmt::Write as _;

    let mut out = String::new();
    for &byte in bytes.iter().take(24) {
        if (b' '..=b'~').contains(&byte) && byte != b'\\' {
            out.push(byte as char);
        } else {
            let _ = write!(out, "\\x{byte:02x}");
        }
    }
    if bytes.len() > 24 {
        out.push_str("...");
    }
    out
}

/// Probes the endpoint on its own thread until the response matches or
/// [`DEADLINE`] passes, stores the outcome, and announces it on the event
/// pipe. A failed outcome carries the last attempt's summary. The thread
/// ends either way, so a later freeze still drains to one thread.
pub(super) fn spawn(
    endpoint: SocketAddr,
    probe: ReadyProbe,
    outcome: Arc<OnceLock<Result<(), String>>>,
    notify: Arc<dyn Fn() + Send + Sync>,
) -> std::io::Result<()> {
    std::thread::Builder::new()
        .name("ready-probe".to_owned())
        .spawn(move || {
            let started = Instant::now();
            let deadline = started + DEADLINE;
            let mut interval = INITIAL_INTERVAL;
            let mut attempts = 0_u32;
            loop {
                attempts += 1;
                match attempt(endpoint, &probe) {
                    Ok(()) => {
                        tracing::debug!(attempts, elapsed = ?started.elapsed(), "readiness probe matched");
                        let _ = outcome.set(Ok(()));
                        break;
                    }
                    Err(summary) => {
                        tracing::trace!(attempts, %summary, "readiness probe attempt fell short");
                        if Instant::now() >= deadline {
                            let _ = outcome.set(Err(summary));
                            break;
                        }
                    }
                }
                std::thread::sleep(interval);
                interval = (interval * 2).min(MAX_INTERVAL);
            }
            notify();
        })?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::net::TcpListener;

    fn probe() -> ReadyProbe {
        ReadyProbe {
            send: b"\x00ping".to_vec(),
            matches: regex::bytes::Regex::new(r"^ok\x00").expect("pattern"),
        }
    }

    /// One canned server connection: read the probe bytes, answer, close.
    fn serve_one(listener: &TcpListener, response: &'static [u8]) -> std::thread::JoinHandle<()> {
        let listener = listener.try_clone().expect("clone listener");
        std::thread::spawn(move || {
            let (mut stream, _) = listener.accept().expect("accept");
            let mut buffer = [0_u8; 64];
            let _ = stream.read(&mut buffer);
            stream.write_all(response).expect("respond");
        })
    }

    #[test]
    fn attempt_matches_only_the_serving_response() {
        let listener = TcpListener::bind("127.0.0.1:0").expect("bind");
        let endpoint = listener.local_addr().expect("addr");

        let starting = serve_one(&listener, b"no\x00starting up\x00");
        let summary = attempt(endpoint, &probe()).expect_err("must not match");
        assert!(summary.contains("unmatched bytes"), "{summary}");
        assert!(summary.contains(r"no\x00starting up\x00"), "{summary}");
        starting.join().expect("join");

        let serving = serve_one(&listener, b"ok\x00v1");
        attempt(endpoint, &probe()).expect("must match");
        serving.join().expect("join");
    }

    #[test]
    fn an_empty_probe_matches_a_server_that_speaks_first() {
        let listener = TcpListener::bind("127.0.0.1:0").expect("bind");
        let endpoint = listener.local_addr().expect("addr");
        let probe = ReadyProbe {
            send: Vec::new(),
            matches: regex::bytes::Regex::new(r"(?s-u)\A.{2}\x02").expect("pattern"),
        };

        // A greeting sent on accept, nothing read first. The skipped
        // bytes are a newline and a high byte, so the pattern's flags
        // are both load-bearing.
        let greeting = std::thread::spawn(move || {
            let (mut stream, _) = listener.accept().expect("accept");
            stream
                .write_all(b"\x0a\x80\x02server hello\x00")
                .expect("greet");
        });
        attempt(endpoint, &probe).expect("must match");
        greeting.join().expect("join");
    }
}
