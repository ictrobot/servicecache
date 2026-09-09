//! The host's process title: what `ps` and `htop` show as its command
//! line. The manager (`servicecache serve` or `run`) keeps the command
//! line it was started with; every host in the tree below it takes a
//! title instead. Only the base template is spawned with `exec()`: a
//! recipe template is a `fork()` of the base and an instance a fork of
//! its template, so both inherit the argument memory of the process above
//! verbatim. The title is therefore written over that memory in place,
//! and the manager spawns every host with a padding argument that
//! reserves room for the longest title along the chain.
//!
//! The standard library does not copy the arguments at startup: it keeps
//! pointers into this same memory and reads the strings on every call.
//! From the first [`set`] on, `std::env::args()` and `args_os()` return
//! fragments of the title and empty strings for the rest of the process,
//! without any error. Anything that needs an argument must take it from
//! the parsed command line, never re-read argv. The environment is left
//! alone, so `std::env::vars()` and `current_exe()` are unaffected.

use std::{fmt::Write as _, net::SocketAddr};

/// The flag the padding argument is passed under.
pub const BUFFER_FLAG: &str = "--internal-name-buffer";

/// The length of the padding argument, flag included: room for the
/// longest title with margin, whatever the paths in the real arguments
/// are.
const BUFFER_LEN: usize = 256;

/// The padding argument, flag and value: a label so that a host whose
/// title was never set still explains itself, padded with underscores to
/// `BUFFER_LEN` in all. Built at compile time.
pub const BUFFER_ARG: &str = {
    const LABEL: &[u8] = b"_SERVICECACHE_NAME_BUFFER";
    const PREFIX: &[u8] = BUFFER_FLAG.as_bytes();
    const BYTES: [u8; BUFFER_LEN] = {
        let mut bytes = [b'_'; BUFFER_LEN];
        let mut i = 0;
        while i < PREFIX.len() {
            bytes[i] = PREFIX[i];
            i += 1;
        }
        bytes[i] = b'=';
        i += 1;
        let mut j = 0;
        while j < LABEL.len() {
            bytes[i + j] = LABEL[j];
            j += 1;
        }
        bytes
    };
    match std::str::from_utf8(&BYTES) {
        Ok(arg) => arg,
        Err(_) => panic!("the padding argument is ASCII"),
    }
};

/// What a title says the host is doing.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum State {
    /// Bringing the guest up; not yet serving.
    Starting,
    /// The guest is serving on this endpoint.
    Serving(SocketAddr),
    /// Frozen: a template, serving nothing.
    Frozen,
}

/// The title: role, `name@version`, the recipe when there is one, and
/// what the host is doing. `recipe` is the SHA-256 of the recipe bytes;
/// the title shows its first eight hex digits.
fn render(name: &str, version: &str, recipe: Option<&[u8; 32]>, state: State) -> String {
    let role = match state {
        State::Starting | State::Serving(_) => "instance",
        State::Frozen => "template",
    };
    let mut title = format!("servicecache {role} {name}@{version}");
    if let Some(digest) = recipe {
        title.push_str(" recipe ");
        for byte in &digest[..4] {
            let _ = write!(title, "{byte:02x}");
        }
    }
    match state {
        State::Starting => title.push_str(" starting"),
        State::Serving(endpoint) => {
            let _ = write!(title, " listening on {endpoint}");
        }
        State::Frozen => {}
    }
    title
}

/// Sets the process title for a host holding `name@version`, initialized
/// with the recipe whose SHA-256 is `recipe` if any, in `state`. Best
/// effort: a failure is logged and changes nothing else.
///
/// Destroys the original arguments: `std::env::args()` returns garbage
/// from here on (see the module documentation).
pub fn set(name: &str, version: &str, recipe: Option<&[u8; 32]>, state: State) {
    write(&render(name, version, recipe, state));
}

/// Writes `title` over the arguments, truncated to the room they left.
pub(super) fn write(title: &str) {
    match region() {
        Ok((start, len)) => {
            // The last byte stays NUL so that the kernel serves the region
            // as a plain argument list rather than reading on into the
            // environment.
            let room = len.saturating_sub(1);
            let title = title.as_bytes();
            let shown = &title[..title.len().min(room)];
            // SAFETY: `/proc/self/stat` reports the process's own argument
            // strings, writable memory at the top of the main thread's
            // stack. Writing plain bytes there is sound; the standard
            // library still points into it, which is why `args()` reads
            // garbage afterwards rather than anything worse.
            unsafe {
                std::ptr::copy_nonoverlapping(shown.as_ptr(), start.cast::<u8>(), shown.len());
                std::ptr::write_bytes(start.cast::<u8>().add(shown.len()), 0, len - shown.len());
            }
        }
        Err(error) => tracing::debug!(error = format!("{error:#}"), "process title not set"),
    }
}

/// The argument memory the kernel serves as `/proc/self/cmdline`: its
/// address and length, from the `arg_start` and `arg_end` fields of
/// `/proc/self/stat`.
fn region() -> anyhow::Result<(*mut libc::c_void, usize)> {
    let stat = std::fs::read_to_string("/proc/self/stat")?;
    // The command name is in parentheses and may contain anything, so the
    // fields are counted from after the last one.
    let (_, after_comm) = stat
        .rsplit_once(')')
        .ok_or_else(|| anyhow::anyhow!("unparseable /proc/self/stat"))?;
    let mut fields = after_comm.split_ascii_whitespace();
    // `arg_start` is field 48 and `arg_end` field 49 of stat; the state,
    // field 3, is the first after the command name.
    let arg_start: usize = fields
        .nth(48 - 3)
        .ok_or_else(|| anyhow::anyhow!("no arg_start in /proc/self/stat"))?
        .parse()?;
    let arg_end: usize = fields
        .next()
        .ok_or_else(|| anyhow::anyhow!("no arg_end in /proc/self/stat"))?
        .parse()?;
    if arg_start == 0 || arg_end <= arg_start {
        anyhow::bail!("no argument region ({arg_start:#x}..{arg_end:#x})");
    }
    Ok((arg_start as *mut libc::c_void, arg_end - arg_start))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_buffer_is_labelled_and_full_length() {
        assert_eq!(BUFFER_ARG.len(), BUFFER_LEN);
        let (flag, value) = BUFFER_ARG.split_once('=').expect("flag=value");
        assert_eq!(flag, BUFFER_FLAG);
        assert!(value.starts_with("_SERVICECACHE_NAME_BUFFER___"));
        assert!(
            value
                .bytes()
                .all(|byte| byte == b'_' || byte.is_ascii_uppercase())
        );
    }

    #[test]
    fn titles_read_as_role_service_recipe_and_state() {
        let endpoint: SocketAddr = "127.0.0.1:46051".parse().expect("an endpoint");
        let mut digest = [0xff; 32];
        digest[..4].copy_from_slice(&[0xfa, 0x9b, 0x30, 0xbc]);
        let title = |recipe, state| render("exampledb", "1.2.3", recipe, state);
        assert_eq!(
            title(None, State::Starting),
            "servicecache instance exampledb@1.2.3 starting"
        );
        assert_eq!(
            title(None, State::Serving(endpoint)),
            "servicecache instance exampledb@1.2.3 listening on 127.0.0.1:46051"
        );
        assert_eq!(
            title(Some(&digest), State::Serving(endpoint)),
            "servicecache instance exampledb@1.2.3 recipe fa9b30bc listening on 127.0.0.1:46051"
        );
        assert_eq!(
            title(Some(&digest), State::Frozen),
            "servicecache template exampledb@1.2.3 recipe fa9b30bc"
        );
    }

    #[test]
    fn the_region_is_where_the_arguments_are() {
        let (start, len) = region().expect("a region");
        // Whatever the test harness was started as, the first argument is
        // the program path, and the region holds every argument.
        let first = std::env::args().next().expect("argv[0]");
        assert!(len > first.len());
        // SAFETY: reading the process's own argument memory.
        let bytes = unsafe { std::slice::from_raw_parts(start.cast::<u8>(), first.len()) };
        assert_eq!(bytes, first.as_bytes());
    }
}
