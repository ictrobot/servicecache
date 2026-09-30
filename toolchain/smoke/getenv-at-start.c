/* Verify that a program given an environment variable starts and reads it,
 * without referencing environ.  mimalloc, libc's allocator here, reads its
 * options with getenv as it initializes, and libc sets up the environment of
 * a program that does not reference environ on the first getenv, allocating
 * to do it.  Before the allocator's glue referenced environ, any variable
 * made that allocation reenter mimalloc, which called getenv again, until the
 * call stack was exhausted. */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* run.sh passes this variable with this value. */
#define VARIABLE "SC_SMOKE_GETENV"
#define EXPECTED "set by run.sh"

int main(void) {
  const char *value = getenv(VARIABLE);
  if (value == NULL) {
    fprintf(stderr, "%s is not set\n", VARIABLE);
    return 1;
  }
  if (strcmp(value, EXPECTED) != 0) {
    fprintf(stderr, "%s is \"%s\", not \"%s\"\n", VARIABLE, value, EXPECTED);
    return 1;
  }

  puts("WASIX starts with an environment and no reference to environ");
  return 0;
}
