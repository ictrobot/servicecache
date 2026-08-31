/* Verify that changing a live descriptor's epoll interest still delivers
 * the readiness it already has.  Switching an established connection from
 * read to write interest is how request/reply servers drive their state
 * machines; the socket is already writable, so the level-triggered event
 * must arrive without any new readiness transition. */

#define _GNU_SOURCE
#include <arpa/inet.h>
#include <errno.h>
#include <netinet/in.h>
#include <spawn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/epoll.h>
#include <sys/socket.h>
#include <sys/wait.h>
#include <unistd.h>

extern char **environ;

#define PORT 15922

static void fail(const char *operation) {
  fprintf(stderr, "%s: %s\n", operation, strerror(errno));
  exit(1);
}

static int client(void) {
  int conn = socket(AF_INET, SOCK_STREAM, 0);
  if (conn < 0)
    fail("socket");
  struct sockaddr_in addr = {0};
  addr.sin_family = AF_INET;
  addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  addr.sin_port = htons(PORT);
  if (connect(conn, (struct sockaddr *)&addr, sizeof addr) != 0)
    fail("connect");
  if (write(conn, "ping", 4) != 4)
    fail("write");
  char reply[4];
  size_t have = 0;
  while (have < sizeof reply) {
    ssize_t got = read(conn, reply + have, sizeof reply - have);
    if (got <= 0)
      fail("read");
    have += (size_t)got;
  }
  if (memcmp(reply, "pong", 4) != 0) {
    fprintf(stderr, "unexpected reply\n");
    return 1;
  }
  close(conn);
  return 0;
}

int main(int argc, char **argv) {
  if (argc == 2 && strcmp(argv[1], "--client") == 0)
    return client();

  int listener = socket(AF_INET, SOCK_STREAM, 0);
  if (listener < 0)
    fail("socket");
  int one = 1;
  setsockopt(listener, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
  struct sockaddr_in addr = {0};
  addr.sin_family = AF_INET;
  addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  addr.sin_port = htons(PORT);
  if (bind(listener, (struct sockaddr *)&addr, sizeof addr) != 0)
    fail("bind");
  if (listen(listener, 8) != 0)
    fail("listen");

  int ep = epoll_create1(0);
  if (ep < 0)
    fail("epoll_create1");
  struct epoll_event ev = {.events = EPOLLIN, .data = {.fd = listener}};
  if (epoll_ctl(ep, EPOLL_CTL_ADD, listener, &ev) != 0)
    fail("epoll_ctl add listener");

  char *client_argv[] = {"epoll-interest-switch.wasm", "--client", NULL};
  pid_t client_pid;
  int spawn_error = posix_spawnp(&client_pid, "epoll-interest-switch.wasm",
                                 NULL, NULL, client_argv, environ);
  if (spawn_error != 0) {
    errno = spawn_error;
    fail("posix_spawnp");
  }

  struct epoll_event event;
  if (epoll_wait(ep, &event, 1, 8000) != 1)
    fail("epoll_wait for the connection");
  if (event.data.fd != listener || !(event.events & EPOLLIN)) {
    fprintf(stderr, "expected the listener readable, got fd %d events %#x\n",
            event.data.fd, event.events);
    return 1;
  }
  int conn = accept(listener, NULL, NULL);
  if (conn < 0)
    fail("accept");
  ev.events = EPOLLIN;
  ev.data.fd = conn;
  if (epoll_ctl(ep, EPOLL_CTL_ADD, conn, &ev) != 0)
    fail("epoll_ctl add conn");
  if (epoll_wait(ep, &event, 1, 8000) != 1)
    fail("epoll_wait for the request");
  if (event.data.fd != conn || !(event.events & EPOLLIN)) {
    fprintf(stderr, "expected the connection readable, got fd %d events %#x\n",
            event.data.fd, event.events);
    return 1;
  }
  char request[4];
  if (read(conn, request, sizeof request) != 4)
    fail("read");

  /* The regression: the socket has been writable all along, and the switch
   * to write interest must replay that level state, not wait for a
   * transition that will never come. */
  ev.events = EPOLLOUT;
  ev.data.fd = conn;
  if (epoll_ctl(ep, EPOLL_CTL_MOD, conn, &ev) != 0)
    fail("epoll_ctl mod conn");
  int n = epoll_wait(ep, &event, 1, 4000);
  if (n == 0) {
    fprintf(stderr, "interest switch lost the socket's writability\n");
    return 1;
  }
  if (n != 1)
    fail("epoll_wait for writability");
  if (event.data.fd != conn || !(event.events & EPOLLOUT)) {
    fprintf(stderr, "expected the connection writable, got fd %d events %#x\n",
            event.data.fd, event.events);
    return 1;
  }
  if (write(conn, "pong", 4) != 4)
    fail("write");

  int status;
  if (waitpid(client_pid, &status, 0) != client_pid)
    fail("waitpid");
  if (!WIFEXITED(status) || WEXITSTATUS(status) != 0) {
    fprintf(stderr, "client exited with status %d\n", status);
    return 1;
  }
  close(conn);
  puts("WASIX epoll interest switch keeps level readiness");
  return 0;
}
