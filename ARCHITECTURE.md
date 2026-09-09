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
- **`servicecache serve` is the manager.** It serves an HTTP API on a Unix socket (`/openapi.json` describes it). A request names a service and optionally a recipe, and is answered by forking a frozen template: the base template for a service is brought up (prepare, start) and frozen; a recipe's template is a fork of the base with the initializer run on the clone, frozen in turn, so copy-on-write sharing chains through to every instance. Instances carry a renewable TTL, and a template that has had no running instance or child template for five minutes is destroyed, so an idle manager holds nothing.
- **A host (`servicecache host`) runs exactly one guest** on the embedded runtime: the guest's linear memory, an in-memory filesystem with the manifest's read-only mounts, and one OS thread per guest thread. Each guest thread drives a coroutine that suspends when the guest blocks instead of parking its OS thread, so a thread holds no guest state. Compiled modules are cached under `~/.cache/servicecache` and shared by every host; `servicecache cache clean` removes them. Manager and hosts log through `tracing` to stderr (`-v` repeated, `--log DIRECTIVES`, `SERVICECACHE_LOG`); a host is started with the manager's filter, so the same setting follows a freeze into its clones. Each host titles itself over its command line, so `ps` and `htop` show `servicecache template exampledb@1.2.3`, `servicecache template exampledb@1.2.3 recipe fa9b30bc` and `servicecache instance exampledb@1.2.3 recipe fa9b30bc listening on 127.0.0.1:46361` in the process tree.
- **A control thread drives the host.** It runs a synchronous loop over a socketpair inherited from the manager: `prepare`, `start`, `initialize`, `freeze`, `fork` and `stop` in; `ready`, `exited`, `frozen`, `forked` and `error` out; descriptors such as the listening socket travel with their message as `SCM_RIGHTS`. Hosts die with the manager.
- **Freeze is terminal.** The host waits until every guest thread is suspended in a wait, ends every thread but the control thread, and verifies the process has one thread. A frozen host is a template: it answers only `fork` and `stop`. Its clients are disconnected at the freeze and its port refuses connections from then on, so a clone inherits no connection, and every live shared-memory object is copied into private frozen backing along with its mappings. Afterwards the template gives the all-zero pages of the guest's memory back to the kernel, in slices between requests, so that it keeps less resident and a fork copies fewer page-table entries; the guest cannot tell.
- **A clone is a `fork()` of a template.** The child rebuilds what the parent dismantled — clone-local shared memory replayed from the frozen snapshot, the tokio runtime, the selector, one thread per guest coroutine, the listening socket the manager passed for it — resumes every coroutine where it stopped, and serves on its own control channel. Clones die with their template.
- **The runtime is Wasmer with a patch series.** Wasmer is built in named variants, each an ordered list of patch sets applied to the pinned tag (`wasmer/<variant>/variant.env`, described in `wasmer/README`): `stock` applies none, `fixes` carries fixes to upstream that are not specific to ServiceCache, `extensions` carries the fixes set and the extension sets, and `servicecache` adds its own set on top of fixes and extensions and is what the workspace builds the host against (`work/src/wasmer/servicecache`). Every variant's CLI is built from source into `work/wasmer/<variant>`. Suspension is off unless the host enables it. The CLI that builds and smoke-tests a package's guests is `stock`, which a guest with no extension declaration must run under unchanged; a package that declares extensions uses the `extensions` variant instead.

## Freezing and resurrection

Each guest thread is an OS thread driving a coroutine that runs the guest's Wasm. Every blocking path (a socket wait, a futex, a sleep) suspends the coroutine back to its host thread with its pending wait, instead of parking the OS thread inside the runtime, so at a quiescent instant a guest thread's entire state is its coroutine and the guest memory it points into.

A freeze waits for that instant: every coroutine suspended in a wait, no guest thread starting or exiting, host output flushed. The host then dismantles execution, ending the guest threads and the selector and abandoning the tokio runtime, and verifies the process has exactly one thread before answering. One thread makes `fork()` safe: no lock can be held by a thread that does not exist in the child.

A fork resurrects the guest in the child. The runtime is rebuilt (tokio, the selector, epoll), a fresh OS thread is started for each coroutine with its per-thread state restored, each pending wait is re-created, and every coroutine resumes where it suspended. The child adopts the listening socket the manager passed for it and serves. The parent stays frozen and is only ever forked again. The kernel shares the template's memory with every clone copy-on-write, which is where the speed and the density come from.

## Design rules

The manager and its guests are designed to be independent programs. Their only interfaces are the WASIX ABI and the service's own network protocol.

1. **The manager is generic.** It has no service-specific knowledge; guest memory is opaque bytes to it.
2. **Guests import only the standard WASIX ABI.** Every guest runs unchanged under stock Wasmer, enforced at assembly against a pinned baseline of import namespaces — unless the package declares an extension under rule 8.
3. **Initialization is the service's own client.** Upstream's client, built for WASIX, speaking the service's own protocol.
4. **Guest patches make sense without ServiceCache.** Anyone running the server under plain Wasmer should want them.
5. **Freeze and clone happen in the runtime.** The guest never knows.
6. **No state is shipped.** Guests start on a clean filesystem.
7. **Manifests are plain files.** No inheritance, no merging.
8. **Extensions are narrow, generic and opt in.** A guest-visible extension is program-agnostic and POSIX-shaped, declared by the package, and enforced by the linker; see Extensions below.

## Extensions

An extension adds a program-agnostic, POSIX-shaped, guest-visible primitive to the runtime's WASIX surface.

Each extension lives whole in `extensions/<name>/`: its specification, the guest header, a demo, its smoke test and its own Wasmer patch set. The namespace is versioned and author-prefixed (`ictrobot_<name>_v<n>`). The implementation belongs to the runtime, not the manager, and stays free of anything project-specific, so it can be proposed upstream.

A package opts in by setting `SC_GUEST_EXTENSIONS` in its `version.env` and listing the same namespaces under `extensions` in `service.toml`'s `[service]` table. Assembly checks every built module's imports against the declaration.

At run time the host registers only the declared namespaces, so an undeclared import fails to instantiate exactly as it would under stock Wasmer. The declaration may be a superset of what the manifest's own modules import: a service can load other modules from its package, and the declaration is the allowance for all of them.

Only permissively licensed modules (the service and all its dependencies) import extensions.

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
stdin_file = "share/bootstrap.sql"              # optional: package file piped to the module's stdin

[guest]                                         # the server
module      = "exampledbd.wasm"
args        = ["--data=/data", "--port=4000"]
listen_port = 4000
ready       = { send = '\x00ping', matches = '^ok\x00' }  # optional: proof it serves

[initializer]                                   # optional: run against the guest, recipe on stdin
module = "exampledb-cli.wasm"
args   = ["--host", "{host}", "--port", "{port}"]
```

- Paths are relative to the manifest's directory; absolute paths are an error.
- The writable filesystem always starts clean; no state is shipped. `[prepare]` builds what `[guest]` starts on: `fs` mounts read-only trees shipped in the package, and `module`, if present, runs to completion on that filesystem with no network; `stdin_file`, if present, is a package file piped to that run's standard input.
- `listen_port` is the port the server binds inside the guest. The socket it gets is the one the manager passed, so a guest never binds a real host port; a bind on any other port is refused.
- `ready`, if present, is bytes the host writes to the guest's endpoint and a bytes regex the response must match before the guest is reported ready. It delays ready, and the initializer with it, where a server has a startup phase in which it answers connections with an error; and it ensures the server is actually in its accept loop before the template freezes. `send` is a byte string, printable ASCII with `\xNN` escapes, omitted where the server speaks first; write both fields in single-quoted TOML strings. Absent, listening is readiness.
- `[initializer]` runs against the guest's endpoint with `{host}` and `{port}` substituted, receives the recipe on stdin, and must exit 0. The manager never interprets its arguments.
- Manifests are plain files; the manager never merges or inherits them.
