/* Verify that select() and pselect() wait for a timeout under one second.
 * A select() timeout is how long to wait, not a point in time, but the
 * unpatched libc encoded it like an absolute timestamp, and every timeout
 * under a second became a request to return at once: a program that meant
 * to sleep between iterations spun instead.  A zero timeout must still
 * return at once, and a negative one is invalid. */

#include <errno.h>
#include <stdio.h>
#include <string.h>
#include <sys/select.h>
#include <time.h>

/* The timeout asked for, and the window a wait for it must land in: at
 * least most of it, and nowhere near a second, which is where a timeout
 * taken for seconds rather than nanoseconds would land. */
#define TIMEOUT_MS 200
#define EARLIEST_MS 150
#define LATEST_MS 900

static long elapsed_ms(const struct timespec *start) {
  struct timespec now;
  clock_gettime(CLOCK_MONOTONIC, &now);
  return (now.tv_sec - start->tv_sec) * 1000 +
         (now.tv_nsec - start->tv_nsec) / 1000000;
}

static int check_wait(const char *call, int result, long waited) {
  if (result != 0) {
    fprintf(stderr, "%s with a %d ms timeout returned %d: %s\n", call,
            TIMEOUT_MS, result, strerror(errno));
    return 1;
  }
  if (waited < EARLIEST_MS || waited > LATEST_MS) {
    fprintf(stderr, "%s with a %d ms timeout returned after %ld ms\n", call,
            TIMEOUT_MS, waited);
    return 1;
  }
  return 0;
}

int main(void) {
  struct timespec start;

  struct timeval tv = {.tv_sec = 0, .tv_usec = TIMEOUT_MS * 1000};
  clock_gettime(CLOCK_MONOTONIC, &start);
  int result = select(0, NULL, NULL, NULL, &tv);
  if (check_wait("select", result, elapsed_ms(&start)))
    return 1;

  struct timespec ts = {.tv_sec = 0, .tv_nsec = TIMEOUT_MS * 1000000L};
  clock_gettime(CLOCK_MONOTONIC, &start);
  result = pselect(0, NULL, NULL, NULL, &ts, NULL);
  if (check_wait("pselect", result, elapsed_ms(&start)))
    return 1;

  struct timeval zero = {.tv_sec = 0, .tv_usec = 0};
  clock_gettime(CLOCK_MONOTONIC, &start);
  result = select(0, NULL, NULL, NULL, &zero);
  long waited = elapsed_ms(&start);
  if (result != 0 || waited >= EARLIEST_MS) {
    fprintf(stderr, "select with a zero timeout returned %d after %ld ms\n",
            result, waited);
    return 1;
  }

  struct timespec negative = {.tv_sec = -1, .tv_nsec = 0};
  errno = 0;
  result = pselect(0, NULL, NULL, NULL, &negative, NULL);
  if (result != -1 || errno != EINVAL) {
    fprintf(stderr, "pselect with a negative timeout returned %d (%s)\n",
            result, strerror(errno));
    return 1;
  }

  puts("WASIX select and pselect wait for their timeouts");
  return 0;
}
