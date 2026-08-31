/* A self-contained walkthrough of ictrobot_shm_v1: a parent and a spawned
 * child map the same /dev/shm object and pass a value through it.  See the
 * README in this directory for the ABI. */

#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <semaphore.h>
#include <spawn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#include <ictrobot_shm_v1.h>

extern char **environ;

#define OBJECT_NAME "/ictrobot-shm-demo"

/* Everything the two processes share lives inside the mapped page. */
struct shared_page {
  sem_t question_ready;
  sem_t answer_ready;
  int question;
  int answer;
};

static void fail(const char *operation) {
  fprintf(stderr, "%s: %s\n", operation, strerror(errno));
  exit(1);
}

static void wait_for(sem_t *sem, const char *what) {
  struct timespec deadline;
  if (clock_gettime(CLOCK_REALTIME, &deadline) != 0)
    fail("clock_gettime");
  deadline.tv_sec += 5;
  while (sem_timedwait(sem, &deadline) != 0) {
    if (errno != EINTR)
      fail(what);
  }
}

/* Maps one page of the object over freshly reserved linear memory.  An
 * anonymous mmap hands back a Wasm-page-aligned private range; fd_map then
 * replaces its contents with the shared object's. */
static struct shared_page *map_page(int fd) {
  void *address =
      mmap(NULL, ICTROBOT_SHM_WASM_PAGE_SIZE, PROT_READ | PROT_WRITE,
           MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
  if (address == MAP_FAILED)
    fail("mmap");
  if (ictrobot_shm_fd_map(fd, address, ICTROBOT_SHM_WASM_PAGE_SIZE, 0) != 0)
    fail("ictrobot_shm_fd_map");
  return address;
}

static int child(void) {
  /* The child knows only the object's name; the mapping's guest address is
   * its own and independent of the parent's. */
  int fd = shm_open(OBJECT_NAME, O_RDWR, 0);
  if (fd < 0)
    fail("shm_open");
  struct shared_page *page = map_page(fd);

  wait_for(&page->question_ready, "waiting for the question");
  page->answer = page->question * 2;
  if (sem_post(&page->answer_ready) != 0)
    fail("sem_post");

  if (ictrobot_shm_fd_unmap(page, ICTROBOT_SHM_WASM_PAGE_SIZE) != 0)
    fail("ictrobot_shm_fd_unmap");
  if (munmap(page, ICTROBOT_SHM_WASM_PAGE_SIZE) != 0)
    fail("munmap");
  if (close(fd) != 0)
    fail("close");
  return 0;
}

int main(int argc, char **argv) {
  if (argc == 2 && strcmp(argv[1], "--child") == 0)
    return child();

  int fd = shm_open(OBJECT_NAME, O_CREAT | O_EXCL | O_RDWR, 0600);
  if (fd < 0)
    fail("shm_open");
  if (ftruncate(fd, ICTROBOT_SHM_WASM_PAGE_SIZE) != 0)
    fail("ftruncate");
  struct shared_page *page = map_page(fd);

  /* Process-shared primitives work inside the mapping: futex identity is
   * the object and offset, not the guest address. */
  if (sem_init(&page->question_ready, 1, 0) != 0 ||
      sem_init(&page->answer_ready, 1, 0) != 0)
    fail("sem_init");

  char *child_argv[] = {"ictrobot-shm-demo.wasm", "--child", NULL};
  pid_t child_pid;
  int spawn_error = posix_spawnp(&child_pid, "ictrobot-shm-demo.wasm", NULL,
                                 NULL, child_argv, environ);
  if (spawn_error != 0) {
    errno = spawn_error;
    fail("posix_spawnp");
  }

  page->question = 21;
  if (sem_post(&page->question_ready) != 0)
    fail("sem_post");
  wait_for(&page->answer_ready, "waiting for the answer");
  printf("asked %d, child answered %d\n", page->question, page->answer);
  if (page->answer != 42) {
    fprintf(stderr, "the shared page did not carry the answer\n");
    return 1;
  }

  /* The name and the descriptor can go while mappings live: the answer
   * has proven both sides mapped, the unlinked name is gone for a fresh
   * shm_open, and the page stays shared until the last mapping does. */
  if (shm_unlink(OBJECT_NAME) != 0)
    fail("shm_unlink");
  if (shm_open(OBJECT_NAME, O_RDWR, 0) >= 0 || errno != ENOENT) {
    fprintf(stderr, "the unlinked name was still visible\n");
    return 1;
  }
  if (close(fd) != 0)
    fail("close");
  if (page->answer != 42) {
    fprintf(stderr, "the mapping did not survive the unlink\n");
    return 1;
  }

  int status;
  if (waitpid(child_pid, &status, 0) != child_pid)
    fail("waitpid");
  if (!WIFEXITED(status) || WEXITSTATUS(status) != 0) {
    fprintf(stderr, "child exited with status %d\n", status);
    return 1;
  }

  if (ictrobot_shm_fd_unmap(page, ICTROBOT_SHM_WASM_PAGE_SIZE) != 0)
    fail("ictrobot_shm_fd_unmap");
  if (munmap(page, ICTROBOT_SHM_WASM_PAGE_SIZE) != 0)
    fail("munmap");

  puts("ictrobot_shm_v1 demo: parent and child shared one page");
  return 0;
}
