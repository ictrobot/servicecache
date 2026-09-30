/* Verify that unlinking a directory is refused without touching it, on a
 * host directory and in the in-memory root.  The unpatched runtime removed
 * the parent's entry before it answered EISDIR, so the directory stayed but
 * could no longer be removed: a program that unlinks first and removes a
 * directory on EISDIR, as Go's os.Remove does, got ENOENT from rmdir and
 * left the tree in place. */

#include <errno.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

/* The scratch directory the runner starts the fixture in is a host
 * directory; the root outside the mounts is in memory. */
#define HOST_DIRECTORY "sc-unlink-directory"
#define MEMORY_DIRECTORY "/sc-unlink-directory"

static int check(const char *path) {
  rmdir(path); /* A run that failed part way may have left it. */
  if (mkdir(path, 0755) != 0) {
    fprintf(stderr, "mkdir %s failed: %s\n", path, strerror(errno));
    return 1;
  }
  errno = 0;
  if (unlink(path) == 0 || errno != EISDIR) {
    fprintf(stderr, "unlink of directory %s answered %s, not EISDIR\n", path,
            errno ? strerror(errno) : "success");
    return 1;
  }
  if (rmdir(path) != 0) {
    fprintf(stderr, "rmdir %s after the refused unlink failed: %s\n", path,
            strerror(errno));
    return 1;
  }
  struct stat st;
  if (stat(path, &st) == 0 || errno != ENOENT) {
    fprintf(stderr, "%s is still there after rmdir\n", path);
    return 1;
  }
  return 0;
}

int main(void) {
  if (check(HOST_DIRECTORY) || check(MEMORY_DIRECTORY))
    return 1;
  puts("WASIX refuses to unlink a directory and leaves it intact");
  return 0;
}
