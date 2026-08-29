# ServiceCache architecture

ServiceCache is a generic manager for disposable test services. It runs server software as WASIX guests, freezes initialized instances, and clones them on demand. It knows how to run WebAssembly modules, hand them network sockets, freeze and fork; it does not know what a database is.

## Core model

1. Start a server as a WASIX guest on a clean filesystem, in a host process of its own.
2. Optionally initialize it through the service's own client — itself a WASIX module run by the same runtime — speaking the ordinary application protocol.
3. Freeze the host at a quiescent point: idle, after the initializer has disconnected. A frozen host is a template; it never runs again.
4. Serve requests for the same recipe by forking the template. The kernel shares its memory and its in-memory filesystem copy-on-write.
5. Give each clone its own network endpoint; destroy it after use.

## Processes

- **The manager never runs a guest.** It spawns one host process per guest, creates each guest's listening socket itself — loopback TCP with a kernel-assigned port — and passes it to the host, and hands out endpoints. It is not on the data path: clients connect to a clone's socket directly, and guest memory is opaque bytes to it.
- **A host (`servicecache host`) runs exactly one guest** on the embedded runtime: the guest's linear memory and an in-memory filesystem with the manifest's read-only mounts.
- **A control thread drives the host.** It runs a synchronous loop over a socketpair inherited from the manager: `prepare`, `start`, `initialize`, `freeze`, `fork` and `stop` in; `ready`, `exited`, `frozen`, `forked` and `error` out; descriptors such as the listening socket travel with their message as `SCM_RIGHTS`. Hosts die with the manager.
- **The runtime is Wasmer with a patch series.** `patches/wasmer/` is applied to a checkout under `work/wasmer` that the workspace builds against. The Wasmer CLI that builds and smoke-tests guests is a separate stock installation.

## Design rules

The manager and its guests are designed to be independent programs. Their only interfaces are the WASIX ABI and the service's own network protocol.

1. **The manager is generic.** It has no service-specific knowledge; guest memory is opaque bytes to it.
2. **Guests import only the standard WASIX ABI.** Every guest runs unchanged under stock Wasmer.
3. **Initialization is the service's own client.** Upstream's client, built for WASIX, speaking the service's own protocol.
4. **Guest patches make sense without ServiceCache.** Anyone running the server under plain Wasmer should want them.
5. **Freeze and clone happen in the runtime.** The guest never knows.
6. **No state is shipped.** Guests start on a clean filesystem.
7. **Manifests are plain files.** No inheritance, no merging.

## Services

A service is a directory of artifacts plus a manifest. The directory `make services` produces (`work/services/<name>-<version>/`) is byte-for-byte the layout an installed package uses. For an imaginary service `exampledb`:

```text
exampledb-1.2.3/
├── service.toml
├── exampledbd.wasm      server
├── exampledb-cli.wasm   upstream client, used as the initializer
├── share/               read-only support files the server needs at runtime
└── BUILD-INFO           upstream tag, ServiceCache commit, toolchain pins
```

### Manifest

A service is up to three runs of WASIX modules, each described by its own table. The manager knows only how to run a module; the tables differ in wiring, not in kind.

```toml
[service]
name    = "exampledb"
version = "1.2.3"

[prepare]                                       # optional: build the filesystem the guest starts on
fs     = { "/usr/share/exampledb" = "share/" }  # read-only trees from the package
module = "exampledbd.wasm"                      # optional: run to exit 0 on that filesystem, no network
args   = ["--init", "--data=/data"]

[guest]                                         # the server
module      = "exampledbd.wasm"
args        = ["--data=/data", "--port=4000"]
listen_port = 4000

[initializer]                                   # optional: run against the guest, recipe on stdin
module = "exampledb-cli.wasm"
args   = ["--host", "{host}", "--port", "{port}"]
```

- Paths are relative to the manifest's directory; absolute paths are an error.
- The writable filesystem always starts clean; no state is shipped. `[prepare]` builds what `[guest]` starts on: `fs` mounts read-only trees shipped in the package, and `module`, if present, runs to completion on that filesystem with no network.
- `listen_port` is the port the server binds inside the guest. The socket it gets is the one the manager passed, so a guest never binds a real host port; a bind on any other port is refused.
- `[initializer]` runs against the guest's endpoint with `{host}` and `{port}` substituted, receives the recipe on stdin, and must exit 0. The manager never interprets its arguments.
- Manifests are plain files; the manager never merges or inherits them.
