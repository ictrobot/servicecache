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

: "${WASIXCC_SHA256:=7f9644bb94e3a14d8d2594b022fdf1ab44e22cfd365e6bf4bd324d8064cc908a}"
: "${WASMER_SHA256:=9b9a42c48d8c807ae1602cdd75fcb91d294824ae131ca9281eeca3710f75e4c3}"
