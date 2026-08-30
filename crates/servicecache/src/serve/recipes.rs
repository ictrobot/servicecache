//! Recipes read from files the request names, opted into with
//! `--recipe-root`. The server reads and hashes so a client never has to
//! load or encode a large recipe; the roots bound what a request can
//! name, so even a same-user proxy forwarding hostile traffic exposes at
//! most the recipe trees. Confinement is checked on the opened
//! descriptor, not the requested path, so a swapped symlink cannot slip
//! past it.

use std::{
    io::Read as _,
    os::fd::AsRawFd as _,
    path::{Path, PathBuf},
};

use anyhow::{Context as _, Result, bail};

use super::api;

/// The directories recipe files may come from, canonicalized. Empty means
/// the feature is off.
#[derive(Debug, Default)]
pub struct Roots(Vec<PathBuf>);

impl Roots {
    /// Canonicalizes `dirs`; each must exist and be a directory.
    ///
    /// # Errors
    ///
    /// Fails on a missing or non-directory root, so a misspelt flag stops
    /// the server rather than silently refusing every request.
    pub fn new(dirs: &[PathBuf]) -> Result<Self> {
        let mut roots = Vec::with_capacity(dirs.len());
        for dir in dirs {
            let root = std::fs::canonicalize(dir)
                .with_context(|| format!("--recipe-root {}", dir.display()))?;
            if !root.is_dir() {
                bail!("--recipe-root {} is not a directory", dir.display());
            }
            roots.push(root);
        }
        Ok(Self(roots))
    }

    /// Whether no roots are configured — the feature is off.
    #[must_use]
    pub fn is_empty(&self) -> bool {
        self.0.is_empty()
    }

    fn contains(&self, path: &Path) -> bool {
        self.0.iter().any(|root| path.starts_with(root))
    }
}

/// Reads and concatenates `paths` in order, a newline inserted between
/// files where one is missing, refusing anything that does not resolve
/// under a root. `max_len` bounds the concatenation.
///
/// # Errors
///
/// A problem reply: `recipe-file-invalid` for a path that is relative,
/// unreadable or not a regular file; `recipe-files-refused` for one
/// outside every root; `recipe-too-large` past `max_len`.
pub fn read(roots: &Roots, paths: &[String], max_len: usize) -> Result<Vec<u8>, api::Problem> {
    let mut recipe: Vec<u8> = Vec::new();
    for path in paths {
        if !Path::new(path).is_absolute() {
            return Err(api::Problem::recipe_file_invalid(
                path,
                "not an absolute path",
            ));
        }
        // O_NONBLOCK so that naming a fifo fails cleanly instead of
        // hanging the open; regular files ignore it.
        let file = {
            use std::os::unix::fs::OpenOptionsExt as _;
            std::fs::OpenOptions::new()
                .read(true)
                .custom_flags(libc::O_NONBLOCK | libc::O_NOCTTY)
                .open(path)
                .map_err(|error| api::Problem::recipe_file_invalid(path, error))?
        };
        let metadata = file
            .metadata()
            .map_err(|error| api::Problem::recipe_file_invalid(path, error))?;
        if !metadata.is_file() {
            return Err(api::Problem::recipe_file_invalid(
                path,
                "not a regular file",
            ));
        }
        // What was actually opened, after every symlink: the boundary is
        // checked on the descriptor so no rename or swap can move it.
        let real = std::fs::read_link(format!("/proc/self/fd/{}", file.as_raw_fd()))
            .map_err(|error| api::Problem::recipe_file_invalid(path, error))?;
        if !roots.contains(&real) {
            return Err(api::Problem::recipe_files_refused(format!(
                "{path} is outside every --recipe-root"
            )));
        }

        if !recipe.is_empty() && recipe.last() != Some(&b'\n') {
            recipe.push(b'\n');
        }
        let remaining = max_len
            .checked_sub(recipe.len())
            .ok_or_else(|| api::Problem::recipe_too_large(max_len))?;
        if metadata.len() > remaining as u64 {
            return Err(api::Problem::recipe_too_large(max_len));
        }
        // The read itself is bounded, not just the size that was stated:
        // a file that grows past the cap mid-read stops at one extra byte
        // instead of being buffered to EOF.
        let bytes_read = file
            .take(remaining as u64 + 1)
            .read_to_end(&mut recipe)
            .map_err(|error| api::Problem::recipe_file_invalid(path, error))?;
        if bytes_read > remaining {
            return Err(api::Problem::recipe_too_large(max_len));
        }
    }
    Ok(recipe)
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
                "servicecache-recipes-test-{}-{sequence}",
                std::process::id()
            ));
            std::fs::create_dir(&path).expect("create test directory");
            Self(path)
        }

        fn file(&self, name: &str, content: &[u8]) -> String {
            let path = self.0.join(name);
            std::fs::write(&path, content).expect("write test file");
            path.to_str().expect("utf-8 path").to_owned()
        }
    }

    impl Drop for TestDirectory {
        fn drop(&mut self) {
            std::fs::remove_dir_all(&self.0).expect("remove test directory");
        }
    }

    fn slug(result: Result<Vec<u8>, api::Problem>) -> String {
        let problem = result.expect_err("expected a problem");
        problem
            .kind
            .strip_prefix("urn:servicecache:")
            .expect("a servicecache problem")
            .to_owned()
    }

    const MAX: usize = 1024;

    #[test]
    fn files_concatenate_in_order_with_newlines_supplied() {
        let dir = TestDirectory::new();
        let roots = Roots::new(std::slice::from_ref(&dir.0)).expect("roots");
        let schema = dir.file("schema.sql", b"CREATE TABLE t (x INT);\n");
        let data = dir.file("data.sql", b"INSERT INTO t VALUES (1);");
        let unterminated = dir.file("more.sql", b"-- no newline");

        let recipe = read(&roots, &[schema.clone(), data.clone()], MAX).expect("read");
        assert_eq!(
            recipe,
            b"CREATE TABLE t (x INT);\nINSERT INTO t VALUES (1);"
        );

        // A missing terminator gets a newline before the next file, so
        // statements never fuse across a boundary.
        let recipe = read(&roots, &[unterminated, data], MAX).expect("read");
        assert_eq!(recipe, b"-- no newline\nINSERT INTO t VALUES (1);");
    }

    #[test]
    fn relative_and_missing_and_irregular_paths_are_invalid() {
        let dir = TestDirectory::new();
        let roots = Roots::new(std::slice::from_ref(&dir.0)).expect("roots");
        assert_eq!(
            slug(read(&roots, &["schema.sql".into()], MAX)),
            "recipe-file-invalid"
        );
        let missing = dir.0.join("absent.sql").to_str().expect("path").to_owned();
        assert_eq!(slug(read(&roots, &[missing], MAX)), "recipe-file-invalid");
        // A device node opens but is not a regular file.
        assert_eq!(
            slug(read(&roots, &["/dev/null".into()], MAX)),
            "recipe-file-invalid"
        );
    }

    #[test]
    fn files_outside_every_root_are_refused() {
        let root = TestDirectory::new();
        let elsewhere = TestDirectory::new();
        let roots = Roots::new(std::slice::from_ref(&root.0)).expect("roots");
        let outside = elsewhere.file("schema.sql", b"SELECT 1;\n");
        assert_eq!(slug(read(&roots, &[outside], MAX)), "recipe-files-refused");
    }

    #[test]
    fn a_symlink_out_of_the_root_is_refused() {
        let root = TestDirectory::new();
        let elsewhere = TestDirectory::new();
        let roots = Roots::new(std::slice::from_ref(&root.0)).expect("roots");
        let target = elsewhere.file("secret.sql", b"SELECT 1;\n");
        let link = root.0.join("innocent.sql");
        std::os::unix::fs::symlink(&target, &link).expect("symlink");
        // The link sits under the root; what it opens does not.
        assert_eq!(
            slug(read(
                &roots,
                &[link.to_str().expect("path").to_owned()],
                MAX
            )),
            "recipe-files-refused"
        );
    }

    #[test]
    fn the_size_cap_holds_across_files() {
        let dir = TestDirectory::new();
        let roots = Roots::new(std::slice::from_ref(&dir.0)).expect("roots");
        let half = dir.file("half.sql", &vec![b'a'; 600]);
        assert_eq!(
            slug(read(&roots, &[half.clone(), half.clone()], MAX)),
            "recipe-too-large"
        );
        assert_eq!(read(&roots, &[half], MAX).expect("read").len(), 600);
    }

    #[test]
    fn a_missing_root_stops_the_server() {
        let dir = TestDirectory::new();
        let absent = dir.0.join("absent");
        assert!(Roots::new(&[absent]).is_err());
    }
}
