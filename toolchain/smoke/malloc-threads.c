/* Verify that the libc's malloc works across threads.  The sysroot's libc is
 * built with mimalloc (patches/wasix-libc, patches/mimalloc), whose WASI port
 * is single-threaded without its patch and never learns that a thread ended,
 * so every thread's heap is lost with it.  Here threads allocate blocks of
 * many sizes and leave each one in a shared table, freeing whatever block it
 * replaces, so most blocks are freed by a thread that did not allocate them;
 * the threads then end and new ones take their place.  A block is filled with
 * a byte derived from its address and size, and checked before it is freed.
 * The light rounds come first, while the program's memory is still small and
 * has no room to hide a leak in: once a few of them have filled the table,
 * thousands more short-lived threads must fit in what ended threads gave
 * back.  Memory may grow by one of mimalloc's arenas, which over that many
 * threads is a few KiB each, where the unpatched port loses a thread's whole
 * heap and is stopped within a few rounds.  The heavy rounds then add large
 * blocks and long-lived contention.  What the allocation functions leave in
 * errno, the aligned allocation functions, and a block that libc allocates
 * for the program to free, are checked first; last, a very large block and
 * one with the largest alignment mimalloc serves must each reuse the memory
 * they free, and a larger alignment must be refused. */

#include <errno.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define THREADS 8
#define SLOTS 256
/* Light rounds are there for the number of threads that start and end, and
 * allocate small blocks only, so that what the table holds stays the same
 * size; memory is measured after the settling ones and after the last one.
 * Heavy rounds are there for the allocator's work under contention. */
#define SETTLING_ROUNDS 50
#define LIGHT_ROUNDS 1000
#define LIGHT_ALLOCATIONS 50
#define HEAVY_ROUNDS 10
#define HEAVY_ALLOCATIONS 20000
/* Most blocks are small; in a heavy round one in LARGE_EVERY is large enough
 * to leave mimalloc's size classes. */
#define SMALL_MAX 3000
#define LARGE_EVERY 256
#define LARGE_MIN 300000
#define LARGE_SPAN 3000000
/* mimalloc takes memory an arena at a time, 64 MiB once the program is this
 * size, and how threads interleave decides whether it needs one more after
 * the settling rounds.  A leak of a 64 KiB page per thread, the least a lost
 * heap can be, would take seven. */
#define WASM_PAGE_BYTES 65536
#define GROWTH_LIMIT_BYTES (64u * 1024 * 1024)
/* A guest cannot give memory back, so mimalloc is patched to keep every block
 * in arenas it reuses: one too large for its size classes by far, and one
 * with the largest alignment it over-allocates for, of a size that gives it a
 * page of its own larger than the part of a page the page map covers. */
#define HUGE_BLOCK_BYTES (300u * 1024 * 1024)
#define MAX_ALIGNMENT (512u * 1024)
#define ALIGNED_BLOCK_BYTES (2u * 1024 * 1024)
#define REUSE_CYCLES 8
#define REUSE_SETTLING_CYCLES 1

struct block {
  unsigned char *data;
  size_t size;
};

static struct block slots[THREADS][SLOTS];
static pthread_mutex_t slot_locks[THREADS];
static int corrupt;
/* Set before a round's threads start. */
static int allocations;
static int large_blocks;

static unsigned char fill_byte(const struct block *block) {
  return (unsigned char)(((uintptr_t)block->data >> 4) ^ block->size);
}

static void fill(const struct block *block) {
  memset(block->data, fill_byte(block), block->size);
}

/* Checks the block's first and last bytes, the ones a neighbouring block's
 * overrun or a reused block would change, and frees it. */
static void check_and_free(const struct block *block) {
  if (block->data == NULL) {
    return;
  }
  unsigned char expected = fill_byte(block);
  if (block->data[0] != expected || block->data[block->size - 1] != expected) {
    __atomic_store_n(&corrupt, 1, __ATOMIC_RELAXED);
  }
  free(block->data);
}

static void *worker(void *arg) {
  unsigned state = (unsigned)(uintptr_t)arg * 2654435761u + 1;
  for (int i = 0; i < allocations; i++) {
    state = state * 1664525u + 1013904223u;
    struct block block;
    block.size = (state >> 8) % SMALL_MAX + 1;
    if (large_blocks && state % LARGE_EVERY == 0) {
      block.size = LARGE_MIN + (state >> 12) % LARGE_SPAN;
    }
    block.data = malloc(block.size);
    if (block.data == NULL) {
      fprintf(stderr, "malloc of %zu bytes failed\n", block.size);
      exit(1);
    }
    fill(&block);

    unsigned owner = (state >> 3) % THREADS;
    unsigned slot = (state >> 16) % SLOTS;
    pthread_mutex_lock(&slot_locks[owner]);
    struct block previous = slots[owner][slot];
    slots[owner][slot] = block;
    pthread_mutex_unlock(&slot_locks[owner]);
    check_and_free(&previous);
  }
  return NULL;
}

static int check_aligned(const char *call, void *pointer, size_t alignment) {
  if (pointer == NULL || (uintptr_t)pointer % alignment != 0) {
    fprintf(stderr, "%s returned %p for an alignment of %zu\n", call, pointer,
            alignment);
    return 1;
  }
  return 0;
}

/* The error checks call through these, so that the compiler cannot answer for
 * an allocation it knows the rules of and remove the call. */
static void *(*volatile checked_malloc)(size_t) = malloc;
static void *(*volatile checked_calloc)(size_t, size_t) = calloc;
static void *(*volatile checked_realloc)(void *, size_t) = realloc;
static void *(*volatile checked_aligned_alloc)(size_t, size_t) = aligned_alloc;

/* A block allocated and freed over and over must come from the same memory
 * once the first cycles have made room for it.  This runs after the thread
 * rounds, so that the memory a large block claims cannot hide a thread's
 * leak from them. */
static int check_reuse(size_t size, size_t alignment) {
  size_t settled_pages = 0;
  for (int cycle = 0; cycle < REUSE_CYCLES; cycle++) {
    void *pointer = alignment != 0 ? checked_aligned_alloc(alignment, size)
                                   : checked_malloc(size);
    if (pointer == NULL ||
        (alignment != 0 && (uintptr_t)pointer % alignment != 0)) {
      fprintf(stderr, "allocating %zu bytes aligned to %zu failed\n", size,
              alignment);
      return 1;
    }
    free(pointer);
    size_t pages = __builtin_wasm_memory_size(0);
    if (cycle == REUSE_SETTLING_CYCLES) {
      settled_pages = pages;
    }
    if (cycle > REUSE_SETTLING_CYCLES && pages > settled_pages) {
      fprintf(stderr, "%zu bytes aligned to %zu were not reused once freed\n",
              size, alignment);
      return 1;
    }
  }
  return 0;
}

int main(void) {
  /* errno starts out stale each time: a failure must overwrite it. */
  errno = EIO;
  if (checked_calloc(SIZE_MAX, 2) != NULL || errno != ENOMEM) {
    fprintf(stderr, "overflowing calloc did not set ENOMEM\n");
    return 1;
  }
  errno = EIO;
  if (checked_malloc(SIZE_MAX) != NULL || errno != ENOMEM) {
    fprintf(stderr, "oversized malloc did not set ENOMEM\n");
    return 1;
  }
  errno = EIO;
  if (checked_aligned_alloc(48, 480) != NULL || errno != EINVAL) {
    fprintf(stderr, "aligned_alloc with alignment 48 did not set EINVAL\n");
    return 1;
  }

  /* getcwd allocates through libc's internal name for malloc. */
  char *cwd = getcwd(NULL, 0);
  if (cwd == NULL) {
    perror("getcwd");
    return 1;
  }
  free(cwd);

  void *pointer = NULL;
  if (posix_memalign(&pointer, 4096, 10000) != 0) {
    pointer = NULL;
  }
  if (check_aligned("posix_memalign", pointer, 4096)) {
    return 1;
  }
  free(pointer);
  pointer = aligned_alloc(64, 640);
  if (check_aligned("aligned_alloc", pointer, 64)) {
    return 1;
  }
  memset(pointer, 0x5a, 640);
  unsigned char *grown = realloc(pointer, 100000);
  if (grown == NULL || grown[0] != 0x5a || grown[639] != 0x5a) {
    fprintf(stderr, "realloc lost the block's contents\n");
    return 1;
  }
  errno = EIO;
  if (checked_realloc(grown, SIZE_MAX) != NULL || errno != ENOMEM ||
      grown[0] != 0x5a || grown[639] != 0x5a) {
    fprintf(stderr, "failed realloc changed the block or did not set ENOMEM\n");
    return 1;
  }
  errno = EIO;
  free(grown);
  if (errno != EIO) {
    fprintf(stderr, "free changed errno\n");
    return 1;
  }

  for (int i = 0; i < THREADS; i++) {
    pthread_mutex_init(&slot_locks[i], NULL);
  }
  size_t settled_pages = 0;
  allocations = LIGHT_ALLOCATIONS;
  for (int round = 0; round < LIGHT_ROUNDS + HEAVY_ROUNDS; round++) {
    if (round == SETTLING_ROUNDS) {
      settled_pages = __builtin_wasm_memory_size(0);
    }
    if (round > SETTLING_ROUNDS && round <= LIGHT_ROUNDS) {
      /* Checked every round, so that a leak stops the test long before it
       * runs the program out of memory. */
      size_t grown_pages = __builtin_wasm_memory_size(0) - settled_pages;
      if (grown_pages > GROWTH_LIMIT_BYTES / WASM_PAGE_BYTES) {
        fprintf(stderr,
                "memory grew by %zu KiB while %d threads started and ended\n",
                grown_pages * (WASM_PAGE_BYTES / 1024),
                (round - SETTLING_ROUNDS) * THREADS);
        return 1;
      }
    }
    if (round == LIGHT_ROUNDS) {
      allocations = HEAVY_ALLOCATIONS;
      large_blocks = 1;
    }
    pthread_t threads[THREADS];
    for (int i = 0; i < THREADS; i++) {
      /* Each thread of the run gets its own sequence of sizes. */
      uintptr_t seed = (uintptr_t)round * THREADS + i;
      if (pthread_create(&threads[i], NULL, worker, (void *)seed) != 0) {
        perror("pthread_create");
        return 1;
      }
    }
    for (int i = 0; i < THREADS; i++) {
      pthread_join(threads[i], NULL);
    }
  }
  for (int owner = 0; owner < THREADS; owner++) {
    for (int slot = 0; slot < SLOTS; slot++) {
      check_and_free(&slots[owner][slot]);
    }
  }

  if (corrupt) {
    fprintf(stderr, "a block's contents changed before it was freed\n");
    return 1;
  }
  if (check_reuse(HUGE_BLOCK_BYTES, 0) ||
      check_reuse(ALIGNED_BLOCK_BYTES, MAX_ALIGNMENT)) {
    return 1;
  }
  /* A larger alignment must fail, and without taking memory to find out. */
  size_t pages = __builtin_wasm_memory_size(0);
  void *refused = NULL;
  errno = EIO;
  if (checked_aligned_alloc(2 * MAX_ALIGNMENT, ALIGNED_BLOCK_BYTES) != NULL ||
      errno != ENOMEM ||
      posix_memalign(&refused, 2 * MAX_ALIGNMENT, ALIGNED_BLOCK_BYTES) !=
          ENOMEM ||
      __builtin_wasm_memory_size(0) != pages) {
    fprintf(stderr, "an alignment of %u bytes did not fail with ENOMEM\n",
            2 * MAX_ALIGNMENT);
    return 1;
  }
  puts("WASIX malloc works across threads");
  return 0;
}
