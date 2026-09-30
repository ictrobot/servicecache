/* Verify that a socket reports its type in each state a server puts one in.
 * getsockopt(SO_TYPE) reads the type fd_fdstat_get reports, and fstat the
 * one fd_filestat_get reports.  The unpatched runtime's fd_fdstat_get
 * reported an unknown type for a bound or listening TCP socket, a bound UDP
 * socket and a socketpair, so SO_TYPE failed with ENOTSOCK, and its
 * fd_filestat_get reported an unknown type for every socket but a
 * socketpair, so fstat did not report a socket. */

#include <arpa/inet.h>
#include <errno.h>
#include <netinet/in.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <unistd.h>

static int check_socket(const char *state, int fd, int expected_type) {
  int type;
  socklen_t length = sizeof(type);
  if (getsockopt(fd, SOL_SOCKET, SO_TYPE, &type, &length) != 0) {
    fprintf(stderr, "getsockopt(SO_TYPE) on a %s failed: %s\n", state,
            strerror(errno));
    return 1;
  }
  if (type != expected_type) {
    fprintf(stderr, "a %s has type %d, not %d\n", state, type, expected_type);
    return 1;
  }

  struct stat st;
  if (fstat(fd, &st) != 0) {
    fprintf(stderr, "fstat of a %s failed: %s\n", state, strerror(errno));
    return 1;
  }
  if (!S_ISSOCK(st.st_mode)) {
    fprintf(stderr, "fstat of a %s reports mode %o, not a socket\n", state,
            (unsigned)st.st_mode);
    return 1;
  }
  return 0;
}

static int open_socket(int type, const char *state) {
  int fd = socket(AF_INET, type, 0);
  if (fd < 0) {
    fprintf(stderr, "opening a %s failed: %s\n", state, strerror(errno));
    return -1;
  }
  return fd;
}

static int bind_loopback(int fd, const char *state) {
  struct sockaddr_in addr = {.sin_family = AF_INET,
                             .sin_addr.s_addr = htonl(INADDR_LOOPBACK)};
  if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) != 0) {
    fprintf(stderr, "binding a %s failed: %s\n", state, strerror(errno));
    return 1;
  }
  return 0;
}

int main(void) {
  int tcp = open_socket(SOCK_STREAM, "TCP socket");
  if (tcp < 0 || check_socket("new TCP socket", tcp, SOCK_STREAM) ||
      bind_loopback(tcp, "TCP socket") ||
      check_socket("bound TCP socket", tcp, SOCK_STREAM))
    return 1;
  if (listen(tcp, 1) != 0) {
    fprintf(stderr, "listen failed: %s\n", strerror(errno));
    return 1;
  }
  if (check_socket("TCP listener", tcp, SOCK_STREAM))
    return 1;
  close(tcp);

  int udp = open_socket(SOCK_DGRAM, "UDP socket");
  if (udp < 0 || check_socket("new UDP socket", udp, SOCK_DGRAM) ||
      bind_loopback(udp, "UDP socket") ||
      check_socket("bound UDP socket", udp, SOCK_DGRAM))
    return 1;
  close(udp);

  int pair[2];
  if (socketpair(AF_UNIX, SOCK_STREAM, 0, pair) != 0) {
    fprintf(stderr, "socketpair failed: %s\n", strerror(errno));
    return 1;
  }
  if (check_socket("socketpair end", pair[0], SOCK_STREAM) ||
      check_socket("socketpair end", pair[1], SOCK_STREAM))
    return 1;
  close(pair[0]);
  close(pair[1]);

  puts("WASIX sockets report their type in every state");
  return 0;
}
