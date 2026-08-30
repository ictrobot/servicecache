//! Every assembled service comes up through `servicecache host`: prepare,
//! start on a socket the manager passed, initialize with the recipe its
//! adapter provides, answer the adapter's check, stop. Skipped for services
//! that are not built or have no adapter.

#[path = "support/service_adapter.rs"]
mod service_adapter;

use std::path::{Path, PathBuf};

use service_adapter::ServiceAdapter;
use servicecache::{manager::HostProcess, manifest::Manifest};

fn repo_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../..")
}

fn manifests() -> Vec<PathBuf> {
    let root = repo_root().join("work/services");
    let Ok(entries) = std::fs::read_dir(&root) else {
        eprintln!(
            "skipped: {} is not built (run `make services`)",
            root.display()
        );
        return Vec::new();
    };
    let mut manifests: Vec<PathBuf> = entries
        .filter_map(Result::ok)
        .map(|entry| entry.path().join("service.toml"))
        .filter(|path| path.is_file())
        .collect();
    manifests.sort();
    manifests
}

fn run_through_host(manifest_path: &Path) {
    let manifest = Manifest::load(manifest_path).expect("load the manifest");
    let name = manifest.service.name.clone();
    let Some(adapter) = ServiceAdapter::find(&repo_root(), &name) else {
        eprintln!("skipped: {name} has no adapter");
        return;
    };

    let binary = Path::new(env!("CARGO_BIN_EXE_servicecache"));
    let cache_dir =
        servicecache::cache::directory(None, std::env::var_os("SERVICECACHE_CACHE_DIR").as_deref())
            .expect("a cache directory");
    let mut host =
        HostProcess::spawn_with_binary(binary, manifest_path, &cache_dir).expect("spawn the host");
    if manifest.prepare.is_some() {
        assert_eq!(host.prepare().expect("prepare"), 0, "{name}: prepare");
    }
    let endpoint = host.start().expect("start");
    if manifest.initializer.is_some() {
        assert_eq!(
            host.initialize(&adapter.recipe()).expect("initialize"),
            0,
            "{name}: initializer"
        );
    }
    adapter.check_initialized(endpoint);
    host.stop().expect("stop");
}

#[test]
fn every_built_service_comes_up_through_the_host() {
    for manifest in manifests() {
        run_through_host(&manifest);
    }
}
