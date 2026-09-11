/* Verify that closing an epoll set while readiness is being dispatched to
 * it leaves the runtime's selector working.  A server that waits for one
 * event at a time creates, arms and closes an epoll set around every wait,
 * so a peer that keeps writing races readiness against the teardown of
 * each set.  If the teardown that a dispatch triggers re-enters
 * the descriptor's interest registry, the selector thread wedges and every
 * socket in the process goes silent: the next epoll_ctl never returns. */

#define _GNU_SOURCE
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <pthread.h>
#include <signal.h>
#include <spawn.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/epoll.h>
#include <sys/socket.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

extern char **environ;

/* Long enough for the close/dispatch race to come up many thousands of
 * times, short enough to stay a smoke test. */
#define RUN_MS 3000
/* No single epoll cycle may take anywhere near this long: the whole point
 * is that none of them blocks.  A wedged selector shows up as an epoll_ctl
 * or epoll_wait that never returns, so the bound is enforced by a watchdog
 * thread as well as by the loop itself. */
#define STALL_MS 2000
#define MIN_CYCLES 100

static atomic_llong last_progress_ms;
static atomic_int loop_running;

static void fail(const char *operation) {
  fprintf(stderr, "%s: %s\n", operation, strerror(errno));
  exit(1);
}

static long long now_ms(void) {
  struct timespec now;
  if (clock_gettime(CLOCK_MONOTONIC, &now) != 0)
    fail("clock_gettime");
  return (long long)now.tv_sec * 1000 + now.tv_nsec / 1000000;
}

/* The failure mode is a thread that never comes back, so the deadline has
 * to be checked from somewhere other than the loop being timed. */
static void *watchdog(void *unused) {
  (void)unused;
  while (atomic_load(&loop_running)) {
    struct timespec tick = {.tv_sec = 0, .tv_nsec = 50 * 1000 * 1000};
    nanosleep(&tick, NULL);
    long long stalled = now_ms() - atomic_load(&last_progress_ms);
    if (stalled > STALL_MS) {
      fprintf(stderr,
              "epoll cycle made no progress for %lldms: "
              "closing a set during dispatch wedged the selector\n",
              stalled);
      fflush(stderr);
      _exit(1);
    }
  }
  return NULL;
}

static int connect_to_server(unsigned short port) {
  struct sockaddr_in addr = {0};
  addr.sin_family = AF_INET;
  addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  addr.sin_port = htons(port);

  for (int attempt = 0; attempt < 200; ++attempt) {
    int conn = socket(AF_INET, SOCK_STREAM, 0);
    if (conn < 0)
      fail("socket");
    if (connect(conn, (struct sockaddr *)&addr, sizeof addr) == 0)
      return conn;
    close(conn);
    struct timespec retry = {.tv_sec = 0, .tv_nsec = 20 * 1000 * 1000};
    nanosleep(&retry, NULL);
  }
  fail("connect");
  return -1;
}

/* The peer: small writes as fast as the connection takes them, so that a
 * readiness event is in flight whenever the server closes a set. */
static int peer(const char *port_text) {
  char *end;
  long port = strtol(port_text, &end, 10);
  if (*port_text == '\0' || *end != '\0' || port <= 0 || port > 65535) {
    fprintf(stderr, "invalid peer port: %s\n", port_text);
    return 1;
  }
  signal(SIGPIPE, SIG_IGN);
  int conn = connect_to_server((unsigned short)port);
  if (fcntl(conn, F_SETFL, O_NONBLOCK) != 0)
    fail("fcntl");

  long long deadline = now_ms() + RUN_MS + 1000;
  const char message[] = "tick";
  while (now_ms() < deadline) {
    ssize_t written = write(conn, message, sizeof message - 1);
    if (written > 0)
      continue;
    if (written < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
      /* The server reads in bursts; give it room rather than spinning. */
      struct timespec pause = {.tv_sec = 0, .tv_nsec = 200 * 1000};
      nanosleep(&pause, NULL);
      continue;
    }
    /* The server finished and closed: nothing left to feed. */
    break;
  }
  close(conn);
  return 0;
}

static int server(void) {
  int listener = socket(AF_INET, SOCK_STREAM, 0);
  if (listener < 0)
    fail("socket");
  struct sockaddr_in addr = {0};
  addr.sin_family = AF_INET;
  addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  addr.sin_port = 0;
  if (bind(listener, (struct sockaddr *)&addr, sizeof addr) != 0)
    fail("bind");
  if (listen(listener, 8) != 0)
    fail("listen");

  socklen_t addr_len = sizeof addr;
  if (getsockname(listener, (struct sockaddr *)&addr, &addr_len) != 0)
    fail("getsockname");
  char port_text[8];
  snprintf(port_text, sizeof port_text, "%u", (unsigned)ntohs(addr.sin_port));
  char *peer_argv[] = {"epoll-close-during-dispatch.wasm", "--peer", port_text,
                       NULL};
  pid_t peer_pid;
  int spawn_error =
      posix_spawnp(&peer_pid, "epoll-close-during-dispatch.wasm", NULL, NULL,
                   peer_argv, environ);
  if (spawn_error != 0) {
    errno = spawn_error;
    fail("posix_spawnp");
  }

  int conn = accept(listener, NULL, NULL);
  if (conn < 0)
    fail("accept");
  if (fcntl(conn, F_SETFL, O_NONBLOCK) != 0)
    fail("fcntl");

  atomic_store(&last_progress_ms, now_ms());
  atomic_store(&loop_running, 1);
  pthread_t watchdog_thread;
  int thread_error = pthread_create(&watchdog_thread, NULL, watchdog, NULL);
  if (thread_error != 0) {
    errno = thread_error;
    fail("pthread_create");
  }

  /* Repeat create, arm, wait, read and close while the peer keeps writing,
   * racing teardown against readiness dispatch as often as possible. */
  long long deadline = now_ms() + RUN_MS;
  long long cycles = 0;
  long long bytes = 0;
  long long slowest_ms = 0;
  int peer_gone = 0;
  while (!peer_gone && now_ms() < deadline) {
    long long started = now_ms();
    int epoll_fd = epoll_create1(0);
    if (epoll_fd < 0)
      fail("epoll_create1");
    struct epoll_event interest = {.events = EPOLLIN, .data = {.fd = conn}};
    if (epoll_ctl(epoll_fd, EPOLL_CTL_ADD, conn, &interest) != 0)
      fail("epoll_ctl");
    struct epoll_event event;
    int event_count = epoll_wait(epoll_fd, &event, 1, 10);
    if (event_count < 0 && errno != EINTR)
      fail("epoll_wait");

    /* Bound the read burst so a busy peer cannot delay the next close. */
    for (int burst = 0; burst < 64; ++burst) {
      char buffer[512];
      ssize_t got = read(conn, buffer, sizeof buffer);
      if (got > 0) {
        bytes += got;
        continue;
      }
      if (got == 0) {
        peer_gone = 1;
        break;
      }
      if (errno == EAGAIN || errno == EWOULDBLOCK)
        break;
      if (errno == EINTR)
        continue;
      fail("read");
    }

    if (close(epoll_fd) != 0)
      fail("close");

    long long took = now_ms() - started;
    if (took > slowest_ms)
      slowest_ms = took;
    cycles++;
    atomic_store(&last_progress_ms, now_ms());
  }
  atomic_store(&loop_running, 0);
  pthread_join(watchdog_thread, NULL);
  close(conn);
  close(listener);

  int status;
  if (waitpid(peer_pid, &status, 0) != peer_pid)
    fail("waitpid");
  if (!WIFEXITED(status) || WEXITSTATUS(status) != 0) {
    fprintf(stderr, "peer exited with status %d\n", status);
    return 1;
  }

  if (slowest_ms > STALL_MS) {
    fprintf(stderr, "an epoll cycle blocked for %lldms\n", slowest_ms);
    return 1;
  }
  if (cycles < MIN_CYCLES || bytes == 0) {
    fprintf(stderr, "only %lld epoll cycles and %lld bytes in %dms\n", cycles,
            bytes, RUN_MS);
    return 1;
  }

  return 0;
}

int main(int argc, char **argv) {
  if (argc == 3 && strcmp(argv[1], "--peer") == 0)
    return peer(argv[2]);
  if (server() != 0)
    return 1;
  puts("WASIX epoll sets close during dispatch without wedging the selector");
  return 0;
}
