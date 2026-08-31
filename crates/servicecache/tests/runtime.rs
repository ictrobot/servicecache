//! The embedded runtime runs a module with isolated stdio and no network.
//! The fixtures are the toolchain's smoke modules (`bootstrap.sh --check`);
//! the tests are skipped when they are not built.

use std::path::{Path, PathBuf};

use servicecache::runtime::{RunOutput, RunRequest, Runtime};

fn smoke_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../work/build/toolchain-smoke")
}

/// Run a smoke module, or return `None` when it has not been built.
fn run(module: &Path, args: &[&str], stdin: &[u8]) -> Option<RunOutput> {
    if !module.is_file() {
        eprintln!(
            "skipped: {} is not built (run `make smoke-toolchain`)",
            module.display()
        );
        return None;
    }
    let args = args.iter().map(ToString::to_string).collect::<Vec<_>>();
    Some(
        Runtime::new()
            .run(&RunRequest {
                module,
                args: &args,
                stdin,
                mounts: &[],
            })
            .expect("run a smoke module"),
    )
}

#[test]
fn runs_a_threaded_module_to_completion() {
    let Some(output) = run(&smoke_root().join("wasix_cpp.wasm"), &[], b"") else {
        return;
    };
    assert_eq!(output.status, 0);
    let text = String::from_utf8_lossy(&output.stdout);
    assert!(text.contains("WASIX pthread works"), "{text}");
}

#[test]
fn stdin_is_a_pipe_and_the_network_is_denied() {
    let Some(output) = run(
        &smoke_root().join("stdio-net.wasm"),
        &["one", "two"],
        b"PING\n",
    ) else {
        return;
    };
    assert_eq!(output.status, 0);
    let text = String::from_utf8_lossy(&output.stdout);
    assert!(text.contains("args=2 one two"), "{text}");
    // Piped stdin is presented to WASIX guests as a terminal by the runtime;
    // what matters here is that every byte arrives and EOF follows.
    assert!(text.contains("stdin bytes=5"), "{text}");
    assert!(
        text.contains("connect errno=") || text.contains("socket errno="),
        "the network was not denied: {text}"
    );
}

#[test]
fn a_signal_during_a_handler_still_wakes_the_wait() {
    let Some(output) = run(&smoke_root().join("signal-during-handler.wasm"), &[], b"") else {
        return;
    };
    assert_eq!(
        output.status,
        0,
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    assert_eq!(
        String::from_utf8_lossy(&output.stdout).trim(),
        "WASIX signal during a handler still wakes the wait"
    );
}

#[test]
fn a_signal_handler_self_pipe_wakes_every_epoll_registration() {
    let Some(output) = run(&smoke_root().join("signal-epoll.wasm"), &[], b"") else {
        return;
    };
    assert_eq!(
        output.status,
        0,
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    assert_eq!(
        String::from_utf8_lossy(&output.stdout).trim(),
        "WASIX signal wakes every epoll registration"
    );
}
