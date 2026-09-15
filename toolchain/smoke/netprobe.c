/* Listens on the port named by its argument, accepts one connection and
 * tells the client the addresses the guest sees: its own listening port
 * (getsockname) and the client's port (getpeername). Given a second port,
 * it also reports what of the network it can reach. Built by bootstrap.sh
 * --check; the manager's tests run it under the host to check that a guest
 * reads ports back correctly and makes outbound connections only to its
 * own endpoint. */

#include <arpa/inet.h>
#include <errno.h>
#include <netdb.h>
#include <netinet/in.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

/* How a blocking connection to PORT on loopback ends. */
static const char *connect_to(unsigned short port) {
  int fd = socket(AF_INET, SOCK_STREAM, 0);
  if (fd < 0) {
    return "socket-failed";
  }
  struct sockaddr_in addr;
  memset(&addr, 0, sizeof addr);
  addr.sin_family = AF_INET;
  addr.sin_port = htons(port);
  addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  const char *result;
  if (connect(fd, (struct sockaddr *)&addr, sizeof addr) == 0) {
    result = "connected";
  } else if (errno == EPERM) {
    result = "EPERM";
  } else if (errno == ECONNREFUSED) {
    result = "ECONNREFUSED";
  } else {
    result = "failed";
  }
  close(fd);
  return result;
}

int main(int argc, char **argv) {
  if (argc != 2 && argc != 3) {
    fprintf(stderr, "usage: netprobe PORT [OUTBOUND_PORT]\n");
    return 2;
  }
  int port = atoi(argv[1]);

  int listener = socket(AF_INET, SOCK_STREAM, 0);
  if (listener < 0) {
    perror("socket");
    return 1;
  }
  struct sockaddr_in addr;
  memset(&addr, 0, sizeof addr);
  addr.sin_family = AF_INET;
  addr.sin_port = htons((unsigned short)port);
  addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  if (bind(listener, (struct sockaddr *)&addr, sizeof addr) != 0) {
    perror("bind");
    return 1;
  }
  if (listen(listener, 1) != 0) {
    perror("listen");
    return 1;
  }

  struct sockaddr_in peer;
  socklen_t peer_len = sizeof peer;
  int client = accept(listener, (struct sockaddr *)&peer, &peer_len);
  if (client < 0) {
    perror("accept");
    return 1;
  }
  struct sockaddr_in local;
  socklen_t local_len = sizeof local;
  if (getsockname(listener, (struct sockaddr *)&local, &local_len) != 0) {
    perror("getsockname");
    return 1;
  }

  char line[256];
  int n = snprintf(line, sizeof line, "local=%u peer=%u\n", ntohs(local.sin_port),
                   ntohs(peer.sin_port));
  if (argc == 3) {
    const char *outbound = connect_to((unsigned short)atoi(argv[2]));
    const char *self = connect_to(ntohs(local.sin_port));
    struct addrinfo hints;
    memset(&hints, 0, sizeof hints);
    hints.ai_family = AF_INET;
    hints.ai_socktype = SOCK_STREAM;
    struct addrinfo *found = NULL;
    char localhost[INET_ADDRSTRLEN] = "failed";
    if (getaddrinfo("localhost", NULL, &hints, &found) == 0) {
      struct sockaddr_in *first = (struct sockaddr_in *)found->ai_addr;
      inet_ntop(AF_INET, &first->sin_addr, localhost, sizeof localhost);
      freeaddrinfo(found);
    }
    const char *other = "failed";
    if (getaddrinfo("example.com", NULL, &hints, &found) == 0) {
      other = "resolved";
      freeaddrinfo(found);
    }
    n += snprintf(line + n, sizeof line - (size_t)n,
                  "outbound=%s self=%s localhost=%s other=%s\n", outbound, self, localhost,
                  other);
  }
  if (write(client, line, (size_t)n) != n) {
    perror("write");
    return 1;
  }
  close(client);
  close(listener);
  return 0;
}
