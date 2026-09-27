# ServiceCache

**Fast disposable services for tests.**

ServiceCache runs real server software as WASIX/WebAssembly guests, initializes it once, snapshots the live running state, and hands out isolated copy-on-write clones on demand. A test suite that would otherwise repeat startup, schema creation and fixture import on every run gets a fresh, fully initialized instance in the time it takes to clone a snapshot: the first request for a service and recipe pays its bring-up, and later ones are forks of a frozen template, served in milliseconds.

Persistence is explicitly not a goal. Instances are disposable. Snapshots live in memory and are discarded with the manager.

See [ARCHITECTURE.md](ARCHITECTURE.md) for the design.

## Status

Early development prototype. Interfaces, service packages and runtime patches may change without any compatibility guarantees.

## Requirements

- Linux on x86-64 or AArch64.
- A host C/C++ compiler and Rust, normally installed through [rustup](https://rustup.rs/).
- Bash, Git, GNU Make and `sha256sum`.
- Python 3.11 or newer as `python3` (`SC_PYTHON` overrides the interpreter).
- An installed single-user or multi-user [Nix](https://nixos.org/download).
- Enough time and disk space for source builds. The guest toolchain, sources and database builds can occupy multiple gigabytes.

Nix outputs live in its store, linked from `work/services`. Smoke fixtures and Wasmer's host checkouts and builds are kept below `work/`. Rust build output goes below `target/`.

## Quick start

Build a service. Nix builds or reuses its pinned sources and guest toolchain:

```sh
make service-mariadb-11.8.9
```

Start the manager in one terminal:

```sh
make serve
```

Write a recipe, the input for the service's own client (here SQL), and request an initialized instance in another terminal:

```sh
cat > recipe.sql <<'EOF'
CREATE DATABASE app;
CREATE TABLE app.users (id INT PRIMARY KEY, name TEXT);
INSERT INTO app.users VALUES (1, 'first');
EOF
make request-mariadb-11.8.9 RECIPE=recipe.sql
```

The command prints the instance's loopback endpoint, which any MariaDB client can connect to, and keeps the lease alive. Press Ctrl-C, send SIGTERM, or close its standard input to destroy the instance.

The recipe is passed verbatim to the service's own client on standard input, and ServiceCache does not interpret it. The first request for a service, version and recipe pays the bring-up. Later ones are cloned from the frozen template for as long as it lives. With `--recipe-root DIR`, a request may name recipe files under that directory by path instead, read by the server, so large fixtures are never uploaded or encoded.

The manager serves an HTTP API over a per-user Unix socket, described at `/openapi.json`. The `request` command is a thin client for it.
See `make help` and `cargo run -- --help` for the remaining targets and commands.

## Services

ServiceCache is designed to be generic: the manager knows how to run, freeze, snapshot and clone a WASIX guest, not what the guest is. It is currently tested against:

| Service    | Versions                          |
|------------|-----------------------------------|
| MariaDB    | 10.11.19, 11.4.13, 11.8.9, 12.3.3 |
| MySQL      | 8.0.40, 8.0.46, 8.4.11, 9.7.2     |
| PostgreSQL | 18.6                              |
| Valkey     | 7.2.14, 8.1.9, 9.1.1              |
| beanstalkd | 1.13                              |

Each service is built from an exact upstream release plus a small patch series for WASIX. PostgreSQL's series targets WASIX with the ictrobot_shm_v1 shared memory extension.

## Trust model and scope

ServiceCache is intended for trusted local development and CI environments: it is not a production service host or a
multi-tenant security boundary. Service packages, their manifests and the compiled-module cache are trusted input.

Guests receive isolated in-memory writable filesystems and package content explicitly mounted read-only by their
manifests. They accept connections through a manager-provided listening socket. The runtime permits guests and
initializers to make outbound connections only to that service’s own endpoint.

The manager API is intended to be used by the same local user through its Unix socket.

## Development

Common checks (`make lint` needs `uv`, `cargo-deny`, and Nix):

```sh
make lint                 # formatting and static checks
make test                 # Python and Rust tests
make smoke-toolchain      # build and run the WASIX fixtures
make smoke-services       # build and smoke-test every service version
make lifecycle-tests      # build every service and test freeze/fork
```

`make build` and `make test` develop the Rust host with Cargo and do not need Nix. Wasmer CLIs for smoke tests build through Nix.

Smoke and lifecycle targets build the services they need into `work/services`. Use targets such as `smoke-service-mariadb` or `lifecycle-service-mariadb-11.8.9` to test fewer versions.

See [ARCHITECTURE.md](ARCHITECTURE.md#how-guests-are-built) for the build layout and [PROFILING.md](PROFILING.md) for perf profiling.

## License

Except where otherwise noted, ServiceCache's original code, scripts and documentation are licensed under the [MIT License](LICENSE). Patch series modifying third-party software are licensed as documented in their respective patch directories.

This repository distributes patches and build scripts, not built binaries. A guest built from these sources is licensed under the terms of the software it was built from.

## Trademarks

ServiceCache is an independent project. It is not affiliated with, sponsored by, or endorsed by the trademark owners noted below, or by the maintainers of the software it builds and depends on.

- MariaDB is a registered trademark of MariaDB plc.
- Oracle, Java, MySQL, and NetSuite are registered trademarks of Oracle and/or its affiliates.
- Postgres, PostgreSQL and the Slonik Logo are trademarks or registered trademarks of the PostgreSQL Community Association of Canada.
- Valkey and the Valkey logo are trademarks of LF Projects, LLC.
- Wasmer is a trademark of Wasmer, Inc.
- Other names may be trademarks of their respective owners.
