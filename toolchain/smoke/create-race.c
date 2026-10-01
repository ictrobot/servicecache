/* Verify that threads racing to create one name get what open(2) gives them,
 * in an in-memory directory and on a host mount.  Each round runs two races:
 * first every thread creates with O_EXCL, and exactly one succeeds while
 * every other gets EEXIST; then every thread creates without O_EXCL, and all
 * of them open the same file.
 *
 * The unpatched runtime answered a create that lost the race with EPERM,
 * even without O_EXCL.  Once creates ran outside the descriptor table's
 * lock, the in-memory filesystem let two exclusive creates both succeed. */

#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#define THREADS 8
#define ROUNDS 100
#define PRINTED_FAILURES 5

/* The root outside the runner's mounts is the in-memory filesystem; the
 * directory the runner starts the fixture in is a host mount. */
#define MEMORY_DIRECTORY "/sc-create-race"
#define HOST_DIRECTORY "sc-create-race"

static char name[128];
static pthread_barrier_t barrier;
static atomic_int creators;
static atomic_int failures;

static void fail(int exclusive, const char *what) {
  if (atomic_fetch_add(&failures, 1) < PRINTED_FAILURES)
    fprintf(stderr, "%s (%s race): %s\n", name,
            exclusive ? "O_EXCL" : "O_CREAT", what);
}

/* Each thread marks its own byte, so the file read back shows that every
 * open reached the same file. */
static void create_racing(int thread, int exclusive) {
  int fd = open(name, O_CREAT | O_WRONLY | (exclusive ? O_EXCL : 0), 0644);
  if (fd < 0) {
    if (!exclusive || errno != EEXIST)
      fail(exclusive, strerror(errno));
    return;
  }
  atomic_fetch_add(&creators, 1);
  char byte = (char)('a' + thread);
  if (pwrite(fd, &byte, 1, thread) != 1)
    fail(exclusive, strerror(errno));
  close(fd);
}

/* After a race one thread checks it and removes the file for the next. */
static void check_race(int exclusive) {
  int opened = atomic_exchange(&creators, 0);
  if (exclusive && opened != 1)
    fail(exclusive, "other than one exclusive creator");
  if (!exclusive) {
    char contents[THREADS];
    int fd = open(name, O_RDONLY);
    if (opened != THREADS)
      fail(exclusive, "not every thread opened the file");
    else if (fd < 0 || read(fd, contents, THREADS) != THREADS)
      fail(exclusive, "reading the file back failed");
    else
      for (int i = 0; i < THREADS; i++)
        if (contents[i] != (char)('a' + i)) {
          fail(exclusive, "a thread's write went to another file");
          break;
        }
    if (fd >= 0)
      close(fd);
  }
  unlink(name);
}

static void *race(void *arg) {
  int thread = (int)(long)arg;
  for (int round = 0; round < ROUNDS; round++) {
    for (int exclusive = 1; exclusive >= 0; exclusive--) {
      pthread_barrier_wait(&barrier);
      create_racing(thread, exclusive);
      if (pthread_barrier_wait(&barrier) == PTHREAD_BARRIER_SERIAL_THREAD)
        check_race(exclusive);
    }
  }
  return NULL;
}

static int check(const char *directory) {
  if (mkdir(directory, 0755) != 0 && errno != EEXIST) {
    fprintf(stderr, "mkdir %s failed: %s\n", directory, strerror(errno));
    return 1;
  }
  snprintf(name, sizeof(name), "%s/file", directory);
  unlink(name); /* A run that failed part way may have left it. */

  pthread_t threads[THREADS];
  for (long i = 0; i < THREADS; i++) {
    if (pthread_create(&threads[i], NULL, race, (void *)i) != 0) {
      fprintf(stderr, "pthread_create failed\n");
      return 1;
    }
  }
  for (int i = 0; i < THREADS; i++)
    pthread_join(threads[i], NULL);
  rmdir(directory);

  int count = atomic_exchange(&failures, 0);
  if (count != 0) {
    fprintf(stderr, "%s: %d failures in %d rounds\n", directory, count,
            ROUNDS);
    return 1;
  }
  return 0;
}

int main(void) {
  if (pthread_barrier_init(&barrier, NULL, THREADS) != 0) {
    fprintf(stderr, "pthread_barrier_init failed\n");
    return 1;
  }
  /* Check both, so that a failure in one does not hide the other's. */
  int failed = check(MEMORY_DIRECTORY);
  failed |= check(HOST_DIRECTORY);
  if (failed)
    return 1;
  puts("WASIX threads racing to create one name get what open gives them");
  return 0;
}
