/* Verify that threads can create, rename and unlink files in the same
 * in-memory directory at once.  The unpatched runtime found an entry's
 * position in its directory under a read lock and removed that position
 * under the write lock, by which time another thread's removal could have
 * made it stale: the removal panicked, and the panic poisoned the
 * filesystem's lock, so every later operation failed. */

#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

/* The root outside the runner's mounts is the in-memory filesystem. */
#define DIRECTORY "/sc-memfs-race"
#define THREADS 8
#define ROUNDS 500

static int run(int thread) {
  char temporary[64], final[64];
  for (int round = 0; round < ROUNDS; round++) {
    snprintf(temporary, sizeof(temporary), DIRECTORY "/%d-%d.tmp", thread,
             round);
    snprintf(final, sizeof(final), DIRECTORY "/%d-%d", thread, round);

    int fd = open(temporary, O_CREAT | O_EXCL | O_WRONLY, 0644);
    if (fd < 0) {
      fprintf(stderr, "creating %s failed: %s\n", temporary, strerror(errno));
      return 1;
    }
    if (write(fd, final, strlen(final)) < 0) {
      fprintf(stderr, "writing %s failed: %s\n", temporary, strerror(errno));
      return 1;
    }
    close(fd);

    /* Every other round renames the file into place, as a server
     * publishing an object does; the rest unlink the temporary file. */
    if (round % 2 == 0) {
      if (rename(temporary, final) != 0) {
        fprintf(stderr, "renaming %s failed: %s\n", temporary,
                strerror(errno));
        return 1;
      }
      if (unlink(final) != 0) {
        fprintf(stderr, "unlinking %s failed: %s\n", final, strerror(errno));
        return 1;
      }
    } else if (unlink(temporary) != 0) {
      fprintf(stderr, "unlinking %s failed: %s\n", temporary, strerror(errno));
      return 1;
    }
  }
  return 0;
}

static void *thread_main(void *arg) {
  return (void *)(long)run((int)(long)arg);
}

int main(void) {
  if (mkdir(DIRECTORY, 0755) != 0 && errno != EEXIST) {
    fprintf(stderr, "mkdir " DIRECTORY " failed: %s\n", strerror(errno));
    return 1;
  }

  pthread_t threads[THREADS];
  for (long i = 0; i < THREADS; i++) {
    if (pthread_create(&threads[i], NULL, thread_main, (void *)i) != 0) {
      fprintf(stderr, "pthread_create failed\n");
      return 1;
    }
  }
  int failed = 0;
  for (int i = 0; i < THREADS; i++) {
    void *result;
    pthread_join(threads[i], &result);
    failed |= result != NULL;
  }
  if (failed)
    return 1;

  if (rmdir(DIRECTORY) != 0) {
    fprintf(stderr, "rmdir " DIRECTORY " failed: %s\n", strerror(errno));
    return 1;
  }
  puts("WASIX threads create, rename and unlink in one memory directory");
  return 0;
}
