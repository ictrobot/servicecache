#!/usr/bin/env python3
"""Check a service's declared extension imports with Binaryen."""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import tempfile
import tomllib
import unittest
from pathlib import Path
from unittest.mock import patch


class Error(RuntimeError):
    """A ServiceCache tooling invariant failed."""


def check_imports(root: Path) -> None:
    """Check the manifest and all Wasm modules, following artifact symlinks."""

    manifest = tomllib.loads((root / "service.toml").read_text())
    declared = set(manifest["service"].get("extensions", []))
    allowed = declared | {"env", "wasi", "wasi_snapshot_preview1", "wasix_32v1"}
    visited: set[tuple[int, int]] = set()

    def walk_error(error: OSError) -> None:
        raise Error(f"cannot inspect artifact: {error}") from error

    for directory, subdirectories, files in os.walk(root, followlinks=True, onerror=walk_error):
        stat = Path(directory).stat()
        identity = (stat.st_dev, stat.st_ino)
        if identity in visited:
            subdirectories.clear()
            continue
        visited.add(identity)
        for name in files:
            path = Path(directory) / name
            with path.open("rb") as module:
                if module.read(4) != b"\x00asm":
                    continue
            boundary = subprocess.check_output(
                ("wasm-opt", "--all-features", "--print-boundary", "--quiet", str(path)),
                text=True,
                env=os.environ | {"BINARYEN_CORES": os.environ.get("JOBS", "1")},
            )
            unexpected = {entry["module"] for entry in json.loads(boundary)["imports"]} - allowed
            if unexpected:
                raise Error(
                    f"{path}: imports undeclared namespaces: {', '.join(sorted(unexpected))}"
                )


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=Path)

    try:
        check_imports(parser.parse_args().directory)
    except (Error, OSError, ValueError, subprocess.CalledProcessError) as error:
        print(f"error: {error}", file=sys.stderr)
        raise SystemExit(1) from error


class ArtifactImports(unittest.TestCase):
    def setUp(self) -> None:
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        (self.root / "service.toml").write_text('[service]\nextensions = ["extension"]\n')
        self.wasm_opt = self.enterContext(
            patch(
                f"{__name__}.subprocess.check_output",
                return_value='{"imports": [{"module": "env"}, {"module": "extension"}]}',
            )
        )

    def test_nested_modules_and_directory_symlinks(self) -> None:
        # A module reached only through a directory link is still checked;
        # revisiting a directory (including a cycle) must terminate.
        with tempfile.TemporaryDirectory() as external:
            target = Path(external)
            (target / "program").write_bytes(b"\x00asm")
            (self.root / "linked").symlink_to(target, target_is_directory=True)
            (target / "cycle").symlink_to(self.root, target_is_directory=True)
            check_imports(self.root)
            self.wasm_opt.assert_called_once()

    def test_manifest_controls_allowed_namespaces(self) -> None:
        (self.root / "program").write_bytes(b"\x00asm")
        check_imports(self.root)
        (self.root / "service.toml").write_text("[service]\n")
        with self.assertRaisesRegex(Error, "undeclared namespaces: extension"):
            check_imports(self.root)


if __name__ == "__main__":
    main()
