/* Verify that a signal arriving while another signal's handler runs still
 * wakes a blocked wait.  The runtime queues signals and runs handlers from
 * the poll under a blocking syscall; a wake that lands in that window must
 * not be stranded in the queue while the wait goes back to sleep.
 * Cooperating processes that signal back to back and then wait quietly
 * deadlock on a stranded wake. */

#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <spawn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/epoll.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

extern char **environ;

static int signal_pipe_write = -1;
static volatile sig_atomic_t sigusr1_handled;
static volatile sig_atomic_t sigurg_handled;
static volatile unsigned long spin_sink;
static unsigned long spin_iterations;

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

/* A deliberately slow handler: the window in which the second signal must
 * arrive is the handler's execution.  The spin must be pure computation —
 * any syscall in here processes the queued SIGURG and hides the strand —
 * so it runs a count calibrated in the setup instead of watching a clock. */
static void handle_sigusr1(int signal_number) {
  (void)signal_number;
  sigusr1_handled = 1;
  for (unsigned long i = 0; i < spin_iterations; ++i)
    spin_sink += i;
}

static void handle_sigurg(int signal_number) {
  char byte = 0;

  (void)signal_number;
  sigurg_handled = 1;
  (void)write(signal_pipe_write, &byte, sizeof byte);
}

static int sender(const char *target_pid) {
  char *end;
  long pid = strtol(target_pid, &end, 10);

  if (*target_pid == '\0' || *end != '\0' || pid <= 0) {
    fprintf(stderr, "invalid target pid: %s\n", target_pid);
    return 1;
  }
  /* Let the waiter reach epoll_wait, open the window with SIGUSR1, land
   * SIGURG in the middle of it, then stay quiet: nothing else may wake the
   * waiter, or a stranded SIGURG would be released by the later signal. */
  usleep(600000);
  if (kill((pid_t)pid, SIGUSR1) != 0)
    fail("kill");
  usleep(150000);
  if (kill((pid_t)pid, SIGURG) != 0)
    fail("kill");
  return 0;
}

static int waiter(void) {
  /* Calibrate the handler's pure-compute spin to roughly 400 ms. */
  const unsigned long probe = 20 * 1000 * 1000;
  struct timespec cal_start;
  if (clock_gettime(CLOCK_MONOTONIC, &cal_start) != 0)
    fail("clock_gettime");
  for (unsigned long i = 0; i < probe; ++i)
    spin_sink += i;
  long cal_ms = elapsed_ms(&cal_start);
  if (cal_ms < 1)
    cal_ms = 1;
  spin_iterations = probe / (unsigned long)cal_ms * 400;

  int pipe_fds[2];
  if (pipe(pipe_fds) != 0)
    fail("pipe");
  signal_pipe_write = pipe_fds[1];
  if (fcntl(pipe_fds[0], F_SETFL, O_NONBLOCK) != 0 ||
      fcntl(pipe_fds[1], F_SETFL, O_NONBLOCK) != 0)
    fail("fcntl");

  struct sigaction action = {0};
  sigemptyset(&action.sa_mask);
  action.sa_handler = handle_sigusr1;
  if (sigaction(SIGUSR1, &action, NULL) != 0)
    fail("sigaction");
  action.sa_handler = handle_sigurg;
  if (sigaction(SIGURG, &action, NULL) != 0)
    fail("sigaction");

  int epoll_fd = epoll_create1(0);
  if (epoll_fd < 0)
    fail("epoll_create1");
  struct epoll_event interest = {.events = EPOLLIN, .data.fd = pipe_fds[0]};
  if (epoll_ctl(epoll_fd, EPOLL_CTL_ADD, pipe_fds[0], &interest) != 0)
    fail("epoll_ctl");

  /* One long wait: leaving and re-entering the syscall would process the
   * queue and hide a stranded signal, so the wake must arrive inside it. */
  struct timespec start;
  if (clock_gettime(CLOCK_MONOTONIC, &start) != 0)
    fail("clock_gettime");
  struct epoll_event event;
  int event_count = epoll_wait(epoll_fd, &event, 1, 4000);
  long waited = elapsed_ms(&start);
  if (event_count < 0)
    fail("epoll_wait");
  if (event_count != 1 || !sigusr1_handled || !sigurg_handled ||
      waited >= 2000) {
    fprintf(stderr,
            "signal during a handler was stranded "
            "(events=%d usr1=%d urg=%d waited=%ldms)\n",
            event_count, (int)sigusr1_handled, (int)sigurg_handled, waited);
    return 1;
  }

  return 0;
}

static pid_t spawn(char *const child_argv[]) {
  pid_t child_pid;
  int spawn_error = posix_spawnp(&child_pid, "signal-during-handler.wasm",
                                 NULL, NULL, child_argv, environ);
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
  if (argc == 2 && strcmp(argv[1], "--waiter") == 0)
    return waiter();
  if (argc == 3 && strcmp(argv[1], "--sender") == 0)
    return sender(argv[2]);

  char *waiter_argv[] = {"signal-during-handler.wasm", "--waiter", NULL};
  pid_t waiter_pid = spawn(waiter_argv);
  char pid_text[32];
  snprintf(pid_text, sizeof pid_text, "%u", (unsigned)waiter_pid);
  char *sender_argv[] = {"signal-during-handler.wasm", "--sender", pid_text,
                         NULL};
  pid_t sender_pid = spawn(sender_argv);

  if (wait_for_child(sender_pid) != 0 || wait_for_child(waiter_pid) != 0)
    return 1;
  puts("WASIX signal during a handler still wakes the wait");
  return 0;
}
