//! Logging through `tracing`, which Wasmer's crates log with too, to stderr.
//!
//! The filter is a `tracing_subscriber::EnvFilter` directive list, taken
//! from `--log`, else from `-v` repeated, else from `SERVICECACHE_LOG`, else
//! `warn`. The `-v` levels: one informs about this crate's steps (a host
//! starting, phases, a freeze, a fork); two adds their details and the
//! patched Wasmer code's (the gate, the drain, the selector, the listener);
//! three traces both (every coroutine, every socket); four traces
//! everything, wasmer-wasix's syscalls included.
//!
//! A host process is given the manager's directives on its command line, so
//! `-v` on the manager applies to its hosts and their clones. Every line
//! starts with the pid of the process writing it, to tell the manager, its
//! hosts and their clones apart.

use std::{fmt, io::IsTerminal as _, sync::OnceLock};

use anyhow::{Context as _, Result};
use tracing::{Event, Subscriber};
use tracing_subscriber::{
    EnvFilter,
    fmt::{FmtContext, FormatEvent, FormatFields, format::Writer},
    registry::LookupSpan,
};

/// The targets the Wasmer patches log under.
const PATCH_TARGETS: &[&str] = &[
    "wasmer_vm::trap::suspend",
    "virtual_mio::selector",
    "virtual_net::host",
];

static DIRECTIVES: OnceLock<String> = OnceLock::new();

/// An event format that prefixes each line of `inner`'s with the pid of the
/// process writing it, read for every line: a clone inherits the subscriber
/// from its template through `fork()`.
struct WithPid<E> {
    inner: E,
}

impl<S, N, E> FormatEvent<S, N> for WithPid<E>
where
    S: Subscriber + for<'a> LookupSpan<'a>,
    N: for<'a> FormatFields<'a> + 'static,
    E: FormatEvent<S, N>,
{
    fn format_event(
        &self,
        ctx: &FmtContext<'_, S, N>,
        mut writer: Writer<'_>,
        event: &Event<'_>,
    ) -> fmt::Result {
        write!(writer, "[{}] ", std::process::id())?;
        self.inner.format_event(ctx, writer, event)
    }
}

/// The directives for `-v` repeated `verbosity` times.
#[must_use]
pub fn directives_for(verbosity: u8) -> String {
    let ours = |level: &str| {
        std::iter::once("servicecache")
            .chain(PATCH_TARGETS.iter().copied())
            .map(|target| format!("{target}={level}"))
            .collect::<Vec<_>>()
            .join(",")
    };
    match verbosity {
        0 => "warn".to_owned(),
        1 => "warn,servicecache=info".to_owned(),
        2 => format!("warn,{}", ours("debug")),
        3 => format!("info,{}", ours("trace")),
        _ => "trace".to_owned(),
    }
}

/// Installs the subscriber for this process (once; later calls do nothing)
/// and remembers the directives for `directives`.
///
/// # Errors
///
/// Fails on directives the filter cannot parse.
pub fn init(verbosity: u8, log: Option<&str>) -> Result<()> {
    let directives = match (log, verbosity, std::env::var("SERVICECACHE_LOG")) {
        (Some(log), _, _) => log.to_owned(),
        (None, 0, Ok(environment)) => environment,
        (None, verbosity, _) => directives_for(verbosity),
    };
    let filter = EnvFilter::try_new(&directives)
        .with_context(|| format!("bad log directives {directives:?}"))?;
    let _ = DIRECTIVES.set(directives);
    // Already set: by a test, or by an embedder; theirs wins.
    let _ = tracing_subscriber::fmt()
        .with_env_filter(filter)
        .with_writer(std::io::stderr)
        .with_target(true)
        .with_thread_names(true)
        .with_ansi(std::io::stderr().is_terminal())
        .map_event_format(|inner| WithPid { inner })
        .try_init();
    Ok(())
}

/// The directives in effect, once `init` has run.
#[must_use]
pub fn directives() -> Option<&'static str> {
    DIRECTIVES.get().map(String::as_str)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn levels_are_valid_directives() {
        for verbosity in 0..=5 {
            let directives = directives_for(verbosity);
            EnvFilter::try_new(&directives).unwrap_or_else(|error| panic!("{directives}: {error}"));
        }
        assert!(directives_for(2).contains("servicecache=debug"));
        assert!(directives_for(3).contains("wasmer_vm::trap::suspend=trace"));
        assert_eq!(directives_for(9), "trace");
    }
}
