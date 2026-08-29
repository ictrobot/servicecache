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
}

/// Optional filesystem preparation performed before the serving run.
#[derive(Debug, Clone)]
pub struct Prepare {
    pub fs: BTreeMap<PathBuf, PathBuf>,
    pub module: Option<PathBuf>,
    pub args: Vec<String>,
}

/// The serving module and its runtime settings.
#[derive(Debug, Clone)]
pub struct Guest {
    pub module: PathBuf,
    pub args: Vec<String>,
    pub listen_port: u16,
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
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct RawGuest {
    module: PathBuf,
    #[serde(default)]
    args: Vec<String>,
    listen_port: u16,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct RawInitializer {
    module: PathBuf,
    #[serde(default)]
    args: Vec<String>,
}

impl Manifest {
    /// Parse and validate a manifest, resolving package paths relative to it.
    ///
    /// # Errors
    ///
    /// Returns an error for unreadable or invalid TOML, unsupported keys,
    /// absolute package paths, invalid mount paths, or missing artifacts.
    pub fn load(path: &Path) -> Result<Self> {
        let contents = fs::read_to_string(path)
            .with_context(|| format!("failed to read manifest {}", path.display()))?;
        let raw: RawManifest = toml::from_str(&contents)
            .with_context(|| format!("failed to parse manifest {}", path.display()))?;
        let directory = path
            .parent()
            .context("manifest path has no parent directory")?
            .to_path_buf();

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
            .map(|table| resolve_prepare(table, &directory))
            .transpose()?;
        let guest = Guest {
            module: resolve_module(&directory, &raw.guest.module, "guest module")?,
            args: raw.guest.args,
            listen_port: raw.guest.listen_port,
        };
        let initializer = raw
            .initializer
            .map(|table| {
                Ok::<Initializer, anyhow::Error>(Initializer {
                    module: resolve_module(&directory, &table.module, "initializer module")?,
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

fn resolve_prepare(raw: RawPrepare, directory: &Path) -> Result<Prepare> {
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
        reject_absolute(&source, "prepare mount source")?;
        let resolved = directory.join(&source);
        ensure!(
            resolved.is_dir(),
            "prepare mount source {} is not a directory",
            resolved.display()
        );
        mounts.insert(guest, resolved);
    }

    let module = raw
        .module
        .as_deref()
        .map(|path| resolve_module(directory, path, "prepare module"))
        .transpose()?;

    Ok(Prepare {
        fs: mounts,
        module,
        args: raw.args,
    })
}

fn resolve_module(directory: &Path, path: &Path, description: &str) -> Result<PathBuf> {
    reject_absolute(path, description)?;
    let resolved = directory.join(path);
    ensure!(
        resolved.is_file(),
        "{description} {} is not a file",
        resolved.display()
    );
    Ok(resolved)
}

fn reject_absolute(path: &Path, description: &str) -> Result<()> {
    if path.is_absolute() {
        bail!("{description} {} must be relative", path.display());
    }
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

    #[test]
    fn resolves_all_run_tables_and_mounts() {
        let directory = TestDirectory::new();
        fs::create_dir(directory.0.join("share")).expect("create mounted directory");
        directory.write("prepare.wasm", "prepare");
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
        assert!(absolute_error.to_string().contains("must be relative"));

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
        assert!(absolute_error.to_string().contains("must be relative"));

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
}
