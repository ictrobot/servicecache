//! Building guests on the host's runtime and starting them.

use std::{
    collections::HashMap,
    io::Write as _,
    path::{Path, PathBuf},
    sync::{Arc, Mutex},
};

use anyhow::{Context as _, Result};
use virtual_fs::{MountFileSystem, Pipe, host_fs};
use wasmer::{Engine, Module};
use wasmer_wasix::{
    PluggableRuntime, Runtime, UnsupportedVirtualNetworking, WasiEnv,
    bin_factory::spawn_exec_module, os::task::TaskJoinHandle,
};

use super::{net::HostNetworking, tasks::HostTaskManager};
use crate::{
    cache::ModuleCache,
    runtime::{ReadOnlyMount, read_only_mounts},
};

/// One run of a module: the prepare step, the serving guest, or the
/// initializer.
#[derive(Debug)]
pub struct GuestRun<'a> {
    pub module: &'a Path,
    pub args: Vec<String>,
    pub stdin: &'a [u8],
    /// Whether the run gets the host's networking; the prepare step does not.
    pub network: bool,
}

/// The engine, filesystem and networking every run in this host shares.
pub struct GuestRuntime {
    engine: Engine,
    tasks: HostTaskManager,
    /// The in-memory root with the manifest's read-only mounts. Shared by
    /// every run, so the prepare step's output is what the guest starts on.
    fs: Arc<MountFileSystem>,
    networking: Arc<HostNetworking>,
    cache: ModuleCache,
    modules: Mutex<HashMap<PathBuf, Module>>,
}

impl GuestRuntime {
    /// A runtime with the given read-only host mounts, loading compiled
    /// modules through `cache`.
    ///
    /// # Errors
    ///
    /// Fails if a mount cannot be opened.
    pub fn new(
        tasks: HostTaskManager,
        mounts: &[ReadOnlyMount],
        networking: Arc<HostNetworking>,
        cache: ModuleCache,
    ) -> Result<Self> {
        let fs = read_only_mounts(mounts, &tasks.handle())?;
        Ok(Self {
            engine: Engine::default(),
            tasks,
            fs: Arc::new(fs),
            networking,
            cache,
            modules: Mutex::new(HashMap::new()),
        })
    }

    /// The compiled module at `path`, once per path: from the cache, or
    /// compiled and stored.
    ///
    /// # Errors
    ///
    /// Fails if the module cannot be read or compiled.
    pub fn module(&self, path: &Path) -> Result<Module> {
        let mut modules = self
            .modules
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        if let Some(module) = modules.get(path) {
            return Ok(module.clone());
        }
        let module = self.cache.load(&self.engine, path, |engine, bytes| {
            // The compiler parallelises with rayon, partly on the global
            // pool, whose workers would live for the rest of the process: a
            // freeze cannot allow that, and a forked child could not compile
            // against the parent's dead workers. A private pool, dropped
            // afterwards, leaves no threads behind.
            let pool = rayon::ThreadPoolBuilder::new()
                .thread_name(|i| format!("compile-{i}"))
                .build()
                .map_err(|error| wasmer::CompileError::Resource(error.to_string()))?;
            pool.install(|| Module::from_binary(engine, bytes))
        })?;
        modules.insert(path.to_path_buf(), module.clone());
        Ok(module)
    }

    /// Starts a run on its own guest threads and returns the handle to wait
    /// for its main thread.
    ///
    /// # Errors
    ///
    /// Fails if the module cannot be compiled or the guest cannot be built.
    pub fn spawn(&self, run: &GuestRun<'_>) -> Result<TaskJoinHandle> {
        let module = self.module(run.module)?;

        let mut runtime = PluggableRuntime::new(Arc::new(self.tasks.clone()));
        runtime.set_engine(self.engine.clone());
        if run.network {
            runtime.networking = self.networking.clone();
        } else {
            runtime.set_networking_implementation(UnsupportedVirtualNetworking::default());
        }
        runtime.http_client = None;
        let runtime: Arc<dyn Runtime + Send + Sync> = Arc::new(runtime);

        let (mut stdin_writer, stdin_reader) = Pipe::channel();
        stdin_writer
            .write_all(run.stdin)
            .context("failed to buffer the guest's stdin")?;
        drop(stdin_writer);

        let program_name = run
            .module
            .file_name()
            .and_then(std::ffi::OsStr::to_str)
            .unwrap_or("module");
        let fs: Arc<dyn virtual_fs::FileSystem + Send + Sync> = self.fs.clone();
        let mut builder = WasiEnv::builder(program_name)
            .args(&run.args)
            .stdin(Box::new(stdin_reader))
            .stdout(Box::new(host_fs::Stderr))
            .stderr(Box::new(host_fs::Stderr))
            .fs(fs)
            .runtime(runtime.clone());
        builder.add_preopen_build(|preopen| {
            preopen
                .directory("/")
                .alias(".")
                .read(true)
                .write(true)
                .create(true)
        })?;
        builder.add_preopen_dir("/")?;
        // The main thread runs `_start` through a plain call, not through
        // `call_async` and a thread-local executor: a suspended coroutine
        // must be resumable on another OS thread, which an executor's
        // coroutine whose parent frame is on the dead thread is not.
        builder
            .capabilities_mut()
            .threading
            .enable_asynchronous_threading = false;

        let env = builder
            .build()
            .with_context(|| format!("failed to build the environment for {program_name}"))?;
        spawn_exec_module(module, env, &runtime)
            .with_context(|| format!("failed to start {program_name}"))
    }
}

/// The exit status of a finished run, if it has finished. A run that ended
/// with a runtime error rather than an exit reports 128.
#[must_use]
pub fn exit_status(handle: &TaskJoinHandle) -> Option<i32> {
    match handle.status() {
        wasmer_wasix::os::task::TaskStatus::Finished(Ok(code)) => Some(code.raw()),
        wasmer_wasix::os::task::TaskStatus::Finished(Err(error)) => {
            Some(error.as_exit_code().map_or(128, |code| code.raw()))
        }
        _ => None,
    }
}
