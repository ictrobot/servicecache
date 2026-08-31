use std::{
    future::Future,
    io::{Read, Write},
    path::{Path, PathBuf},
    pin::Pin,
    sync::Arc,
};

use anyhow::{Context, Result};
use wasmer::{Engine, Module, Store};

use crate::cache::ModuleCache;
use wasmer_wasix::{
    Pipe, PluggableRuntime, UnsupportedVirtualNetworking, WasiEnv, WasiError,
    runtime::task_manager::tokio::TokioTaskManager,
    virtual_fs::{
        FileOpener, FileSystem, FsError, Metadata, MountFileSystem, OpenOptions, OpenOptionsConfig,
        ReadDir, RootFileSystemBuilder, VirtualFile, host_fs::FileSystem as HostFileSystem,
    },
};

/// A read-only directory to mount inside the guest filesystem.
#[derive(Debug, Clone)]
pub struct ReadOnlyMount {
    pub guest: PathBuf,
    pub host: PathBuf,
}

/// Inputs for one WASIX module run.
#[derive(Debug)]
pub struct RunRequest<'a> {
    pub module: &'a Path,
    pub args: &'a [String],
    pub stdin: &'a [u8],
    pub mounts: &'a [ReadOnlyMount],
}

/// Captured results from a completed WASIX module run.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RunOutput {
    pub status: i32,
    pub stdout: Vec<u8>,
    pub stderr: Vec<u8>,
}

/// The embedded stock Wasmer runtime.
#[derive(Debug, Clone, Default)]
pub struct Runtime {
    engine: Engine,
    /// Compiled modules on disk; without it every load compiles.
    cache: Option<ModuleCache>,
}

impl Runtime {
    /// Construct a runtime using Wasmer's default compiler.
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }

    /// The same runtime, loading compiled modules through `cache`.
    #[must_use]
    pub fn with_cache(mut self, cache: ModuleCache) -> Self {
        self.cache = Some(cache);
        self
    }

    /// The compiled module at `path`.
    fn module(&self, path: &Path) -> Result<Module> {
        match &self.cache {
            Some(cache) => cache.load(&self.engine, path, Module::from_binary),
            None => Module::from_file(&self.engine, path)
                .with_context(|| format!("failed to compile {}", path.display())),
        }
    }

    /// Compile a module without running it.
    ///
    /// # Errors
    ///
    /// Returns an error when the module cannot be read or compiled by Wasmer.
    pub fn load(&self, path: &Path) -> Result<()> {
        self.module(path)
            .with_context(|| format!("failed to load WASIX module {}", path.display()))?;
        Ok(())
    }

    /// Run a WASIX module with isolated standard I/O, filesystem, and network.
    ///
    /// The writable root filesystem is in memory, host mounts are read-only,
    /// and all socket operations use an unsupported networking backend.
    ///
    /// # Errors
    ///
    /// Returns an error for runtime setup, module compilation, instantiation,
    /// or execution failures. A normal non-zero guest exit is returned in the
    /// output status.
    pub fn run(&self, request: &RunRequest<'_>) -> Result<RunOutput> {
        let tokio_runtime = tokio::runtime::Builder::new_multi_thread()
            .enable_all()
            .build()
            .context("failed to create WASIX task runtime")?;
        let _runtime_guard = tokio_runtime.enter();

        let module = self.module(request.module)?;
        let mut store = Store::new(self.engine.clone());
        let filesystem = read_only_mounts(request.mounts, tokio_runtime.handle())?;

        let (mut stdin_writer, stdin_reader) = Pipe::channel();
        stdin_writer
            .write_all(request.stdin)
            .context("failed to buffer guest stdin")?;
        drop(stdin_writer);
        let (stdout_writer, mut stdout_reader) = Pipe::channel();
        let (stderr_writer, mut stderr_reader) = Pipe::channel();

        let task_manager = Arc::new(TokioTaskManager::new(tokio_runtime.handle().clone()));
        let mut runtime = PluggableRuntime::new(task_manager);
        runtime.set_engine(self.engine.clone());
        runtime.set_networking_implementation(UnsupportedVirtualNetworking::default());
        runtime.http_client = None;

        let program_name = request
            .module
            .file_name()
            .and_then(std::ffi::OsStr::to_str)
            .unwrap_or("module");
        let mut builder = WasiEnv::builder(program_name)
            .args(request.args)
            .stdin(Box::new(stdin_reader))
            .stdout(Box::new(stdout_writer))
            .stderr(Box::new(stderr_writer))
            .mount_fs(filesystem)
            .runtime(Arc::new(runtime));
        builder.add_mapped_command(program_name, request.module.to_string_lossy());
        builder.add_preopen_build(|preopen| {
            preopen
                .directory("/")
                .alias(".")
                .read(true)
                .write(true)
                .create(true)
        })?;
        builder.add_preopen_dir("/")?;

        let status = {
            let (instance, _environment) = builder
                .instantiate(module, &mut store)
                .context("failed to instantiate WASIX module")?;
            let start = instance
                .exports
                .get_function("_start")
                .context("WASIX module does not export _start")?;
            match start.call(&mut store, &[]) {
                Ok(_) => 0,
                Err(error) => match error.downcast_ref::<WasiError>() {
                    Some(WasiError::Exit(code)) => code.raw(),
                    _ => return Err(error).context("WASIX module execution failed"),
                },
            }
        };

        drop(store);
        let mut stdout = Vec::new();
        stdout_reader
            .read_to_end(&mut stdout)
            .context("failed to read guest stdout")?;
        let mut stderr = Vec::new();
        stderr_reader
            .read_to_end(&mut stderr)
            .context("failed to read guest stderr")?;

        Ok(RunOutput {
            status,
            stdout,
            stderr,
        })
    }
}

/// An in-memory root filesystem with `mounts` as read-only host directories.
///
/// Nothing is created under the root: a guest's data directory must not
/// exist until the guest makes it.
///
/// # Errors
///
/// Fails if a mount cannot be opened or mounted.
pub fn read_only_mounts(
    mounts: &[ReadOnlyMount],
    handle: &tokio::runtime::Handle,
) -> Result<MountFileSystem> {
    let filesystem = RootFileSystemBuilder::default().build();
    for mount in mounts {
        let host = HostFileSystem::new(handle.clone(), &mount.host)
            .with_context(|| format!("failed to open host mount {}", mount.host.display()))?;
        filesystem
            .mount(&mount.guest, Arc::new(ReadOnlyFileSystem { inner: host }))
            .with_context(|| {
                format!(
                    "failed to mount {} at {}",
                    mount.host.display(),
                    mount.guest.display()
                )
            })?;
    }
    Ok(filesystem)
}

#[derive(Debug)]
struct ReadOnlyFileSystem {
    inner: HostFileSystem,
}

impl FileSystem for ReadOnlyFileSystem {
    fn readlink(&self, path: &Path) -> wasmer_wasix::virtual_fs::Result<PathBuf> {
        self.inner.readlink(path)
    }

    fn read_dir(&self, path: &Path) -> wasmer_wasix::virtual_fs::Result<ReadDir> {
        self.inner.read_dir(path)
    }

    fn create_dir(&self, _path: &Path) -> wasmer_wasix::virtual_fs::Result<()> {
        Err(FsError::PermissionDenied)
    }

    fn create_symlink(
        &self,
        _source: &Path,
        _target: &Path,
    ) -> wasmer_wasix::virtual_fs::Result<()> {
        Err(FsError::PermissionDenied)
    }

    fn hard_link(&self, _source: &Path, _target: &Path) -> wasmer_wasix::virtual_fs::Result<()> {
        Err(FsError::PermissionDenied)
    }

    fn remove_dir(&self, _path: &Path) -> wasmer_wasix::virtual_fs::Result<()> {
        Err(FsError::PermissionDenied)
    }

    fn rename<'a>(
        &'a self,
        _from: &'a Path,
        _to: &'a Path,
    ) -> Pin<Box<dyn Future<Output = wasmer_wasix::virtual_fs::Result<()>> + Send + 'a>> {
        Box::pin(async { Err(FsError::PermissionDenied) })
    }

    fn metadata(&self, path: &Path) -> wasmer_wasix::virtual_fs::Result<Metadata> {
        self.inner.metadata(path)
    }

    fn symlink_metadata(&self, path: &Path) -> wasmer_wasix::virtual_fs::Result<Metadata> {
        self.inner.symlink_metadata(path)
    }

    fn remove_file(&self, _path: &Path) -> wasmer_wasix::virtual_fs::Result<()> {
        Err(FsError::PermissionDenied)
    }

    fn new_open_options(&self) -> OpenOptions<'_> {
        OpenOptions::new(self)
    }
}

impl FileOpener for ReadOnlyFileSystem {
    fn open(
        &self,
        path: &Path,
        configuration: &OpenOptionsConfig,
    ) -> wasmer_wasix::virtual_fs::Result<Box<dyn VirtualFile + Send + Sync + 'static>> {
        if configuration.write
            || configuration.create
            || configuration.create_new
            || configuration.append
            || configuration.truncate
        {
            return Err(FsError::PermissionDenied);
        }
        self.inner.open(path, configuration)
    }
}

#[cfg(test)]
mod tests {
    use std::{
        fs,
        sync::atomic::{AtomicUsize, Ordering},
    };

    use wasmer_wasix::virtual_fs::{AsyncReadExt, AsyncWriteExt};

    use super::*;

    static NEXT_DIRECTORY: AtomicUsize = AtomicUsize::new(0);

    #[test]
    fn filesystem_has_writable_memory_and_read_only_host_mounts() {
        let sequence = NEXT_DIRECTORY.fetch_add(1, Ordering::Relaxed);
        let host_directory = std::env::temp_dir().join(format!(
            "servicecache-runtime-test-{}-{sequence}",
            std::process::id()
        ));
        fs::create_dir(&host_directory).expect("create host directory");
        fs::write(host_directory.join("input.txt"), "mounted").expect("write mounted test file");

        let tokio_runtime = tokio::runtime::Runtime::new().expect("create test runtime");
        let filesystem = read_only_mounts(
            &[ReadOnlyMount {
                guest: PathBuf::from("/mounted"),
                host: host_directory.clone(),
            }],
            tokio_runtime.handle(),
        )
        .expect("create guest filesystem");

        let mut mounted_file = filesystem
            .new_open_options()
            .read(true)
            .open("/mounted/input.txt")
            .expect("open mounted file");
        let mut mounted_contents = String::new();
        tokio_runtime
            .block_on(mounted_file.read_to_string(&mut mounted_contents))
            .expect("read mounted file");
        assert_eq!(mounted_contents, "mounted");
        assert_eq!(
            filesystem
                .new_open_options()
                .write(true)
                .open("/mounted/input.txt")
                .expect_err("host mount should reject writes"),
            FsError::PermissionDenied
        );

        filesystem
            .create_dir(Path::new("/data"))
            .expect("create in-memory directory");
        let mut memory_file = filesystem
            .new_open_options()
            .write(true)
            .create_new(true)
            .open("/data/output.txt")
            .expect("create in-memory file");
        tokio_runtime
            .block_on(memory_file.write_all(b"writable"))
            .expect("write in-memory file");

        drop(mounted_file);
        drop(memory_file);
        drop(filesystem);
        fs::remove_dir_all(host_directory).expect("remove host directory");
    }
}
