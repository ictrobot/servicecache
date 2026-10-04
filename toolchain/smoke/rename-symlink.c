/* Verify that rename moves a symbolic link itself, and replaces one, without
 * following it, in a host directory and in the in-memory root.  The
 * unpatched runtime resolved both paths through the link: renaming a link
 * that points at nothing failed with ENOENT, and after a file was renamed
 * onto such a link the runtime looked the name up through the link it had
 * replaced and panicked. */

#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

/* The scratch directory the runner starts the fixture in is a host
 * directory; the root outside the mounts is in memory. */
#define HOST_DIRECTORY "sc-rename-symlink"
#define MEMORY_DIRECTORY "/sc-rename-symlink"

#define CONTENT "renamed onto a link"

static int fail(const char *directory, const char *what) {
  fprintf(stderr, "%s: %s: %s\n", directory, what, strerror(errno));
  return 1;
}

static int check(const char *directory) {
  char link[64], moved[64], file[64], target[64], buffer[64];
  struct stat st;
  snprintf(link, sizeof link, "%s/link", directory);
  snprintf(moved, sizeof moved, "%s/moved", directory);
  snprintf(file, sizeof file, "%s/file", directory);
  /* A run that failed part way may have left these. */
  unlink(link);
  unlink(moved);
  unlink(file);
  rmdir(directory);
  if (mkdir(directory, 0755) != 0)
    return fail(directory, "mkdir");

  /* A link that points at nothing moves as itself. */
  if (symlink("missing", link) != 0)
    return fail(directory, "symlink");
  if (rename(link, moved) != 0)
    return fail(directory, "rename of a link that points at nothing");
  ssize_t length = readlink(moved, target, sizeof target - 1);
  if (length < 0)
    return fail(directory, "readlink of the moved link");
  target[length] = '\0';
  if (strcmp(target, "missing") != 0) {
    fprintf(stderr, "%s: the moved link points at %s\n", directory, target);
    return 1;
  }
  if (lstat(link, &st) == 0 || errno != ENOENT) {
    fprintf(stderr, "%s: the link is still at its old name\n", directory);
    return 1;
  }

  /* A file renamed onto the link replaces it. */
  int fd = open(file, O_WRONLY | O_CREAT | O_EXCL, 0644);
  if (fd < 0 || write(fd, CONTENT, strlen(CONTENT)) != (ssize_t)strlen(CONTENT) ||
      close(fd) != 0)
    return fail(directory, "writing the file");
  if (rename(file, moved) != 0)
    return fail(directory, "rename of a file onto a link");
  if (lstat(moved, &st) != 0 || !S_ISREG(st.st_mode)) {
    fprintf(stderr, "%s: the name the file took is not a regular file\n", directory);
    return 1;
  }
  fd = open(moved, O_RDONLY);
  if (fd < 0)
    return fail(directory, "opening the file under the link's name");
  length = read(fd, buffer, sizeof buffer - 1);
  close(fd);
  if (length != (ssize_t)strlen(CONTENT) || memcmp(buffer, CONTENT, length) != 0) {
    fprintf(stderr, "%s: the file under the link's name reads differently\n", directory);
    return 1;
  }

  if (unlink(moved) != 0 || rmdir(directory) != 0)
    return fail(directory, "removing the fixture's files");
  return 0;
}

int main(void) {
  if (check(HOST_DIRECTORY) || check(MEMORY_DIRECTORY))
    return 1;
  puts("WASIX renames a symbolic link, and onto one, without following it");
  return 0;
}
