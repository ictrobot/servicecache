# ServiceCache

**Fast disposable services for tests.**

ServiceCache runs real server software as WASIX/WebAssembly guests, initializes it once, snapshots the live running state, and hands out isolated copy-on-write clones on demand. A test suite that would otherwise repeat startup, schema creation and fixture import on every run gets a fresh, fully initialized instance in the time it takes to clone a snapshot.

Persistence is explicitly not a goal. Instances are disposable; snapshots live in memory and are discarded with the manager.

See [ARCHITECTURE.md](ARCHITECTURE.md) for the design.

## Status

Early development.

## Services

ServiceCache is designed to be generic: the manager knows how to run, freeze, snapshot and clone a WASIX guest, not what the guest is. It is currently tested against:

| Service    | Versions                          |
|------------|-----------------------------------|
| MariaDB    | 10.11.19, 11.4.13, 11.8.9, 12.3.3 |
| MySQL      | 8.0.40, 8.0.46                     |
| Valkey     | 9.1.1                             |
| beanstalkd | 1.13                              |

Each service is built from an exact upstream release plus a small patch series for WASIX.

## License

Except where otherwise noted, ServiceCache's original code, scripts and documentation are licensed under the [MIT License](LICENSE). Patch series modifying third-party software are licensed as documented in their respective patch directories.

This repository distributes patches and build scripts, not built binaries. A guest built from these sources is licensed under the terms of the software it was built from.

## Trademarks

ServiceCache is an independent project. It is not affiliated with, sponsored by, or endorsed by the trademark owners noted below, or by the maintainers of the software it builds and depends on.

- MariaDB is a registered trademark of MariaDB plc.
- Oracle, Java, MySQL, and NetSuite are registered trademarks of Oracle and/or its affiliates.
- Valkey and the Valkey logo are trademarks of LF Projects, LLC.
- Wasmer is a trademark of Wasmer, Inc.
- Other names may be trademarks of their respective owners.
