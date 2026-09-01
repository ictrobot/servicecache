use std::{
    collections::BTreeMap,
    fs,
    path::{Path, PathBuf},
};

use anyhow::{Context, Result, bail, ensure};
use serde::Deserialize;

/// A validated service package manifest.
#[derive(Debug, Clone)]
pub struct Manifest {
    pub service: Service,
    pub prepare: Option<Prepare>,
    pub guest: Guest,
    pub initializer: Option<Initializer>,
    directory: PathBuf,
}

/// The identity of a service package.
#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Service {
    pub name: String,
    pub version: String,
    /// Import namespaces the service's modules may use beyond the WASIX
    /// baseline, each specified in extensions/<name>/. Assembly checks the
    /// built modules against it, and the host registers only these
    /// namespaces for every run, so an undeclared import fails to
    /// instantiate.
    #[serde(default)]
    pub extensions: Vec<String>,
}

/// Optional filesystem preparation performed before the serving run.
#[derive(Debug, Clone)]
pub struct Prepare {
    pub fs: BTreeMap<PathBuf, PathBuf>,
    pub module: Option<PathBuf>,
    pub args: Vec<String>,
    pub stdin_file: Option<PathBuf>,
}

/// The serving module and its runtime settings.
#[derive(Debug, Clone)]
pub struct Guest {
    pub module: PathBuf,
    pub args: Vec<String>,
    pub listen_port: u16,
    /// Optional proof the server is serving: bytes the host writes to the
    /// guest's endpoint and a pattern its response must match before the
    /// guest is reported ready. Absent, listening is readiness.
    pub ready: Option<ReadyProbe>,
}

/// A readiness probe: what to send, empty where the server speaks
/// first, and what a serving guest answers.
#[derive(Debug, Clone)]
pub struct ReadyProbe {
    pub send: Vec<u8>,
    pub matches: regex::bytes::Regex,
}

/// An optional module used to initialize the serving guest.
#[derive(Debug, Clone)]
pub struct Initializer {
    pub module: PathBuf,
    pub args: Vec<String>,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct RawManifest {
    service: Service,
    prepare: Option<RawPrepare>,
    guest: RawGuest,
    initializer: Option<RawInitializer>,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct RawPrepare {
    #[serde(default)]
    fs: BTreeMap<PathBuf, PathBuf>,
    module: Option<PathBuf>,
    #[serde(default)]
    args: Vec<String>,
    stdin_file: Option<PathBuf>,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct RawGuest {
    module: PathBuf,
    #[serde(default)]
    args: Vec<String>,
    listen_port: u16,
    ready: Option<RawReadyProbe>,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct RawReadyProbe {
    #[serde(default)]
    send: String,
    matches: String,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct RawInitializer {
    module: PathBuf,
    #[serde(default)]
    args: Vec<String>,
}

impl Manifest {
    /// Parse and validate a manifest, resolving package paths relative to
    /// it. A package path must stay inside the package: plain relative
    /// components only, and what it resolves to — through any symlink —
    /// under the manifest's directory, so a package cannot reference
    /// files its digest does not cover.
    ///
    /// # Errors
    ///
    /// Returns an error for unreadable or invalid TOML, unsupported keys,
    /// absolute or escaping package paths, invalid mount paths, or
    /// missing artifacts.
    pub fn load(path: &Path) -> Result<Self> {
        let contents = fs::read_to_string(path)
            .with_context(|| format!("failed to read manifest {}", path.display()))?;
        let raw: RawManifest = toml::from_str(&contents)
            .with_context(|| format!("failed to parse manifest {}", path.display()))?;
        let directory = path
            .parent()
            .context("manifest path has no parent directory")?
            .to_path_buf();
        let canonical = fs::canonicalize(&directory).with_context(|| {
            format!(
                "failed to resolve package directory {}",
                directory.display()
            )
        })?;

        ensure!(
            !raw.service.name.is_empty(),
            "service name must not be empty"
        );
        ensure!(
            !raw.service.version.is_empty(),
            "service version must not be empty"
        );

        let prepare = raw
            .prepare
            .map(|table| resolve_prepare(table, &directory, &canonical))
            .transpose()?;
        let guest = Guest {
            module: resolve_module(&directory, &canonical, &raw.guest.module, "guest module")?,
            args: raw.guest.args,
            listen_port: raw.guest.listen_port,
            ready: raw
                .guest
                .ready
                .map(|probe| {
                    Ok::<ReadyProbe, anyhow::Error>(ReadyProbe {
                        send: decode_byte_string(&probe.send)
                            .context("invalid ready probe send bytes")?,
                        matches: regex::bytes::Regex::new(&probe.matches)
                            .context("invalid ready probe pattern")?,
                    })
                })
                .transpose()?,
        };
        let initializer = raw
            .initializer
            .map(|table| {
                Ok::<Initializer, anyhow::Error>(Initializer {
                    module: resolve_module(
                        &directory,
                        &canonical,
                        &table.module,
                        "initializer module",
                    )?,
                    args: table.args,
                })
            })
            .transpose()?;

        Ok(Self {
            service: raw.service,
            prepare,
            guest,
            initializer,
            directory,
        })
    }

    /// Return the directory containing this manifest.
    #[must_use]
    pub fn directory(&self) -> &Path {
        &self.directory
    }

    /// Return every module referenced by this manifest in execution order.
    #[must_use]
    pub fn modules(&self) -> Vec<&Path> {
        let mut modules = Vec::with_capacity(3);
        if let Some(module) = self
            .prepare
            .as_ref()
            .and_then(|table| table.module.as_deref())
        {
            modules.push(module);
        }
        modules.push(&self.guest.module);
        if let Some(table) = &self.initializer {
            modules.push(&table.module);
        }
        modules
    }
}

impl Prepare {
    /// Read the package file configured as the prepare module's standard input.
    ///
    /// An absent `stdin_file` produces an empty input stream.
    ///
    /// # Errors
    ///
    /// Returns an error when the configured file can no longer be read.
    pub fn read_stdin(&self) -> Result<Vec<u8>> {
        self.stdin_file
            .as_ref()
            .map(|path| {
                fs::read(path).with_context(|| {
                    format!("failed to read prepare stdin file {}", path.display())
                })
            })
            .transpose()
            .map(Option::unwrap_or_default)
    }
}

fn resolve_prepare(raw: RawPrepare, directory: &Path, canonical: &Path) -> Result<Prepare> {
    let mut mounts = BTreeMap::new();
    for (guest, source) in raw.fs {
        ensure!(
            guest.is_absolute(),
            "prepare mount path {} must be absolute",
            guest.display()
        );
        ensure!(
            !guest
                .components()
                .any(|part| matches!(part, std::path::Component::ParentDir)),
            "prepare mount path {} must not contain '..'",
            guest.display()
        );
        reject_escape(&source, "prepare mount source")?;
        let resolved = directory.join(&source);
        ensure!(
            resolved.is_dir(),
            "prepare mount source {} is not a directory",
            resolved.display()
        );
        ensure_contained(&resolved, canonical, "prepare mount source")?;
        mounts.insert(guest, resolved);
    }

    let module = raw
        .module
        .as_deref()
        .map(|path| resolve_module(directory, canonical, path, "prepare module"))
        .transpose()?;
    let stdin_file = raw
        .stdin_file
        .as_deref()
        .map(|path| resolve_file(directory, canonical, path, "prepare stdin file"))
        .transpose()?;

    Ok(Prepare {
        fs: mounts,
        module,
        args: raw.args,
        stdin_file,
    })
}

/// Decode a manifest byte string: printable ASCII verbatim, `\xNN` for any
/// byte, `\\` for a backslash. Everything else is refused, so a typo fails
/// the load rather than the probe, and the manifest stays reviewable.
fn decode_byte_string(source: &str) -> Result<Vec<u8>> {
    let mut bytes = Vec::with_capacity(source.len());
    let mut chars = source.chars();
    while let Some(ch) = chars.next() {
        match ch {
            '\\' => match chars.next() {
                Some('\\') => bytes.push(b'\\'),
                Some('x') => {
                    let high = chars.next().and_then(|c| c.to_digit(16));
                    let low = chars.next().and_then(|c| c.to_digit(16));
                    match (high, low) {
                        (Some(high), Some(low)) => bytes.push(
                            u8::try_from(high * 16 + low).expect("two hex digits fit a byte"),
                        ),
                        _ => bail!("\\x needs two hex digits"),
                    }
                }
                other => bail!(
                    "unsupported escape {}",
                    other.map_or_else(|| "at end of string".to_owned(), |c| format!("\\{c}"))
                ),
            },
            ' '..='~' => bytes.push(ch as u8),
            _ => bail!("unsupported character {ch:?}; escape bytes as \\xNN"),
        }
    }
    Ok(bytes)
}

fn resolve_module(
    directory: &Path,
    canonical: &Path,
    path: &Path,
    description: &str,
) -> Result<PathBuf> {
    resolve_file(directory, canonical, path, description)
}

fn resolve_file(
    directory: &Path,
    canonical: &Path,
    path: &Path,
    description: &str,
) -> Result<PathBuf> {
    reject_escape(path, description)?;
    let resolved = directory.join(path);
    ensure!(
        resolved.is_file(),
        "{description} {} is not a file",
        resolved.display()
    );
    ensure_contained(&resolved, canonical, description)?;
    Ok(resolved)
}

/// A package path must be plain names and `.`, nothing else: no root and
/// no `..`, so it cannot name anything above the manifest's directory.
fn reject_escape(path: &Path, description: &str) -> Result<()> {
    // `.` components are harmless — `.` itself mounts the package root —
    // and containment is enforced through the canonical path anyway; only
    // parent, root and prefix components can try to leave.
    if !path.components().all(|part| {
        matches!(
            part,
            std::path::Component::Normal(_) | std::path::Component::CurDir
        )
    }) {
        bail!(
            "{description} {} must be a plain relative path inside the package",
            path.display()
        );
    }
    Ok(())
}

/// What the path resolves to — through any symlink — must stay under the
/// package directory, so nothing outside the package's digest is used.
fn ensure_contained(resolved: &Path, canonical_directory: &Path, description: &str) -> Result<()> {
    let canonical = fs::canonicalize(resolved)
        .with_context(|| format!("failed to resolve {description} {}", resolved.display()))?;
    ensure!(
        canonical.starts_with(canonical_directory),
        "{description} {} resolves outside the package",
        resolved.display()
    );
    Ok(())
}

#[cfg(test)]
mod tests {
    use std::{
        fs,
        sync::atomic::{AtomicUsize, Ordering},
    };

    use super::*;

    static NEXT_DIRECTORY: AtomicUsize = AtomicUsize::new(0);

    struct TestDirectory(PathBuf);

    impl TestDirectory {
        fn new() -> Self {
            let sequence = NEXT_DIRECTORY.fetch_add(1, Ordering::Relaxed);
            let path = std::env::temp_dir().join(format!(
                "servicecache-manifest-test-{}-{sequence}",
                std::process::id()
            ));
            fs::create_dir(&path).expect("create test directory");
            Self(path)
        }

        fn write(&self, relative: &str, contents: &str) {
            fs::write(self.0.join(relative), contents).expect("write test file");
        }
    }

    impl Drop for TestDirectory {
        fn drop(&mut self) {
            fs::remove_dir_all(&self.0).expect("remove test directory");
        }
    }

    #[test]
    fn resolves_relative_module_paths() {
        let directory = TestDirectory::new();
        directory.write("server.wasm", "module");
        directory.write(
            "service.toml",
            r#"
                [service]
                name = "example"
                version = "1"

                [guest]
                module = "server.wasm"
                listen_port = 1234
            "#,
        );

        let manifest = Manifest::load(&directory.0.join("service.toml")).expect("load manifest");
        assert_eq!(manifest.guest.module, directory.0.join("server.wasm"));
    }

    /// A manifest for `directory` whose guest module is `module`.
    fn manifest_with_module(directory: &TestDirectory, module: &str) {
        directory.write(
            "service.toml",
            &format!(
                r#"
                    [service]
                    name = "example"
                    version = "1"

                    [guest]
                    module = "{module}"
                    listen_port = 1234
                "#
            ),
        );
    }

    #[test]
    fn rejects_paths_that_leave_the_package() {
        let directory = TestDirectory::new();
        let outside = TestDirectory::new();
        outside.write("server.wasm", "module");

        // `..` components are refused before anything is resolved.
        manifest_with_module(&directory, "../server.wasm");
        let error = Manifest::load(&directory.0.join("service.toml")).expect_err("escape");
        assert!(
            error.to_string().contains("plain relative path"),
            "{error:#}"
        );

        // A lexically clean path whose symlink resolves outside is refused
        // too: the package's digest would not cover what runs.
        std::os::unix::fs::symlink(
            outside.0.join("server.wasm"),
            directory.0.join("server.wasm"),
        )
        .expect("symlink");
        manifest_with_module(&directory, "server.wasm");
        let error = Manifest::load(&directory.0.join("service.toml")).expect_err("symlink escape");
        assert!(
            error.to_string().contains("resolves outside the package"),
            "{error:#}"
        );
    }

    #[test]
    fn mounts_the_package_root_as_a_source() {
        let directory = TestDirectory::new();
        directory.write("server.wasm", "module");
        directory.write(
            "service.toml",
            r#"
                [service]
                name = "example"
                version = "1"

                [prepare]
                fs = { "/service" = "." }

                [guest]
                module = "server.wasm"
                listen_port = 1234
            "#,
        );
        let manifest = Manifest::load(&directory.0.join("service.toml")).expect("load manifest");
        let prepare = manifest.prepare.expect("a prepare step");
        assert_eq!(prepare.fs[&PathBuf::from("/service")], directory.0);
        assert!(manifest.service.extensions.is_empty());
    }

    #[test]
    fn byte_strings_decode_strictly() {
        assert_eq!(
            decode_byte_string(r"user\x00example\x00\\").expect("decode"),
            b"user\0example\0\\"
        );
        assert_eq!(decode_byte_string("").expect("decode"), b"");
        for bad in [r"\q", r"\x0", r"\x0g", "\\", "caf\u{e9}", "tab\there"] {
            assert!(decode_byte_string(bad).is_err(), "{bad:?} must be refused");
        }
    }

    #[test]
    fn ready_probes_are_parsed() {
        let directory = TestDirectory::new();
        directory.write("server.wasm", "module");
        directory.write(
            "service.toml",
            r#"
                [service]
                name = "example"
                version = "1"

                [guest]
                module = "server.wasm"
                listen_port = 1234
                ready = { send = '\x00ping', matches = '^ok\x00' }
            "#,
        );
        let manifest = Manifest::load(&directory.0.join("service.toml")).expect("load manifest");
        let probe = manifest.guest.ready.expect("a probe");
        assert_eq!(probe.send, b"\x00ping");
        assert!(probe.matches.is_match(b"ok\x00v1"));
        assert!(!probe.matches.is_match(b"no\x00starting"));
    }

    #[test]
    fn a_probe_may_send_nothing_where_the_server_speaks_first() {
        let directory = TestDirectory::new();
        directory.write("server.wasm", "module");
        directory.write(
            "service.toml",
            r#"
                [service]
                name = "example"
                version = "1"

                [guest]
                module = "server.wasm"
                listen_port = 1234
                ready = { matches = '(?s-u)\A.{2}\x02' }
            "#,
        );
        let manifest = Manifest::load(&directory.0.join("service.toml")).expect("load manifest");
        let probe = manifest.guest.ready.expect("a probe");
        assert_eq!(probe.send, b"");
        assert!(probe.matches.is_match(b"\x0a\x80\x02hello"));
        assert!(!probe.matches.is_match(b"\x0a\x80\x03"));
    }

    #[test]
    fn service_extensions_are_parsed() {
        let directory = TestDirectory::new();
        directory.write("server.wasm", "module");
        directory.write(
            "service.toml",
            r#"
                [service]
                name = "example"
                version = "1"
                extensions = ["ictrobot_shm_v1"]

                [guest]
                module = "server.wasm"
                listen_port = 1234
            "#,
        );
        let manifest = Manifest::load(&directory.0.join("service.toml")).expect("load manifest");
        assert_eq!(manifest.service.extensions, ["ictrobot_shm_v1"]);
    }

    #[test]
    fn rejects_mount_sources_that_leave_the_package() {
        let directory = TestDirectory::new();
        directory.write("server.wasm", "module");
        directory.write(
            "service.toml",
            r#"
                [service]
                name = "example"
                version = "1"

                [prepare]
                fs = { "/usr/share/example" = "../share" }

                [guest]
                module = "server.wasm"
                listen_port = 1234
            "#,
        );
        let error = Manifest::load(&directory.0.join("service.toml")).expect_err("escape");
        assert!(
            error.to_string().contains("plain relative path"),
            "{error:#}"
        );
    }

    #[test]
    fn follows_symlinks_that_stay_inside_the_package() {
        let directory = TestDirectory::new();
        directory.write("real.wasm", "module");
        std::os::unix::fs::symlink("real.wasm", directory.0.join("server.wasm")).expect("symlink");
        manifest_with_module(&directory, "server.wasm");
        let manifest = Manifest::load(&directory.0.join("service.toml")).expect("load manifest");
        assert_eq!(manifest.guest.module, directory.0.join("server.wasm"));
    }

    #[test]
    fn resolves_all_run_tables_and_mounts() {
        let directory = TestDirectory::new();
        fs::create_dir(directory.0.join("share")).expect("create mounted directory");
        directory.write("prepare.wasm", "prepare");
        directory.write("bootstrap.sql", "select 1;\n");
        directory.write("server.wasm", "server");
        directory.write("client.wasm", "client");
        directory.write(
            "service.toml",
            r#"
                [service]
                name = "example"
                version = "1"

                [prepare]
                fs = { "/usr/share/example" = "share" }
                module = "prepare.wasm"
                args = ["--prepare"]
                stdin_file = "bootstrap.sql"

                [guest]
                module = "server.wasm"
                args = ["--serve"]
                listen_port = 1234

                [initializer]
                module = "client.wasm"
                args = ["--initialize"]
            "#,
        );

        let manifest = Manifest::load(&directory.0.join("service.toml")).expect("load manifest");
        let prepare = manifest.prepare.as_ref().expect("prepare table");
        assert_eq!(
            prepare.fs.get(Path::new("/usr/share/example")),
            Some(&directory.0.join("share"))
        );
        assert_eq!(prepare.module, Some(directory.0.join("prepare.wasm")));
        assert_eq!(prepare.stdin_file, Some(directory.0.join("bootstrap.sql")));
        assert_eq!(prepare.read_stdin().expect("read stdin"), b"select 1;\n");
        assert_eq!(manifest.guest.module, directory.0.join("server.wasm"));
        assert_eq!(
            manifest.initializer.as_ref().expect("initializer").module,
            directory.0.join("client.wasm")
        );
        assert_eq!(manifest.modules().len(), 3);
    }

    #[test]
    fn rejects_unknown_keys() {
        let directory = TestDirectory::new();
        directory.write("server.wasm", "module");
        directory.write(
            "service.toml",
            r#"
                [service]
                name = "example"
                version = "1"
                unsupported = true

                [guest]
                module = "server.wasm"
                listen_port = 1234
            "#,
        );

        let error =
            Manifest::load(&directory.0.join("service.toml")).expect_err("unknown key should fail");
        assert!(error.to_string().contains("failed to parse manifest"));
    }

    #[test]
    fn rejects_absolute_and_missing_modules() {
        let directory = TestDirectory::new();
        directory.write(
            "service.toml",
            r#"
                [service]
                name = "example"
                version = "1"

                [guest]
                module = "/server.wasm"
                listen_port = 1234
            "#,
        );
        let absolute_error = Manifest::load(&directory.0.join("service.toml"))
            .expect_err("absolute path should fail");
        assert!(absolute_error.to_string().contains("plain relative path"));

        directory.write(
            "service.toml",
            r#"
                [service]
                name = "example"
                version = "1"

                [guest]
                module = "missing.wasm"
                listen_port = 1234
            "#,
        );
        let missing_error = Manifest::load(&directory.0.join("service.toml"))
            .expect_err("missing path should fail");
        assert!(missing_error.to_string().contains("is not a file"));
    }

    #[test]
    fn rejects_absolute_and_missing_mount_sources() {
        let directory = TestDirectory::new();
        directory.write("server.wasm", "module");
        directory.write(
            "service.toml",
            r#"
                [service]
                name = "example"
                version = "1"

                [prepare]
                fs = { "/mounted" = "/host" }

                [guest]
                module = "server.wasm"
                listen_port = 1234
            "#,
        );
        let absolute_error = Manifest::load(&directory.0.join("service.toml"))
            .expect_err("absolute mount source should fail");
        assert!(absolute_error.to_string().contains("plain relative path"));

        directory.write(
            "service.toml",
            r#"
                [service]
                name = "example"
                version = "1"

                [prepare]
                fs = { "/mounted" = "missing" }

                [guest]
                module = "server.wasm"
                listen_port = 1234
            "#,
        );
        let missing_error = Manifest::load(&directory.0.join("service.toml"))
            .expect_err("missing mount source should fail");
        assert!(missing_error.to_string().contains("is not a directory"));
    }

    #[test]
    fn rejects_absolute_and_missing_prepare_stdin_files() {
        let directory = TestDirectory::new();
        directory.write("prepare.wasm", "prepare");
        directory.write("server.wasm", "server");
        directory.write(
            "service.toml",
            r#"
                [service]
                name = "example"
                version = "1"

                [prepare]
                module = "prepare.wasm"
                stdin_file = "/bootstrap.sql"

                [guest]
                module = "server.wasm"
                listen_port = 1234
            "#,
        );
        let absolute_error = Manifest::load(&directory.0.join("service.toml"))
            .expect_err("absolute stdin path should fail");
        assert!(absolute_error.to_string().contains("plain relative path"));

        directory.write(
            "service.toml",
            r#"
                [service]
                name = "example"
                version = "1"

                [prepare]
                module = "prepare.wasm"
                stdin_file = "missing.sql"

                [guest]
                module = "server.wasm"
                listen_port = 1234
            "#,
        );
        let missing_error = Manifest::load(&directory.0.join("service.toml"))
            .expect_err("missing stdin path should fail");
        assert!(missing_error.to_string().contains("is not a file"));
    }
}
