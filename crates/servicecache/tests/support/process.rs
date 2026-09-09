//! Reading a host process from `/proc`.

/// The process title of `pid`: its first argument, which a host writes
/// its title over.
pub fn title(pid: u32) -> String {
    let cmdline = std::fs::read(format!("/proc/{pid}/cmdline")).expect("read cmdline");
    let first = cmdline.split(|&byte| byte == 0).next().unwrap_or_default();
    String::from_utf8_lossy(first).into_owned()
}
