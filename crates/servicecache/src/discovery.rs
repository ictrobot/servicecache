use std::{
    collections::{BTreeMap, btree_map::Entry},
    fs::{self, File},
    io::{self, Read},
    path::{Path, PathBuf},
};

use anyhow::{Context, Result, bail};
use sha2::{Digest, Sha256};

use crate::manifest::Manifest;

/// A file in a service package and its SHA-256 content digest.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ContentDigest {
    pub path: PathBuf,
    pub sha256: String,
}

/// A package hidden by an earlier package with the same name and version.
#[derive(Debug, Clone)]
pub struct ShadowedPackage {
    pub directory: PathBuf,
    pub manifest: Manifest,
}

impl ShadowedPackage {
    /// The package's files with their content digests, hashed on demand.
    ///
    /// # Errors
    ///
    /// Returns an error when a file cannot be read, or the package
    /// contains a symbolic link.
    pub fn files(&self) -> Result<Vec<ContentDigest>> {
        digest_tree(&self.directory)
    }
}

/// The selected package for a name and version. Discovery reads only the
/// manifests; a package's content is hashed on demand, since the trees are
/// large and most commands never look at them.
#[derive(Debug, Clone)]
pub struct DiscoveredPackage {
    pub manifest: Manifest,
    pub shadowed: Vec<ShadowedPackage>,
}

impl DiscoveredPackage {
    /// The package's files with their content digests, hashed on demand.
    ///
    /// # Errors
    ///
    /// Returns an error when a file cannot be read, or the package
    /// contains a symbolic link.
    pub fn files(&self) -> Result<Vec<ContentDigest>> {
        digest_tree(self.manifest.directory())
    }
}

/// Why a name (and optional version) selected no single service.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SelectError {
    /// Nothing installed matches.
    NotFound,
    /// The bare name matches several installed versions.
    Ambiguous(Vec<String>),
}

/// Services indexed by their exact name and version.
#[derive(Debug, Default)]
pub struct ServiceIndex {
    packages: BTreeMap<(String, String), DiscoveredPackage>,
}

impl ServiceIndex {
    /// Discover `*/service.toml` below each search directory.
    ///
    /// Search directories and their children are inspected in order. The first
    /// package for an exact name and version is selected and later packages are
    /// recorded as shadowed.
    ///
    /// # Errors
    ///
    /// Returns an error when a search directory cannot be read, or a discovered
    /// package has an invalid manifest or unreadable file.
    pub fn discover(search_dirs: &[PathBuf]) -> Result<Self> {
        let mut index = Self::default();
        for search_dir in search_dirs {
            let mut manifests = manifests_in(search_dir)?;
            manifests.sort();
            for manifest_path in manifests {
                index.insert(&manifest_path)?;
            }
        }
        Ok(index)
    }

    /// Iterate over selected packages in name and version order.
    pub fn iter(&self) -> impl Iterator<Item = &DiscoveredPackage> {
        self.packages.values()
    }

    /// The manifest for `name` at `version`; a bare name selects the only
    /// installed version.
    ///
    /// # Errors
    ///
    /// [`SelectError::NotFound`] when nothing matches;
    /// [`SelectError::Ambiguous`] when a bare name matches several versions.
    pub fn select(&self, name: &str, version: Option<&str>) -> Result<&Manifest, SelectError> {
        let mut candidates = self
            .packages
            .values()
            .map(|package| &package.manifest)
            .filter(|manifest| manifest.service.name == name)
            .filter(|manifest| version.is_none_or(|version| manifest.service.version == version));
        match (candidates.next(), candidates.next()) {
            (None, _) => Err(SelectError::NotFound),
            (Some(manifest), None) => Ok(manifest),
            (Some(first), Some(second)) => {
                let mut versions = vec![
                    first.service.version.clone(),
                    second.service.version.clone(),
                ];
                versions.extend(candidates.map(|manifest| manifest.service.version.clone()));
                Err(SelectError::Ambiguous(versions))
            }
        }
    }

    /// Iterate over every selected and shadowed package.
    pub fn all_packages(&self) -> impl Iterator<Item = (&Manifest, &Path)> {
        self.packages.values().flat_map(|package| {
            std::iter::once((&package.manifest, package.manifest.directory())).chain(
                package
                    .shadowed
                    .iter()
                    .map(|shadow| (&shadow.manifest, shadow.directory.as_path())),
            )
        })
    }

    fn insert(&mut self, manifest_path: &Path) -> Result<()> {
        let manifest = Manifest::load(manifest_path)?;
        let key = (
            manifest.service.name.clone(),
            manifest.service.version.clone(),
        );

        match self.packages.entry(key) {
            Entry::Vacant(entry) => {
                entry.insert(DiscoveredPackage {
                    manifest,
                    shadowed: Vec::new(),
                });
            }
            Entry::Occupied(mut entry) => {
                entry.get_mut().shadowed.push(ShadowedPackage {
                    directory: manifest.directory().to_path_buf(),
                    manifest,
                });
            }
        }
        Ok(())
    }
}

fn manifests_in(search_dir: &Path) -> Result<Vec<PathBuf>> {
    let entries = match fs::read_dir(search_dir) {
        Ok(entries) => entries,
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(Vec::new()),
        Err(error) => {
            return Err(error).with_context(|| {
                format!("failed to read services directory {}", search_dir.display())
            });
        }
    };

    let mut manifests = Vec::new();
    for entry in entries {
        let entry = entry.with_context(|| {
            format!(
                "failed to read entry in services directory {}",
                search_dir.display()
            )
        })?;
        if entry
            .file_type()
            .with_context(|| format!("failed to inspect {}", entry.path().display()))?
            .is_dir()
        {
            let manifest = entry.path().join("service.toml");
            if manifest.is_file() {
                manifests.push(manifest);
            }
        }
    }
    Ok(manifests)
}

fn digest_tree(directory: &Path) -> Result<Vec<ContentDigest>> {
    let mut files = Vec::new();
    let mut pending = vec![directory.to_path_buf()];
    while let Some(current) = pending.pop() {
        let mut entries = fs::read_dir(&current)
            .with_context(|| format!("failed to read package directory {}", current.display()))?
            .collect::<io::Result<Vec<_>>>()
            .with_context(|| format!("failed to read package directory {}", current.display()))?;
        entries.sort_by_key(fs::DirEntry::file_name);

        for entry in entries {
            let file_type = entry
                .file_type()
                .with_context(|| format!("failed to inspect {}", entry.path().display()))?;
            if file_type.is_dir() {
                pending.push(entry.path());
            } else if file_type.is_file() {
                let path = entry.path();
                files.push(ContentDigest {
                    path: path
                        .strip_prefix(directory)
                        .expect("walked paths stay under the package directory")
                        .to_path_buf(),
                    sha256: digest_file(&path)?,
                });
            } else if file_type.is_symlink() {
                bail!(
                    "package entry {} is a symbolic link",
                    entry.path().display()
                );
            }
        }
    }
    files.sort_by(|left, right| left.path.cmp(&right.path));
    Ok(files)
}

fn digest_file(path: &Path) -> Result<String> {
    let mut file = File::open(path)
        .with_context(|| format!("failed to open package file {}", path.display()))?;
    let mut hasher = Sha256::new();
    let mut buffer = vec![0_u8; 64 * 1024];
    loop {
        let count = file
            .read(&mut buffer)
            .with_context(|| format!("failed to read package file {}", path.display()))?;
        if count == 0 {
            break;
        }
        hasher.update(&buffer[..count]);
    }
    Ok(format!("{:x}", hasher.finalize()))
}

#[cfg(test)]
mod tests {
    use std::sync::atomic::{AtomicUsize, Ordering};

    use super::*;

    static NEXT_DIRECTORY: AtomicUsize = AtomicUsize::new(0);

    struct TestDirectory(PathBuf);

    impl TestDirectory {
        fn new() -> Self {
            let sequence = NEXT_DIRECTORY.fetch_add(1, Ordering::Relaxed);
            let path = std::env::temp_dir().join(format!(
                "servicecache-discovery-test-{}-{sequence}",
                std::process::id()
            ));
            fs::create_dir(&path).expect("create test directory");
            Self(path)
        }

        fn package(&self, directory: &str, marker: &str) {
            let path = self.0.join(directory);
            fs::create_dir(&path).expect("create package directory");
            fs::write(path.join("module.wasm"), marker).expect("write module");
            fs::write(
                path.join("service.toml"),
                r#"
                    [service]
                    name = "example"
                    version = "1"

                    [guest]
                    module = "module.wasm"
                    listen_port = 1234
                "#,
            )
            .expect("write manifest");
        }
    }

    impl Drop for TestDirectory {
        fn drop(&mut self) {
            fs::remove_dir_all(&self.0).expect("remove test directory");
        }
    }

    #[test]
    fn first_package_wins_and_later_package_is_shadowed() {
        let first = TestDirectory::new();
        let second = TestDirectory::new();
        first.package("first", "one");
        second.package("second", "two");

        let index = ServiceIndex::discover(&[first.0.clone(), second.0.clone()])
            .expect("discover services");
        let package = index.iter().next().expect("selected package");
        assert_eq!(package.manifest.directory(), first.0.join("first"));
        assert_eq!(package.shadowed.len(), 1);
        assert_eq!(package.shadowed[0].directory, second.0.join("second"));
        assert_eq!(package.files().expect("hash the package").len(), 2);
        assert_eq!(
            package.shadowed[0].files().expect("hash the shadow").len(),
            2
        );
    }
}
