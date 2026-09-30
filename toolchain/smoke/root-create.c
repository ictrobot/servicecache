/* Verify that entries can be created, renamed and removed at the root of the
 * filesystem through the first pre-open named "/", found as Go's wasip1
 * runtime finds it.  That pre-open is the virtual root, which holds the
 * others.  A lookup through it of a name that is not a pre-open falls
 * through to the directory mounted as "/", but the unpatched runtime created
 * a new entry in the virtual root itself, which holds only pre-opens, and
 * refused it: a program that resolves absolute paths through that
 * descriptor could read the root but not create in it. */

#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
#include <wasi/api.h>

/* Pre-opens are numbered from 3 up, until fd_prestat_get refuses one. */
#define FIRST_PREOPEN 3

#define DIRECTORY "sc-root-create-dir"
#define FILE_NAME "sc-root-create-file"
#define RENAMED "sc-root-create-renamed"

/* The first pre-open named "/", or -1 when there is none. */
static int root_preopen(void) {
  for (__wasi_fd_t fd = FIRST_PREOPEN;; fd++) {
    __wasi_prestat_t prestat;
    if (__wasi_fd_prestat_get(fd, &prestat) != 0)
      return -1;
    if (prestat.tag != __WASI_PREOPENTYPE_DIR ||
        prestat.u.dir.pr_name_len != 1)
      continue;
    uint8_t name;
    if (__wasi_fd_prestat_dir_name(fd, &name, 1) == 0 && name == '/')
      return (int)fd;
  }
}

static int fail(const char *what) {
  fprintf(stderr, "%s failed: %s\n", what, strerror(errno));
  return 1;
}

static int expect_type(const char *path, mode_t type) {
  struct stat st;
  if (stat(path, &st) != 0)
    return fail(path);
  if ((st.st_mode & S_IFMT) != type) {
    fprintf(stderr, "%s has mode %o\n", path, (unsigned)st.st_mode);
    return 1;
  }
  return 0;
}

static int expect_gone(const char *path) {
  struct stat st;
  if (stat(path, &st) == 0 || errno != ENOENT) {
    fprintf(stderr, "%s is still there\n", path);
    return 1;
  }
  return 0;
}

int main(void) {
  int root = root_preopen();
  if (root < 0) {
    fputs("no pre-open is named \"/\"\n", stderr);
    return 1;
  }

  if (mkdirat(root, DIRECTORY, 0755) != 0)
    return fail("mkdirat " DIRECTORY);
  if (expect_type("/" DIRECTORY, S_IFDIR))
    return 1;

  int fd = openat(root, FILE_NAME, O_CREAT | O_EXCL | O_WRONLY, 0644);
  if (fd < 0)
    return fail("openat " FILE_NAME);
  close(fd);
  if (expect_type("/" FILE_NAME, S_IFREG))
    return 1;

  if (renameat(root, FILE_NAME, root, RENAMED) != 0)
    return fail("renameat " FILE_NAME);
  if (expect_gone("/" FILE_NAME) || expect_type("/" RENAMED, S_IFREG))
    return 1;

  if (unlinkat(root, RENAMED, 0) != 0)
    return fail("unlinkat " RENAMED);
  if (unlinkat(root, DIRECTORY, AT_REMOVEDIR) != 0)
    return fail("unlinkat " DIRECTORY);
  if (expect_gone("/" RENAMED) || expect_gone("/" DIRECTORY))
    return 1;

  puts("WASIX creates and removes entries at the root through its pre-open");
  return 0;
}
