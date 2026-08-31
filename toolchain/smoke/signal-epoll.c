/* Verify that a signal sent by one WASIX process wakes every epoll instance
 * watching the receiver's self-pipe.  Servers that register a latch pipe in
 * several wait sets depend on this Linux epoll behavior. */

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
#include <unistd.h>

extern char **environ;

static int signal_pipe_write = -1;
static volatile sig_atomic_t handled;

static void fail(const char *operation) {
  fprintf(stderr, "%s: %s\n", operation, strerror(errno));
  exit(1);
}

static void handle_sigurg(int signal_number) {
  char byte = 0;

  (void)signal_number;
  handled = 1;
  (void)write(signal_pipe_write, &byte, sizeof byte);
}

static int sender(const char *target_pid) {
  char *end;
  long pid = strtol(target_pid, &end, 10);

  if (*target_pid == '\0' || *end != '\0' || pid <= 0) {
    fprintf(stderr, "invalid target pid: %s\n", target_pid);
    return 1;
  }
  usleep(250000);
  if (kill((pid_t)pid, SIGURG) != 0)
    fail("kill");
  return 0;
}

static int waiter(void) {
  int pipe_fds[2];
  if (pipe(pipe_fds) != 0)
    fail("pipe");
  signal_pipe_write = pipe_fds[1];
  if (fcntl(pipe_fds[0], F_SETFL, O_NONBLOCK) != 0 ||
      fcntl(pipe_fds[1], F_SETFL, O_NONBLOCK) != 0)
    fail("fcntl");

  struct sigaction action = {0};
  action.sa_handler = handle_sigurg;
  sigemptyset(&action.sa_mask);
  if (sigaction(SIGURG, &action, NULL) != 0)
    fail("sigaction");

  int epoll_fds[2];
  for (size_t i = 0; i < sizeof epoll_fds / sizeof epoll_fds[0]; ++i) {
    epoll_fds[i] = epoll_create1(0);
    if (epoll_fds[i] < 0)
      fail("epoll_create1");
  }
  struct epoll_event interest = {.events = EPOLLIN, .data.fd = pipe_fds[0]};
  for (size_t i = 0; i < sizeof epoll_fds / sizeof epoll_fds[0]; ++i) {
    if (epoll_ctl(epoll_fds[i], EPOLL_CTL_ADD, pipe_fds[0], &interest) != 0)
      fail("epoll_ctl");
  }

  for (size_t i = 0; i < sizeof epoll_fds / sizeof epoll_fds[0]; ++i) {
    struct epoll_event event;
    int event_count = epoll_wait(epoll_fds[i], &event, 1, 2000);
    if (event_count < 0)
      fail("epoll_wait");
    if (event_count != 1 || event.data.fd != pipe_fds[0] || !handled) {
      fprintf(stderr,
              "signal did not wake epoll %zu (events=%d fd=%d handled=%d)\n",
              i, event_count, event_count == 1 ? event.data.fd : -1,
              (int)handled);
      return 1;
    }
  }

  return 0;
}

static pid_t spawn(char *const child_argv[]) {
  pid_t child_pid;
  int spawn_error = posix_spawnp(&child_pid, "signal-epoll.wasm", NULL, NULL,
                                 child_argv, environ);
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

  char *waiter_argv[] = {"signal-epoll.wasm", "--waiter", NULL};
  pid_t waiter_pid = spawn(waiter_argv);
  char pid_text[32];
  snprintf(pid_text, sizeof pid_text, "%u", (unsigned)waiter_pid);
  char *sender_argv[] = {"signal-epoll.wasm", "--sender", pid_text, NULL};
  pid_t sender_pid = spawn(sender_argv);

  if (wait_for_child(sender_pid) != 0 || wait_for_child(waiter_pid) != 0)
    return 1;
  puts("WASIX signal wakes every epoll registration");
  return 0;
}
