/* Verify that poll_oneoff answers a clock subscription with a zero timeout
 * at once.  WASI defines a relative timeout of zero as a check of what is
 * ready now, but the unpatched runtime took it as no timeout at all, so a
 * poll of the clock alone, or of a descriptor with nothing to read, never
 * returned.  wasix-libc's poll() and select() send one nanosecond instead of
 * zero, so the fixture calls poll_oneoff itself, as the Go runtime does. */

#include <errno.h>
#include <stdio.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <wasi/api.h>

#define CLOCK_USERDATA 1
#define READ_USERDATA 2
/* An immediate check returns in well under this. */
#define LATEST_MS 500

static long elapsed_ms(const struct timespec *start) {
  struct timespec now;
  clock_gettime(CLOCK_MONOTONIC, &now);
  return (now.tv_sec - start->tv_sec) * 1000 +
         (now.tv_nsec - start->tv_nsec) / 1000000;
}

static int poll_at_once(const char *what, const __wasi_subscription_t *subs,
                        __wasi_size_t count) {
  __wasi_event_t events[2];
  __wasi_size_t ready = 0;
  struct timespec start;
  clock_gettime(CLOCK_MONOTONIC, &start);
  __wasi_errno_t error = __wasi_poll_oneoff(subs, events, count, &ready);
  long waited = elapsed_ms(&start);
  if (error != 0) {
    fprintf(stderr, "poll_oneoff of %s failed: %s\n", what, strerror(error));
    return 1;
  }
  if (ready != 1 || events[0].userdata != CLOCK_USERDATA ||
      events[0].type != __WASI_EVENTTYPE_CLOCK) {
    fprintf(stderr, "poll_oneoff of %s reported %u events, not the clock's\n",
            what, (unsigned)ready);
    return 1;
  }
  if (waited > LATEST_MS) {
    fprintf(stderr, "poll_oneoff of %s returned after %ld ms\n", what, waited);
    return 1;
  }
  return 0;
}

int main(void) {
  __wasi_subscription_t clock = {
      .userdata = CLOCK_USERDATA,
      .u.tag = __WASI_EVENTTYPE_CLOCK,
      .u.u.clock = {.id = __WASI_CLOCKID_MONOTONIC, .timeout = 0},
  };
  if (poll_at_once("the clock alone", &clock, 1))
    return 1;

  int pipefd[2];
  if (pipe(pipefd) != 0) {
    fprintf(stderr, "pipe failed: %s\n", strerror(errno));
    return 1;
  }
  __wasi_subscription_t subs[2] = {
      {
          .userdata = READ_USERDATA,
          .u.tag = __WASI_EVENTTYPE_FD_READ,
          .u.u.fd_read = {.file_descriptor = pipefd[0]},
      },
      clock,
  };
  if (poll_at_once("an empty pipe and the clock", subs, 2))
    return 1;
  close(pipefd[0]);
  close(pipefd[1]);

  puts("WASIX answers a poll with a zero timeout at once");
  return 0;
}
