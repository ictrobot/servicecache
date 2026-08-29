# ServiceCache

**Fast disposable services for tests.**

ServiceCache runs real server software as WASIX/WebAssembly guests, initializes it once, snapshots the live running state, and hands out isolated copy-on-write clones on demand. A test suite that would otherwise repeat startup, schema creation and fixture import on every run gets a fresh, fully initialized instance in the time it takes to clone a snapshot.

Persistence is explicitly not a goal. Instances are disposable; snapshots live in memory and are discarded with the manager.

See [ARCHITECTURE.md](ARCHITECTURE.md) for the design.

## Status

Early development.
