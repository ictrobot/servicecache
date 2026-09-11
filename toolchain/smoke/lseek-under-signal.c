/* Verify that syscalls which cannot block keep their answers under a flood
 * of signals.  POSIX gives lseek no EINTR at all, since it never blocks, so a
 * caller that measures a file by seeking to its end takes the answer as
 * final and never retries; fsync and fdatasync are restarted rather than
 * failed when the handler is installed with SA_RESTART.  A runtime that
 * runs the host operation asynchronously and abandons it whenever a signal
 * happens to be queued turns every one of these into a spurious failure. */

#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <spawn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

extern char **environ;

/* How long the seeking process works for, and the window the sender floods
 * it in: the flood has to start after the seeking has and stop before it
 * ends, so that every seek measured is one made under signals. */
#define SEEK_MS 3000
#define SEND_DELAY_MS 250
#define SEND_MS 2500

/* Deadline and sync checks are made once per batch rather than once per
 * seek: every syscall entry drains the signal queue, so the fewer of them
 * there are between one seek and the next, the more of the seeks are made
 * with a signal already waiting. */
#define BATCH 64

static const char PAYLOAD[] = "servicecache";
static const char DATA_FILE[] = "lseek-under-signal.data";

static volatile sig_atomic_t signals_handled;

static void fail(const char *operation) {
  fprintf(stderr, "%s: %s\n", operation, strerror(errno));
  exit(1);
}

static long elapsed_ms(const struct timespec *start) {
  struct timespec now;
  if (clock_gettime(CLOCK_MONOTONIC, &now) != 0)
    fail("clock_gettime");
  return (now.tv_sec - start->tv_sec) * 1000 +
         (now.tv_nsec - start->tv_nsec) / 1000000;
}

static void handle_sigusr1(int signal_number) {
  (void)signal_number;
  signals_handled = 1;
}

static int sender(const char *target_pid) {
  char *end;
  long pid = strtol(target_pid, &end, 10);
  struct timespec start;
  unsigned long sent = 0;

  if (*target_pid == '\0' || *end != '\0' || pid <= 0) {
    fprintf(stderr, "invalid target pid: %s\n", target_pid);
    return 1;
  }
  /* Let the seeking process open its file and start looping first. */
  usleep(SEND_DELAY_MS * 1000);
  if (clock_gettime(CLOCK_MONOTONIC, &start) != 0)
    fail("clock_gettime");
  while (elapsed_ms(&start) < SEND_MS) {
    /* The target finishes on its own deadline; once it has gone there is
     * nobody left to signal and the flood is over. */
    if (kill((pid_t)pid, SIGUSR1) != 0)
      break;
    ++sent;
    usleep(1000);
  }
  if (sent == 0) {
    fprintf(stderr, "no signal could be sent to %ld: %s\n", pid,
            strerror(errno));
    return 1;
  }
  return 0;
}

static int seeker(void) {
  struct sigaction action = {0};
  struct timespec start;
  unsigned long seeks = 0;
  unsigned long syncs = 0;
  int fd;

  fd = open(DATA_FILE, O_RDWR | O_CREAT | O_TRUNC, 0644);
  if (fd < 0)
    fail("open");
  if (write(fd, PAYLOAD, sizeof PAYLOAD) != (ssize_t)sizeof PAYLOAD)
    fail("write");

  sigemptyset(&action.sa_mask);
  action.sa_handler = handle_sigusr1;
  action.sa_flags = SA_RESTART;
  if (sigaction(SIGUSR1, &action, NULL) != 0)
    fail("sigaction");

  if (clock_gettime(CLOCK_MONOTONIC, &start) != 0)
    fail("clock_gettime");
  for (;;) {
    off_t end = lseek(fd, 0, SEEK_END);

    if (end < 0) {
      fprintf(stderr,
              "seek to the end failed after %lu seeks and %lu syncs: %s\n",
              seeks, syncs, strerror(errno));
      return 1;
    }
    if (end != (off_t)sizeof PAYLOAD) {
      fprintf(stderr, "seek to the end returned %lld, not %zu\n",
              (long long)end, sizeof PAYLOAD);
      return 1;
    }
    ++seeks;

    if (seeks % BATCH == 0) {
      /* fsync and fdatasync are separate syscalls, so take turns. */
      int full_sync = syncs % 2 != 0;
      if ((full_sync ? fsync(fd) : fdatasync(fd)) != 0) {
        fprintf(stderr, "%s failed after %lu seeks and %lu syncs: %s\n",
                full_sync ? "fsync" : "fdatasync", seeks, syncs,
                strerror(errno));
        return 1;
      }
      ++syncs;
      if (elapsed_ms(&start) >= SEEK_MS)
        break;
    }
  }

  if (close(fd) != 0)
    fail("close");
  if (unlink(DATA_FILE) != 0)
    fail("unlink");
  /* Without a signal in the queue there was nothing to interrupt anything,
   * and the run proved nothing. */
  if (!signals_handled) {
    fprintf(stderr, "no signal reached the seeking process in %lu seeks\n",
            seeks);
    return 1;
  }
  return 0;
}

static pid_t spawn(char *const child_argv[]) {
  pid_t child_pid;
  int spawn_error = posix_spawnp(&child_pid, "lseek-under-signal.wasm", NULL,
                                 NULL, child_argv, environ);
  if (spawn_error != 0) {
    errno = spawn_error;
    fail("posix_spawnp");
  }
  return child_pid;
}

static int wait_for_child(pid_t child_pid) {
  int status;
  if (waitpid(child_pid, &status, 0) != child_pid)
    fail("waitpid");
  if (!WIFEXITED(status) || WEXITSTATUS(status) != 0) {
    fprintf(stderr, "child %u exited with status %d\n", (unsigned)child_pid,
            status);
    return 1;
  }
  return 0;
}

int main(int argc, char **argv) {
  if (argc == 2 && strcmp(argv[1], "--seeker") == 0)
    return seeker();
  if (argc == 3 && strcmp(argv[1], "--sender") == 0)
    return sender(argv[2]);

  char *seeker_argv[] = {"lseek-under-signal.wasm", "--seeker", NULL};
  pid_t seeker_pid = spawn(seeker_argv);
  char pid_text[32];
  snprintf(pid_text, sizeof pid_text, "%u", (unsigned)seeker_pid);
  char *sender_argv[] = {"lseek-under-signal.wasm", "--sender", pid_text,
                         NULL};
  pid_t sender_pid = spawn(sender_argv);

  /* Reap both, so that a failure in one does not leave the other behind. */
  int sender_failed = wait_for_child(sender_pid);
  int seeker_failed = wait_for_child(seeker_pid);
  if (sender_failed || seeker_failed)
    return 1;
  puts("WASIX seeks and syncs survive a signal flood");
  return 0;
}
