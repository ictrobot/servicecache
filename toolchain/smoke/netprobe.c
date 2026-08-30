/* Listens on the port named by its argument, accepts one connection and
 * tells the client the addresses the guest sees: its own listening port
 * (getsockname) and the client's port (getpeername). Built by bootstrap.sh
 * --check; the manager's tests run it under the host to check that a guest
 * reads ports back correctly. */

#include <arpa/inet.h>
#include <errno.h>
#include <netinet/in.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

int main(int argc, char **argv) {
  if (argc != 2) {
    fprintf(stderr, "usage: netprobe PORT\n");
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

  char line[128];
  int n = snprintf(line, sizeof line, "local=%u peer=%u\n", ntohs(local.sin_port),
                   ntohs(peer.sin_port));
  if (write(client, line, (size_t)n) != n) {
    perror("write");
    return 1;
  }
  close(client);
  close(listener);
  return 0;
}
