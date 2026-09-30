/* Verify that fsync accepts a directory.  A program that needs a new entry
 * or a rename to be durable syncs the directory holding it afterwards, and
 * may treat a failure as fatal; the unpatched runtime refused a directory
 * with EISDIR. */

#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#define DIRECTORY "sc-dir-fsync"
#define ENTRY DIRECTORY "/entry"

static int fail(const char *what) {
  fprintf(stderr, "%s failed: %s\n", what, strerror(errno));
  return 1;
}

int main(void) {
  /* A run that failed part way may have left these. */
  unlink(ENTRY);
  rmdir(DIRECTORY);

  if (mkdir(DIRECTORY, 0755) != 0)
    return fail("mkdir " DIRECTORY);
  int file = open(ENTRY, O_CREAT | O_EXCL | O_WRONLY, 0644);
  if (file < 0)
    return fail("creating " ENTRY);
  close(file);

  int directory = open(DIRECTORY, O_RDONLY | O_DIRECTORY);
  if (directory < 0)
    return fail("opening " DIRECTORY);
  if (fsync(directory) != 0)
    return fail("fsync of " DIRECTORY);
  close(directory);

  unlink(ENTRY);
  rmdir(DIRECTORY);
  puts("WASIX syncs a directory");
  return 0;
}
