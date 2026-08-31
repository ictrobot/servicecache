/*
 * ictrobot_shm_v1: cross-process shared memory for WASIX guests.
 *
 * The runtime maps a /dev/shm object's contents over an existing, private
 * range of WebAssembly linear memory.  Addresses, lengths and file offsets
 * must be aligned to a WebAssembly page.  Closing the descriptor or unlinking
 * its name does not remove an existing mapping.  Unmap accepts one complete
 * mapping; partial unmaps are not part of version 1.  The public wrappers
 * return zero on success, or -1 and set errno on failure.
 *
 * The ABI is specified in this directory's README.  A module using it
 * imports the ictrobot_shm_v1 namespace and instantiates only on a runtime
 * that provides it.
 *
 * Copyright (c) 2026 Ethan Jones
 * SPDX-License-Identifier: MIT
 */
#ifndef ICTROBOT_SHM_V1_H
#define ICTROBOT_SHM_V1_H

#include <errno.h>
#include <stddef.h>
#include <stdint.h>

#define ICTROBOT_SHM_WASM_PAGE_SIZE 65536U

#if UINTPTR_MAX != UINT32_MAX
#error "ictrobot_shm_v1 is a wasm32 ABI"
#endif

#ifdef __cplusplus
extern "C" {
#endif

__attribute__((import_module("ictrobot_shm_v1"), import_name("fd_map")))
extern uint32_t ictrobot_shm_import_fd_map(uint32_t fd, uintptr_t address,
                                           size_t length, uint64_t offset);

__attribute__((import_module("ictrobot_shm_v1"), import_name("fd_unmap")))
extern uint32_t ictrobot_shm_import_fd_unmap(uintptr_t address, size_t length);

#ifdef __cplusplus
}
#endif

static inline int ictrobot_shm_fd_map(int fd, void *address, size_t length,
                                      uint64_t offset) {
  uint32_t error = ictrobot_shm_import_fd_map(
      (uint32_t)fd, (uintptr_t)address, length, offset);

  if (error != 0) {
    errno = (int)error;
    return -1;
  }
  return 0;
}

static inline int ictrobot_shm_fd_unmap(void *address, size_t length) {
  uint32_t error =
      ictrobot_shm_import_fd_unmap((uintptr_t)address, length);

  if (error != 0) {
    errno = (int)error;
    return -1;
  }
  return 0;
}

#endif
