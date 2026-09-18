#!/usr/bin/env bash

# Default toolchain pins. Every pin, here and in any services/<name>/versions.sh
# or versions/<v>/version.env that overrides one, is written as
# : "${VAR:=value}" so that a value already set wins. Files are sourced most
# specific first (version.env, the service's versions.sh, then this file), which
# is what makes the most specific setting win. A plain VAR=value in an override
# file would silently clobber a more specific setting sourced before it.

: "${WASIXCC_VERSION:=0.4.5}"
: "${WASIX_SYSROOT_TAG:=v2026-07-30.1}"
: "${WASIX_LLVM_TAG:=21.1.206}"
: "${BINARYEN_TAG:=version_132}"
: "${WASMER_VERSION:=7.3.0}"
# The sysroot's libc is built with this mimalloc as its malloc.
: "${MIMALLOC_TAG:=v3.5.3}"

# The wasixcc release archive for each supported host architecture (uname -m).
: "${WASIXCC_SHA256_X86_64:=7f9644bb94e3a14d8d2594b022fdf1ab44e22cfd365e6bf4bd324d8064cc908a}"
: "${WASIXCC_SHA256_AARCH64:=aa21613ceee2edc0c6b8918d1c86cb84b40996ac5533c06d3940e3ecd8a64373}"
