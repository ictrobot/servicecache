#!/usr/bin/env python3
"""Every ServiceCache workflow, run through `./x` at the repository root.

Each command first works out every step it needs, then runs them in order
from the repository root. The service versions a command needs build in one
toolchain/service.sh call: every Nix evaluation instantiates the guest
toolchain's whole nixpkgs closure again, so one evaluation builds them all.
"""

from __future__ import annotations

import argparse
import contextlib
import io
import os
import re
import shlex
import signal
import subprocess
import sys
import unittest
from collections.abc import Callable, Iterable
from dataclasses import dataclass
from pathlib import Path
from types import FrameType
from unittest.mock import patch

ROOT = Path(__file__).resolve().parent.parent
SERVICES_DIR = (("SERVICECACHE_SERVICES_DIR", "work/services"),)
LIFECYCLE = (("SERVICECACHE_LIFECYCLE", "1"),)


class UsageError(Exception):
    pass


# What the repository holds, found the way the flake finds it.


def version_key(version: str) -> list[tuple[int, str]]:
    return [
        (int(part), "") if part.isdigit() else (-1, part) for part in re.split(r"[.-]", version)
    ]


def service_versions() -> dict[str, list[str]]:
    """Every service's versions: services/<name>/versions/<version>/version.nix."""
    found: dict[str, list[str]] = {}
    for path in ROOT.glob("services/*/versions/*/version.nix"):
        found.setdefault(path.parts[-4], []).append(path.parts[-2])
    return {name: sorted(found[name], key=version_key) for name in sorted(found)}


def wasmer_variants() -> list[str]:
    return sorted(path.parent.name for path in ROOT.glob("wasmer/*/patches.list"))


def extensions() -> list[str]:
    return sorted(path.parent.name for path in ROOT.glob("extensions/*/smoke.sh"))


def libs() -> list[str]:
    return sorted(path.parent.name for path in ROOT.glob("libs/*/smoke.sh"))


@dataclass(frozen=True)
class Version:
    service: str
    version: str

    def __str__(self) -> str:
        return f"{self.service}@{self.version}"


def select(selector: str) -> list[Version]:
    """The versions one selector names: NAME is every version of a service,
    NAME@VERSION that version, and NAME@PREFIX every version beginning with
    PREFIX and a dot (NAME@1.0 is 1.0.1 and 1.0.10, but not 1.01)."""
    known = service_versions()
    name, at, wanted = selector.partition("@")
    if name not in known:
        raise UsageError(f"unknown service {name!r}; services: {', '.join(known)}")
    versions = known[name]
    if at:
        versions = [v for v in versions if v == wanted or v.startswith(f"{wanted}.")]
        if not versions:
            raise UsageError(
                f"{name} has no version {wanted!r}; versions: {', '.join(known[name])}"
            )
    return [Version(name, version) for version in versions]


def resolve(selectors: list[str]) -> list[Version]:
    """The versions the selectors name, in order and once each; every
    version when there are none."""
    if not selectors:
        return [Version(name, v) for name, versions in service_versions().items() for v in versions]
    chosen: list[Version] = []
    for selector in selectors:
        chosen += [version for version in select(selector) if version not in chosen]
    return chosen


def resolve_one(selector: str) -> Version:
    versions = select(selector)
    if len(versions) != 1:
        raise UsageError(f"{selector} names {len(versions)} versions; name one")
    return versions[0]


def choose(names: list[str], known: list[str], kind: str) -> list[str]:
    """The names given, checked against the known ones, or every known name if none are."""
    for name in names:
        if name not in known:
            raise UsageError(f"unknown {kind} {name!r}; {kind}s: {', '.join(known)}")
    return list(dict.fromkeys(names)) or known


# Steps: the commands a plan runs.


@dataclass(frozen=True)
class Step:
    argv: tuple[str, ...]
    env: tuple[tuple[str, str], ...] = ()
    # The exit statuses that mean success.
    success: tuple[int, ...] = (0,)

    def __str__(self) -> str:
        return shlex.join([f"{key}={value}" for key, value in self.env] + list(self.argv))


def cmd(
    *argv: str,
    env: tuple[tuple[str, str], ...] = (),
    success: tuple[int, ...] = (0,),
) -> Step:
    return Step(argv, env, success)


SETUP_WASMER = cmd("wasmer/setup.sh")


def build_services(versions: list[Version], ccache: bool = False) -> list[Step]:
    if not versions:
        return []
    pairs = [part for version in versions for part in (version.service, version.version)]
    return [cmd("toolchain/service.sh", *(["--ccache"] if ccache else []), *pairs)]


def build_wasmer(variant: str) -> Step:
    return cmd("wasmer/build.sh", variant)


def service_links(versions: list[Version]) -> list[str]:
    return [f"work/services/{version.service}-{version.version}" for version in versions]


def absolute(path: str | None) -> list[str]:
    """A path argument, made absolute: steps run from the repository root."""
    return [os.path.abspath(path)] if path else []


def removal(*paths: str) -> Step:
    """rm -rf for paths relative to the checkout, which this must be."""
    if not (ROOT / "flake.nix").is_file() or not (ROOT / "toolchain/service.sh").is_file():
        raise UsageError(f"{ROOT} is not a ServiceCache checkout; refusing to remove anything")
    return Step(("rm", "-rf", "--", *paths))


# Plans, one per command.


def plan_services(args: argparse.Namespace) -> list[Step]:
    if sum((args.ccache, args.from_source_tar, args.clean)) > 1:
        raise UsageError("--ccache, --from-source-tar and --clean are separate actions; choose one")
    versions = resolve(args.selectors)
    if args.clean:
        return [removal(*service_links(versions))]
    if args.from_source_tar:
        return [cmd("tools/build-source-tar.sh", v.service, v.version) for v in versions]
    return build_services(versions, ccache=args.ccache)


def plan_smoke(args: argparse.Namespace) -> list[Step]:
    everything = not (
        args.selectors
        or args.toolchain
        or args.extension
        or args.extensions
        or args.lib
        or args.libs
    )
    steps: list[Step] = []
    if args.toolchain or everything:
        steps.append(cmd("toolchain/smoke/run.sh"))
    if args.selectors or everything:
        versions = resolve(args.selectors)
        steps += build_services(versions, ccache=args.ccache)
        steps += [cmd(f"services/{v.service}/smoke/smoke.sh", v.version) for v in versions]
    if args.extension or args.extensions or everything:
        names: list[str] = [] if args.extensions or everything else args.extension
        for name in choose(names, extensions(), "extension"):
            steps += [
                build_wasmer("extensions"),
                build_wasmer("stock"),
                cmd(f"extensions/{name}/smoke.sh"),
            ]
    if args.lib or args.libs or everything:
        names = [] if args.libs or everything else args.lib
        for name in choose(names, libs(), "lib"):
            steps += [build_wasmer("stock"), cmd(f"libs/{name}/smoke.sh")]
    return steps


def plan_lifecycle(args: argparse.Namespace) -> list[Step]:
    """The trials are named <service>::<version>::<case>, and the harness
    takes one name filter, a substring: each selector is a cargo test run of
    its own, filtered to its service and the version or prefix it names."""
    filters: list[str] = []
    for selector in args.selectors:
        versions = select(selector)
        name, at, wanted = selector.partition("@")
        if not at:
            filters.append(f"{name}::")
        elif [version.version for version in versions] == [wanted]:
            filters.append(f"{name}::{wanted}::")
        else:
            filters.append(f"{name}::{wanted}.")
    cargo = ["cargo", "test", *(["--release"] if args.release else []), "--test", "lifecycle"]
    long = ["--include-ignored"] if args.long else []
    steps = [*build_services(resolve(args.selectors), ccache=args.ccache), SETUP_WASMER]
    for extra in [[name_filter, *long] for name_filter in filters] or [long]:
        steps.append(cmd(*cargo, *(["--", *extra] if extra else []), env=LIFECYCLE))
    return steps


def plan_run(args: argparse.Namespace) -> list[Step]:
    version = resolve_one(args.selector)
    options = [*(["--recipe", *absolute(args.recipe)] if args.recipe else [])]
    options += ["--clones", str(args.clones)] if args.clones is not None else []
    cargo = cmd("cargo", "run", "--release", "--", "run", str(version), *options, env=SERVICES_DIR)
    return [*build_services([version], ccache=args.ccache), SETUP_WASMER, cargo]


def plan_request(args: argparse.Namespace) -> list[Step]:
    version = resolve_one(args.selector)
    recipe = ["--recipe", *absolute(args.recipe)] if args.recipe else []
    return [SETUP_WASMER, cmd("cargo", "run", "--", "request", str(version), *recipe)]


def plan_serve(args: argparse.Namespace) -> list[Step]:
    return [SETUP_WASMER, cmd("cargo", "run", "--", "serve", env=SERVICES_DIR)]


def plan_cargo(args: argparse.Namespace) -> list[Step]:
    return [SETUP_WASMER, cmd("cargo", *args.cargo)]


def plan_purge(args: argparse.Namespace) -> list[Step]:
    return [removal("work", "target")]


def plan_wasmer(args: argparse.Namespace) -> list[Step]:
    if args.test and args.clean:
        raise UsageError("--test and --clean are separate actions; choose one")
    variants = choose(args.variants, wasmer_variants(), "variant")
    if args.clean:
        return [removal(*(f"work/wasmer/{variant}" for variant in variants))]
    if args.test:
        return [cmd("wasmer/test.sh", variant) for variant in variants]
    return [build_wasmer(variant) for variant in variants]


def plan_setup_wasmer(args: argparse.Namespace) -> list[Step]:
    if args.dev:
        return [cmd("wasmer/setup-dev.sh", *absolute(args.checkout))]
    if args.checkout:
        raise UsageError("a checkout applies to --dev")
    return [SETUP_WASMER]


def python_tests() -> Step:
    return cmd(
        os.environ["SC_PYTHON"],
        "-m",
        "unittest",
        "toolchain/x.py",
        "toolchain/guest_artifacts.py",
    )


def plan_test(args: argparse.Namespace) -> list[Step]:
    if args.python:
        return [python_tests()]
    return [SETUP_WASMER, python_tests(), cmd("cargo", "test", "--workspace")]


def python_lint() -> list[Step]:
    """The developer tools, from the locked dev group in pyproject.toml.
    Nothing a build runs needs them, or anything beyond an interpreter."""
    return [
        cmd("uv", "sync", "--locked"),
        cmd("uv", "run", "ruff", "check", "."),
        cmd("uv", "run", "ruff", "format", "--check", "."),
        cmd("uv", "run", "pyright"),
    ]


def plan_lint(args: argparse.Namespace) -> list[Step]:
    if args.python:
        return python_lint()
    return [
        SETUP_WASMER,
        *python_lint(),
        cmd("cargo", "fmt", "--all", "--check"),
        cmd("cargo", "clippy", "--workspace", "--all-targets", "--", "-D", "warnings"),
        cmd(
            "cargo",
            "deny",
            "-L",
            "error",
            "--config",
            "deny.toml",
            "check",
            "licenses",
            "bans",
        ),
        # No service names outside the services, the docs and pyproject.toml (lists the adapters)
        cmd(
            "git",
            "grep",
            "--untracked",
            "-niF",
            *(f"-e{name}" for name in service_versions()),
            "--",
            ".",
            ":!services",
            ":!*.md",
            ":!pyproject.toml",
            success=(1,),
        ),
        cmd("toolchain/check-patches.sh"),
        cmd("toolchain/nix.sh", "check"),
    ]


def plan_check(args: argparse.Namespace) -> list[Step]:
    no_python = argparse.Namespace(python=False)
    return [*plan_lint(no_python), *plan_test(no_python), cmd("toolchain/smoke/run.sh")]


def plan_completion(args: argparse.Namespace) -> list[Step]:
    print(ADAPTERS[args.shell].replace("@X@", shlex.quote(str(ROOT / "x"))), end="")
    return []


# The command line. One table drives both argparse and the completions.


@dataclass(frozen=True)
class Option:
    flags: tuple[str, ...]
    help: str
    # The metavar of the value the option takes, or None for a switch.
    # FILE values complete as paths, EXTENSION and LIB as those names.
    value: str | None = None
    repeat: bool = False


@dataclass(frozen=True)
class Command:
    name: str
    help: str
    plan: Callable[[argparse.Namespace], list[Step]]
    # What the positional arguments are: "services" (any number of
    # selectors), "service" (one selector), "variants", "path" or "shell".
    arguments: str | None = None
    options: tuple[Option, ...] = ()


# The ccache variant links where the default build does, so the commands
# that build services before using them take it too.
CCACHE = Option(("--ccache",), "build services through ccache (each package's ccache variant)")
DRY_RUN = Option(("-n", "--dry-run"), "print the commands without running them")

COMMANDS = (
    Command(
        "cargo",
        "prepare the Wasmer checkout cargo builds use, then run cargo with these arguments",
        plan_cargo,
        "cargo",
    ),
    Command(
        "services",
        "build services and link them into work/services (all of them if none are named)",
        plan_services,
        "services",
        (
            CCACHE,
            Option(
                ("--from-source-tar",),
                "build from each service's source tar instead, into work/services-from-source-tar",
            ),
            Option(("--clean",), "remove their links instead"),
        ),
    ),
    Command(
        "smoke",
        "smoke-test services, guest libraries, extensions and the toolchain fixtures"
        " (everything if nothing is chosen)",
        plan_smoke,
        "services",
        (
            CCACHE,
            Option(("--toolchain",), "the toolchain fixtures"),
            Option(("--extension",), "one Wasmer extension's demo", value="EXTENSION", repeat=True),
            Option(("--extensions",), "every Wasmer extension's demo"),
            Option(("--lib",), "one guest library's tests", value="LIB", repeat=True),
            Option(("--libs",), "every guest library's tests"),
        ),
    ),
    Command(
        "lifecycle",
        "run the freeze and fork lifecycle tests against services (all of them if none are named)",
        plan_lifecycle,
        "services",
        (
            CCACHE,
            Option(("--long",), "also run the long cases (thousands of forks)"),
            Option(("--release",), "test a release build of servicecache, for latency figures"),
        ),
    ),
    Command(
        "run",
        "run one service and print its endpoint",
        plan_run,
        "service",
        (
            CCACHE,
            Option(("--recipe",), "feed this file to the service's initializer", value="FILE"),
            Option(("--clones",), "fork this many clones on Enter", value="N"),
        ),
    ),
    Command(
        "request",
        "request an instance of a service from a running `./x serve`",
        plan_request,
        "service",
        (Option(("--recipe",), "feed this file to the service's initializer", value="FILE"),),
    ),
    Command(
        "serve",
        "serve the manager's HTTP API for the services in work/services"
        " (SERVICECACHE_SOCKET sets the socket)",
        plan_serve,
    ),
    Command("purge", "remove work/ and target/ entirely", plan_purge),
    Command(
        "wasmer",
        "build Wasmer CLIs into work/wasmer/<variant> (all of them if none are named)",
        plan_wasmer,
        "variants",
        (
            Option(("--test",), "run the variants' unit tests instead"),
            Option(("--clean",), "remove the variants' links instead"),
        ),
    ),
    Command(
        "setup-wasmer",
        "prepare the Wasmer checkout cargo builds use",
        plan_setup_wasmer,
        "path",
        (
            Option(
                ("--dev",),
                "instead put the Wasmer dev checkout's branches at the committed patch sets"
                " (CHECKOUT, or work/wasmer-dev)",
            ),
        ),
    ),
    Command(
        "test",
        "run cargo test and the Python unit tests",
        plan_test,
        None,
        (Option(("--python",), "only the Python unit tests"),),
    ),
    Command(
        "lint",
        "run cargo fmt, clippy and deny, ruff and pyright, and the patch and flake checks",
        plan_lint,
        None,
        (Option(("--python",), "only ruff and pyright"),),
    ),
    Command("check", "lint, test, then smoke-test the toolchain fixtures", plan_check),
    Command(
        "completion",
        "print a completion script for this checkout's `./x`",
        plan_completion,
        "shell",
    ),
)
BY_NAME = {command.name: command for command in COMMANDS}

POSITIONALS = {
    "services": ("selectors", "*", "SERVICE[@VERSION]"),
    "service": ("selector", None, "SERVICE@VERSION"),
    "variants": ("variants", "*", "VARIANT"),
    "path": ("checkout", "?", "CHECKOUT"),
    "shell": ("shell", None, "SHELL"),
    "cargo": ("cargo", argparse.REMAINDER, "ARGS"),
}

EPILOG = """\
A service selector is NAME (every version), NAME@VERSION, or NAME@PREFIX
(every version beginning with PREFIX and a dot, so NAME@1.0 is 1.0.1 and
1.0.10, but not 1.01). Every service version a command needs builds in one
Nix evaluation.
"""


def parsers() -> tuple[argparse.ArgumentParser, dict[str, argparse.ArgumentParser]]:
    """The top-level parser, and each command's own."""
    top = argparse.ArgumentParser(
        prog="x",
        description="Build, test and run ServiceCache.",
        epilog=EPILOG,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    commands = top.add_subparsers(dest="command", metavar="COMMAND")
    subs: dict[str, argparse.ArgumentParser] = {}
    for command in COMMANDS:
        selectors = command.arguments in ("services", "service")
        sub = commands.add_parser(
            command.name,
            help=command.help,
            description=command.help,
            epilog=EPILOG if selectors else None,
        )
        sub.set_defaults(plan=command.plan)
        subs[command.name] = sub
        if command.arguments == "shell":
            sub.add_argument("shell", choices=sorted(ADAPTERS))
        elif command.arguments:
            dest, nargs, metavar = POSITIONALS[command.arguments]
            sub.add_argument(dest, nargs=nargs, metavar=metavar)
        for option in (*command.options, *(() if command.name == "cargo" else (DRY_RUN,))):
            if option.value is None:
                sub.add_argument(*option.flags, action="store_true", help=option.help)
            else:
                sub.add_argument(
                    *option.flags,
                    action="append" if option.repeat else "store",
                    default=[] if option.repeat else None,
                    type=int if option.value == "N" else str,
                    metavar=option.value,
                    help=option.help,
                )
    return top, subs


def parse(argv: list[str]) -> argparse.Namespace:
    """The command line. A command's own arguments are parsed intermixed, so
    options may come between selectors; argparse cannot intermix through
    subcommands, so the command is picked out first. cargo's arguments are
    all cargo's, so they are not parsed at all."""
    top, commands = parsers()
    if argv[:1] == ["cargo"]:
        return argparse.Namespace(command="cargo", plan=plan_cargo, cargo=argv[1:], dry_run=False)
    if argv[:1] and argv[0] in commands:
        args = commands[argv[0]].parse_intermixed_args(argv[1:])
        args.command = argv[0]
        return args
    return top.parse_args(argv)


# Completion: `x --complete WORD...` with the words after the program
# name, the last being the one under the cursor (empty for a new word).
# Each candidate is a line, its description after a tab; where a file name
# goes, the single line :files instead, and the shell completes it itself.
FILES = ":files"


def candidates(kind: str | None, current: str) -> list[tuple[str, str]]:
    known = service_versions()
    pairs: list[tuple[str, str]] = []
    if kind == "services":
        for name, versions in known.items():
            pairs.append((name, f"every version ({', '.join(versions)})"))
            pairs += [(f"{name}@{version}", "") for version in versions]
    elif kind == "service":
        pairs = [
            (f"{name}@{version}", "") for name, versions in known.items() for version in versions
        ]
    elif kind == "variants":
        pairs = [(variant, "Wasmer variant") for variant in wasmer_variants()]
    elif kind == "EXTENSION":
        pairs = [(name, "extension") for name in extensions()]
    elif kind == "LIB":
        pairs = [(name, "guest library") for name in libs()]
    elif kind == "shell":
        pairs = [(shell, "") for shell in sorted(ADAPTERS)]
    elif kind in ("path", "FILE"):
        return [(FILES, "")]
    return [pair for pair in pairs if pair[0].startswith(current)]


def complete(words: list[str]) -> list[tuple[str, str]]:
    *before, current = words or [""]
    if not before:
        found = [(command.name, command.help) for command in COMMANDS]
        return [
            pair
            for pair in [*found, ("--help", "show the commands")]
            if pair[0].startswith(current)
        ]
    command = BY_NAME.get(before[0])
    if command is None or command.name == "cargo":
        return []
    options = (*command.options, DRY_RUN)
    for option in options:
        if option.value is not None and before[-1] in option.flags:
            return candidates(option.value, current)
    if current.startswith("-"):
        flags = [(flag, option.help) for option in options for flag in option.flags]
        return [
            pair
            for pair in [*flags, ("--help", "show this command's help")]
            if pair[0].startswith(current)
        ]
    return candidates(command.arguments, current)


# Each script completes only the x of the checkout that printed it (@X@).
# fish matches the command's resolved path itself; bash and zsh complete by
# command name, so their functions compare the resolved path first and run
# no other x. Each completes file names as it would anywhere else.
ADAPTERS = {
    "fish": """\
# ./x completion fish > ~/.config/fish/conf.d/servicecache-x.fish
function __servicecache_x_complete
    set -l tokens (commandline -xpc)
    set -l output ($tokens[1] --complete $tokens[2..] (commandline -ct))
    if test "$output" = :files
        __fish_complete_path (commandline -ct)
    else
        printf '%s\\n' $output
    end
end
complete -p @X@ -f -a '(__servicecache_x_complete)'
""",
    "bash": """\
# source <(./x completion bash), for example from ~/.bashrc
_x() {
  local IFS=$'\\n' command output
  command="$(type -P -- "${COMP_WORDS[0]}")" && [[ $(realpath -- "$command") == @X@ ]] || return 0
  output="$("$command" --complete "${COMP_WORDS[@]:1:COMP_CWORD}" 2>/dev/null)"
  if [[ $output == :files ]]; then
    compopt -o default
    COMPREPLY=()
  else
    COMPREPLY=($(cut -f1 <<< "$output"))
  fi
}
complete -F _x x
""",
    "zsh": """\
# source <(./x completion zsh), for example from ~/.zshrc after compinit
_x() {
  local command=${words[1]} output line
  local -a candidates
  [[ $command == */* ]] || command=${commands[$command]}
  [[ -n $command && ${command:A} == @X@ ]] || return 1
  output="$("$command" --complete "${(@)words[2,CURRENT]}" 2>/dev/null)"
  if [[ $output == :files ]]; then
    _files
    return
  fi
  for line in "${(@f)output}"; do
    [[ -n $line ]] || continue
    if [[ $line == *$'\\t'* ]]; then
      candidates+=("${${line%%$'\\t'*}//:/\\\\:}:${line#*$'\\t'}")
    else
      candidates+=("${line//:/\\\\:}")
    fi
  done
  _describe 'x' candidates
}
compdef _x x
""",
}


# Running a plan.


class Interrupted(Exception):
    def __init__(self, signum: int) -> None:
        super().__init__(signum)
        self.signum = signum


def wait_for(step: Step) -> int:
    """Run a step to its end. SIGINT, SIGTERM and SIGHUP are passed on to
    it, so a step such as request or serve shuts down cleanly; then the whole
    run stops. Ctrl-C reaches the step from the terminal as well, so it gets
    SIGINT twice; the steps stop at the first, and serve and request ignore
    the second."""
    process = subprocess.Popen(step.argv, cwd=ROOT, env=os.environ | dict(step.env))
    received: list[int] = []

    def handle(signum: int, frame: FrameType | None) -> None:
        received.append(signum)
        process.send_signal(signum)

    handled = (signal.SIGINT, signal.SIGTERM, signal.SIGHUP)
    previous = {signum: signal.signal(signum, handle) for signum in handled}
    try:
        status = process.wait()
    finally:
        for signum, handler in previous.items():
            signal.signal(signum, handler)
    if received:
        raise Interrupted(received[0])
    # A step killed by a signal reports it as a shell would.
    return 128 - status if status < 0 else status


def execute(steps: Iterable[Step], dry_run: bool) -> int:
    """Run each step once, in order, from the repository root, stopping at
    the first that fails."""
    for step in dict.fromkeys(steps):
        # A dry run's commands can be pasted or saved as they are; a run
        # marks them on stderr as bash's set -x does.
        if dry_run:
            print(step)
            continue
        print(f"+ {step}", file=sys.stderr, flush=True)
        try:
            status = wait_for(step)
        except Interrupted as interrupted:
            return 128 + interrupted.signum
        if status not in step.success:
            print(f"error: {step} exited with status {status}", file=sys.stderr)
            return status or 1
    return 0


def main(argv: list[str]) -> int:
    if sys.version_info < (3, 11):  # noqa: UP036 - x may be run under an older python3
        print("error: x needs Python 3.11 or newer", file=sys.stderr)
        return 2
    if argv[:1] == ["--complete"]:
        for name, description in complete(argv[1:]):
            print(f"{name}\t{description}" if description else name)
        return 0
    args = parse(argv)
    if args.command is None:
        parsers()[0].print_help()
        return 0
    # One interpreter for every Python the scripts run; sc_python in
    # toolchain/lib.sh checks it.
    os.environ.setdefault("SC_PYTHON", sys.executable)
    try:
        steps = args.plan(args)
    except UsageError as error:
        print(f"error: {error}", file=sys.stderr)
        return 2
    try:
        return execute(steps, args.dry_run)
    except KeyboardInterrupt:
        return 130


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))


@patch(
    f"{__name__}.service_versions",
    return_value={"alpha": ["1.0.1", "1.0.10", "1.2.0"], "beta": ["2.0.0"]},
)
class Selection(unittest.TestCase):
    def test_selectors(self, _: object) -> None:
        self.assertEqual([str(v) for v in select("alpha@1.0")], ["alpha@1.0.1", "alpha@1.0.10"])
        self.assertEqual([str(v) for v in select("alpha@1.0.1")], ["alpha@1.0.1"])
        self.assertEqual([str(v) for v in select("alpha@1.2")], ["alpha@1.2.0"])
        self.assertEqual(len(select("alpha")), 3)
        self.assertEqual(len(resolve([])), 4)
        self.assertEqual(
            [str(v) for v in resolve(["beta", "alpha@1.2", "beta@2.0.0"])],
            ["beta@2.0.0", "alpha@1.2.0"],
        )
        for selector in ("alpha@1.1", "alpha@1.0.1.0", "gamma"):
            with self.assertRaises(UsageError):
                select(selector)
        with self.assertRaises(UsageError):
            resolve_one("alpha@1.0")

    def test_lifecycle_filters(self, _: object) -> None:
        args = parse(["lifecycle", "alpha@1.0", "alpha@1.0.1", "beta", "--long"])
        runs = [step.argv[step.argv.index("--") + 1 :] for step in plan_lifecycle(args)[2:]]
        self.assertEqual(
            runs,
            [
                ("alpha::1.0.", "--include-ignored"),
                ("alpha::1.0.1::", "--include-ignored"),
                ("beta::", "--include-ignored"),
            ],
        )

    def test_one_batch(self, _: object) -> None:
        for ccache in ([], ["--ccache"]):
            args = parse(["smoke", "beta", *ccache, "alpha@1.2"])
            builds = [step for step in plan_smoke(args) if step.argv[0] == "toolchain/service.sh"]
            pairs = ("beta", "2.0.0", "alpha", "1.2.0")
            self.assertEqual(builds, [cmd("toolchain/service.sh", *ccache, *pairs)])

    def test_completion(self, _: object) -> None:
        self.assertEqual(complete(["servi"]), [("services", BY_NAME["services"].help)])
        self.assertEqual(
            [name for name, _ in complete(["run", "alpha@1.0"])], ["alpha@1.0.1", "alpha@1.0.10"]
        )
        self.assertEqual(complete(["smoke", "--extension", "nosuch"]), [])
        self.assertEqual(complete(["run", "alpha@1.2.0", "--recipe", "a"]), [(FILES, "")])
        self.assertIn(("--ccache", CCACHE.help), complete(["services", "--cc"]))


class Execution(unittest.TestCase):
    def execute(self, *steps: Step) -> tuple[int, str]:
        output = io.StringIO()
        with contextlib.redirect_stdout(output), contextlib.redirect_stderr(output):
            status = execute(steps, dry_run=False)
        return status, output.getvalue()

    def test_failures_stop(self) -> None:
        status, output = self.execute(cmd("sh", "-c", "exit 3"), cmd("true"))
        self.assertEqual(status, 3)
        self.assertNotIn("+ true\n", output)

    def test_success_statuses_and_repeats(self) -> None:
        status, output = self.execute(cmd("false", success=(1,)), cmd("true"), cmd("true"))
        self.assertEqual(status, 0)
        self.assertEqual(output, "+ false\n+ true\n")
