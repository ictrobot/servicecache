//! Compiled modules, cached on disk.
//!
//! Compiling a module is CPU-intensive and can be slow, particularly in a
//! debug build, and every host process starts from the module's bytes, so
//! the compiled artifact is kept under the cache directory and loaded back
//! through Wasmer's own serialisation. An entry is keyed by the module's
//! content and by the engine that compiled it (compiler and optimisation
//! level, artifact format, the host's CPU features), so nothing is ever
//! stale: a different module, Wasmer or machine is a different entry, and an
//! artifact that no longer loads is recompiled and replaced. Processes
//! missing on the same entry take turns: the first compiles and stores it,
//! the rest wait for it.
//!
//! Wasmer's own caches are not used: `wasmer-cache` keys by module hash
//! alone and writes entries in place, and wasmer-wasix's module cache is
//! asynchronous and compiles on a miss wherever the runtime decides, whereas
//! the host must compile on a thread pool it can tear down before a freeze.
//! The serialisation underneath is the same.
//!
//! The directory is `--cache-dir`, else `SERVICECACHE_CACHE_DIR`, else
//! `$XDG_CACHE_HOME/servicecache` (`~/.cache/servicecache`). Loading an
//! artifact maps executable code into the process, so the directory is
//! created private to the user.

use std::{
    ffi::OsStr,
    fs,
    os::unix::fs::{DirBuilderExt, OpenOptionsExt},
    path::{Path, PathBuf},
};

use anyhow::{Context as _, Result, bail};
use sha2::{Digest, Sha256};
use wasmer::{CompileError, Engine, Module};

/// The cache directory, from the flag, the environment or the XDG default.
///
/// # Errors
///
/// Fails when neither `XDG_CACHE_HOME` nor `HOME` is set and nothing else
/// names a directory.
pub fn directory(flag: Option<&Path>, environment: Option<&OsStr>) -> Result<PathBuf> {
    if let Some(dir) = flag {
        return Ok(dir.to_path_buf());
    }
    if let Some(dir) = environment.filter(|value| !value.is_empty()) {
        return Ok(PathBuf::from(dir));
    }
    if let Some(xdg) = std::env::var_os("XDG_CACHE_HOME").filter(|value| !value.is_empty()) {
        return Ok(PathBuf::from(xdg).join("servicecache"));
    }
    if let Some(home) = std::env::var_os("HOME").filter(|value| !value.is_empty()) {
        return Ok(PathBuf::from(home).join(".cache").join("servicecache"));
    }
    bail!("no cache directory: set --cache-dir, SERVICECACHE_CACHE_DIR or HOME")
}

/// Removes the cache directory. `Ok(false)` when there was none.
///
/// # Errors
///
/// Fails when the directory exists and cannot be removed.
pub fn clean(dir: &Path) -> Result<bool> {
    match fs::remove_dir_all(dir) {
        Ok(()) => Ok(true),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(false),
        Err(error) => Err(error).with_context(|| format!("failed to remove {}", dir.display())),
    }
}

/// Compiled modules under one cache directory.
#[derive(Debug, Clone)]
pub struct ModuleCache {
    dir: PathBuf,
}

impl ModuleCache {
    #[must_use]
    pub fn new(dir: PathBuf) -> Self {
        Self { dir }
    }

    /// The cache directory.
    #[must_use]
    pub fn dir(&self) -> &Path {
        &self.dir
    }

    /// The compiled form of the module at `path`: loaded from the cache, or
    /// compiled with `compile` and stored.
    ///
    /// # Errors
    ///
    /// Fails when the module cannot be read or compiled, or the artifact
    /// cannot be stored.
    pub fn load(
        &self,
        engine: &Engine,
        path: &Path,
        compile: impl FnOnce(&Engine, &[u8]) -> Result<Module, CompileError>,
    ) -> Result<Module> {
        let bytes = fs::read(path).with_context(|| format!("failed to read {}", path.display()))?;
        let entry_dir = self.dir.join("modules").join(engine_key(engine));
        let entry = entry_dir.join(format!("{:x}.bin", Sha256::digest(&bytes)));

        if let Some(module) = load_entry(engine, path, &entry, false) {
            return Ok(module);
        }

        fs::DirBuilder::new()
            .recursive(true)
            .mode(0o700)
            .create(&entry_dir)
            .with_context(|| format!("failed to create {}", entry_dir.display()))?;
        // One compile per entry at a time: the first process to take the
        // entry's lock compiles and stores, the others wait on it and then
        // find the artifact in place. The lock lasts until `lock_file` is
        // dropped; the kernel drops it if its holder dies; the empty lock
        // file stays.
        let lock_path = entry.with_extension("lock");
        let lock_file = fs::OpenOptions::new()
            .create(true)
            .truncate(false)
            .write(true)
            .mode(0o600)
            .open(&lock_path)
            .with_context(|| format!("failed to open {}", lock_path.display()))?;
        lock_file
            .lock()
            .with_context(|| format!("failed to lock {}", lock_path.display()))?;
        if let Some(module) = load_entry(engine, path, &entry, true) {
            return Ok(module);
        }

        let started = std::time::Instant::now();
        let module = compile(engine, &bytes)
            .with_context(|| format!("failed to compile {}", path.display()))?;
        tracing::info!(
            module = %path.display(),
            bytes = bytes.len(),
            elapsed = ?started.elapsed(),
            "compiled module"
        );
        // Written whole under another name, then renamed: a reader sees
        // either no artifact or a complete one.
        let partial = entry_dir.join(format!(
            "{}.tmp-{}",
            entry
                .file_name()
                .map_or_else(String::new, |name| name.to_string_lossy().into_owned()),
            std::process::id()
        ));
        module
            .serialize_to_file(&partial)
            .with_context(|| format!("failed to write {}", partial.display()))?;
        fs::rename(&partial, &entry)
            .with_context(|| format!("failed to move {} into place", partial.display()))?;
        Ok(module)
    }
}

/// The artifact at `entry`, if there is one and it loads. One that does not
/// load is reported and treated as absent, so it gets recompiled. `waited`
/// says whether the caller held the entry's lock first, for the log.
fn load_entry(engine: &Engine, path: &Path, entry: &Path, waited: bool) -> Option<Module> {
    let Ok(metadata) = entry.metadata() else {
        return None;
    };
    if !metadata.is_file() {
        return None;
    }
    let started = std::time::Instant::now();
    // SAFETY: the artifact was written by `Module::serialize` from this
    // program into a directory private to the user; Wasmer checks its header
    // and rejects one it did not produce.
    match unsafe { Module::deserialize_from_file(engine, entry) } {
        Ok(module) => {
            tracing::debug!(
                module = %path.display(),
                entry = %entry.display(),
                bytes = metadata.len(),
                elapsed = ?started.elapsed(),
                waited,
                "module cache hit"
            );
            Some(module)
        }
        Err(error) => {
            tracing::warn!(
                module = %path.display(),
                entry = %entry.display(),
                %error,
                "cached artifact did not load; recompiling"
            );
            None
        }
    }
}

/// What the compiled form depends on besides the module: the engine's
/// compiler and settings, its artifact format, and the CPU features the code
/// was generated for (as a digest of the feature list, to keep the name
/// short).
fn engine_key(engine: &Engine) -> String {
    let features: Vec<String> = wasmer::sys::CpuFeature::for_host()
        .iter()
        .map(|feature| format!("{feature:?}").to_lowercase())
        .collect();
    let cpu = format!("{:x}", Sha256::digest(features.join("+")));
    format!(
        "{}-{}-cpu{}",
        engine.deterministic_id(),
        engine.artifact_format(),
        &cpu[..8]
    )
}

#[cfg(test)]
mod tests {
    use std::sync::atomic::{AtomicUsize, Ordering};

    use super::*;

    fn fixture() -> Option<PathBuf> {
        let path = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("../../work/build/toolchain-smoke/stdio-net.wasm");
        path.is_file().then_some(path)
    }

    #[test]
    fn directory_prefers_flag_then_environment() {
        let flag = Path::new("/flag");
        assert_eq!(
            directory(Some(flag), Some(OsStr::new("/env"))).unwrap(),
            PathBuf::from("/flag")
        );
        assert_eq!(
            directory(None, Some(OsStr::new("/env"))).unwrap(),
            PathBuf::from("/env")
        );
        let default = directory(None, Some(OsStr::new(""))).unwrap();
        assert!(default.ends_with("servicecache"), "{}", default.display());
    }

    #[test]
    fn second_load_is_a_hit_and_clean_removes_it() {
        let Some(module_path) = fixture() else {
            eprintln!("skipped: the toolchain smoke fixtures are not built");
            return;
        };
        let dir =
            std::env::temp_dir().join(format!("servicecache-cache-test-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        let cache = ModuleCache::new(dir.clone());
        let engine = Engine::default();
        let compiles = AtomicUsize::new(0);
        let compile = |engine: &Engine, bytes: &[u8]| {
            compiles.fetch_add(1, Ordering::SeqCst);
            Module::from_binary(engine, bytes)
        };

        cache
            .load(&engine, &module_path, compile)
            .expect("first load compiles");
        assert_eq!(compiles.load(Ordering::SeqCst), 1);
        let entries: Vec<_> = fs::read_dir(dir.join("modules"))
            .expect("modules dir")
            .flatten()
            .collect();
        assert_eq!(entries.len(), 1, "one engine directory");

        cache
            .load(&engine, &module_path, |_, _| {
                panic!("second load must not compile")
            })
            .expect("second load hits");

        assert!(clean(&dir).expect("clean"));
        assert!(!dir.exists());
        assert!(!clean(&dir).expect("clean again"));
    }

    #[test]
    fn concurrent_misses_compile_once() {
        let Some(module_path) = fixture() else {
            eprintln!("skipped: the toolchain smoke fixtures are not built");
            return;
        };
        let dir = std::env::temp_dir().join(format!(
            "servicecache-cache-concurrent-{}",
            std::process::id()
        ));
        let _ = fs::remove_dir_all(&dir);
        let cache = ModuleCache::new(dir.clone());
        let engine = Engine::default();
        let compiles = AtomicUsize::new(0);
        std::thread::scope(|scope| {
            for _ in 0..4 {
                scope.spawn(|| {
                    cache
                        .load(&engine, &module_path, |engine, bytes| {
                            compiles.fetch_add(1, Ordering::SeqCst);
                            std::thread::sleep(std::time::Duration::from_millis(200));
                            Module::from_binary(engine, bytes)
                        })
                        .expect("load");
                });
            }
        });
        assert_eq!(
            compiles.load(Ordering::SeqCst),
            1,
            "one compile for four misses"
        );
        let _ = fs::remove_dir_all(&dir);
    }
}
