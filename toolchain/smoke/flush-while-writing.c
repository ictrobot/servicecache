/* Verify that closing or fdatasync-ing a host file returns while other threads
 * keep writing it.  A file's descriptors share one host handle, and the
 * unpatched runtime's flush, which close and fdatasync wait for, took the
 * handle's lock afresh each time it was polled: a write from another thread
 * in between took over the flush's wakeup, and the flush never woke. */

#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

/* The directory the runner starts the fixture in is a host mount. */
#define FILE_NAME "sc-flush-while-writing"
#define WRITERS 4
#define BLOCK 8192
#define SYNCS 100

static atomic_int done;

static void *writer(void *arg) {
  int fd = open(FILE_NAME, O_WRONLY);
  if (fd < 0) {
    fprintf(stderr, "writer open failed: %s\n", strerror(errno));
    return (void *)1;
  }
  char block[BLOCK];
  memset(block, (int)(long)arg, sizeof(block));
  for (long n = 0; !atomic_load(&done); n++) {
    if (pwrite(fd, block, sizeof(block), (n % 64) * BLOCK) < 0) {
      fprintf(stderr, "pwrite failed: %s\n", strerror(errno));
      close(fd);
      return (void *)1;
    }
  }
  close(fd);
  return NULL;
}

/* Opens and closes the file, syncing it every other time first: both wait
 * for the shared handle's flush. */
static void *syncer(void *arg) {
  (void)arg;
  for (int n = 0; n < SYNCS; n++) {
    int fd = open(FILE_NAME, O_WRONLY);
    if (fd < 0) {
      fprintf(stderr, "syncer open failed: %s\n", strerror(errno));
      return (void *)1;
    }
    if (n % 2 == 0 && fdatasync(fd) != 0) {
      fprintf(stderr, "fdatasync failed: %s\n", strerror(errno));
      close(fd);
      return (void *)1;
    }
    if (close(fd) != 0) {
      fprintf(stderr, "close failed: %s\n", strerror(errno));
      return (void *)1;
    }
  }
  return NULL;
}

int main(void) {
  int fd = open(FILE_NAME, O_CREAT | O_TRUNC | O_WRONLY, 0644);
  if (fd < 0) {
    fprintf(stderr, "creating " FILE_NAME " failed: %s\n", strerror(errno));
    return 1;
  }
  close(fd);

  pthread_t writers[WRITERS], sync_thread;
  for (long i = 0; i < WRITERS; i++)
    pthread_create(&writers[i], NULL, writer, (void *)('a' + i));
  pthread_create(&sync_thread, NULL, syncer, NULL);

  void *result;
  int failed = 0;
  pthread_join(sync_thread, &result);
  failed |= result != NULL;
  atomic_store(&done, 1);
  for (int i = 0; i < WRITERS; i++) {
    pthread_join(writers[i], &result);
    failed |= result != NULL;
  }
  unlink(FILE_NAME);
  if (failed)
    return 1;
  puts("WASIX closes and syncs a file while other threads write it");
  return 0;
}
