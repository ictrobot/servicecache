/* Reports what a WASIX guest sees of its standard input and of the network:
 * how many bytes stdin holds, whether it is a terminal, and what connecting
 * to a loopback port returns. Built by bootstrap.sh --check; the manager's
 * tests run it to check the embedded runtime without any service. */

#include <arpa/inet.h>
#include <errno.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

int main(int argc, char **argv) {
  char buffer[4096];
  size_t total = 0;
  ssize_t n;

  printf("args=%d", argc - 1);
  for (int i = 1; i < argc; i++) {
    printf(" %s", argv[i]);
  }
  printf("\n");

  while ((n = read(0, buffer, sizeof buffer)) > 0) {
    total += (size_t)n;
  }
  printf("stdin bytes=%zu tty=%d\n", total, isatty(0));

  int fd = socket(AF_INET, SOCK_STREAM, 0);
  if (fd < 0) {
    printf("socket errno=%d %s\n", errno, strerror(errno));
    return 0;
  }
  struct sockaddr_in addr;
  memset(&addr, 0, sizeof addr);
  addr.sin_family = AF_INET;
  addr.sin_port = htons(1);
  addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  if (connect(fd, (struct sockaddr *)&addr, sizeof addr) == 0) {
    printf("connect ok\n");
  } else {
    printf("connect errno=%d %s\n", errno, strerror(errno));
  }
  close(fd);
  return 0;
}
