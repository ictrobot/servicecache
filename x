#!/usr/bin/env bash
# ./x: every ServiceCache workflow (toolchain/x.py), run with SC_PYTHON or python3.
exec "${SC_PYTHON:-python3}" "$(dirname "$(realpath "${BASH_SOURCE[0]}")")/toolchain/x.py" "$@"
