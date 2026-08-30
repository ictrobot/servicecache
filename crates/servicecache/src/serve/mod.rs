//! `servicecache serve`: the manager's HTTP API on a Unix socket. A
//! request for an instance forks it off the frozen template for its
//! service and recipe — filled through the fork chain on the first
//! request — and answers with the endpoint; instances live until deleted
//! or until their TTL runs out unrenewed.

pub mod api;
pub mod client;
mod instances;
mod recipes;
mod templates;

use std::{
    io::{Read as _, Write as _},
    path::{Path, PathBuf},
    sync::Arc,
    time::Duration,
};

use anyhow::{Context as _, Result, bail};
use axum::{
    Json, Router,
    body::Bytes,
    extract::{Path as PathParam, Request, State},
    http::{StatusCode, header},
    middleware::Next,
    response::Response,
};
use utoipa::OpenApi as _;
use utoipa_axum::{router::OpenApiRouter, routes};

use crate::discovery::{SelectError, ServiceIndex};
use instances::Registry;
use templates::Templates;

/// How long an instance lives without a renewal, unless the request says.
const DEFAULT_TTL: Duration = Duration::from_secs(300);
/// How long a template lives with no live descendant — no running
/// instance and no child template — before its frozen host is destroyed;
/// counted from its freeze when it is never forked.
pub const DEFAULT_TEMPLATE_TTL: Duration = Duration::from_secs(300);
/// The longest TTL a request may ask for, in seconds.
const MAX_TTL_SECONDS: u64 = 86400;
/// The largest request body: room for the largest recipe the control
/// channel accepts (256 MiB), base64-encoded.
const MAX_BODY: usize = 512 * 1024 * 1024;

/// What `serve` runs with.
pub struct Options {
    /// The Unix socket to listen on.
    pub socket: PathBuf,
    /// The installed services.
    pub services: ServiceIndex,
    /// Where compiled modules are cached.
    pub cache_dir: PathBuf,
    /// How long an idle template lives ([`DEFAULT_TEMPLATE_TTL`] outside
    /// tests).
    pub template_ttl: Duration,
    /// Directories requests may name recipe files under; empty keeps the
    /// feature off.
    pub recipe_roots: Vec<PathBuf>,
}

struct App {
    services: ServiceIndex,
    cache_dir: PathBuf,
    registry: Registry,
    templates: Templates,
    recipe_roots: recipes::Roots,
}

/// What the listener knows about a connection: the peer's uid from
/// `SO_PEERCRED`, when the socket yields one.
#[derive(Debug, Clone, Copy)]
struct Peer {
    uid: Option<u32>,
}

impl
    axum::extract::connect_info::Connected<
        axum::serve::IncomingStream<'_, tokio::net::UnixListener>,
    > for Peer
{
    fn connect_info(stream: axum::serve::IncomingStream<'_, tokio::net::UnixListener>) -> Self {
        Self {
            uid: stream.io().peer_cred().ok().map(|cred| cred.uid()),
        }
    }
}

/// Serves the API until SIGINT or SIGTERM.
///
/// # Errors
///
/// Fails when the socket is already served or cannot be bound.
pub fn run(options: Options) -> Result<()> {
    claim_socket(&options.socket)?;
    let app = Arc::new(App {
        services: options.services,
        cache_dir: options.cache_dir,
        registry: Registry::default(),
        templates: Templates::new(options.template_ttl),
        recipe_roots: recipes::Roots::new(&options.recipe_roots)?,
    });
    let runtime = tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .build()
        .context("failed to start the server's runtime")?;
    let result = runtime.block_on(serve_on(&options.socket, app));
    std::fs::remove_file(&options.socket).ok();
    result
}

/// Makes way for the socket: errors if a server answers on it, removes it
/// if it is stale, and creates its parent directory (mode 700) if needed.
fn claim_socket(socket: &Path) -> Result<()> {
    if socket.exists() {
        if std::os::unix::net::UnixStream::connect(socket).is_ok() {
            bail!("{} is already being served", socket.display());
        }
        std::fs::remove_file(socket)
            .with_context(|| format!("failed to remove the stale socket {}", socket.display()))?;
    } else if let Some(parent) = socket.parent()
        && !parent.as_os_str().is_empty()
        && !parent.exists()
    {
        use std::os::unix::fs::DirBuilderExt as _;
        std::fs::DirBuilder::new()
            .recursive(true)
            .mode(0o700)
            .create(parent)
            .with_context(|| format!("failed to create {}", parent.display()))?;
    }
    Ok(())
}

async fn serve_on(socket: &Path, app: Arc<App>) -> Result<()> {
    let listener = tokio::net::UnixListener::bind(socket)
        .with_context(|| format!("failed to bind {}", socket.display()))?;
    // Registered before the ready line goes out, so a signal sent as soon
    // as it appears still shuts down cleanly.
    let shutdown = shutdown_signal()?;

    // The bare socket path on stdout for scripts, and a labelled line on
    // stderr, where the logs go, so it stands out there.
    println!("listening on {}", socket.display());
    std::io::stdout()
        .flush()
        .context("failed to write the socket path")?;
    eprintln!(
        "==> serving the API on {} (try `curl --unix-socket {} localhost/v1/services`). Ctrl-C to stop.",
        socket.display(),
        socket.display()
    );

    let sweeper = tokio::spawn(sweep(Arc::clone(&app)));
    let router = router(Arc::clone(&app));
    axum::serve(
        listener,
        router.into_make_service_with_connect_info::<Peer>(),
    )
    .with_graceful_shutdown(shutdown)
    .await
    .context("the server failed")?;
    sweeper.abort();
    // Dropping the entries and templates tells their threads to stop
    // their hosts; whatever is still shutting down when the process exits
    // dies with it (hosts die with the thread that spawned them).
    app.registry.clear();
    app.templates.clear();
    Ok(())
}

/// A future resolving on SIGINT or SIGTERM; the handlers are registered
/// here, at the call, not on first poll.
fn shutdown_signal() -> Result<impl std::future::Future<Output = ()>> {
    use tokio::signal::unix::{SignalKind, signal};

    let mut interrupt =
        signal(SignalKind::interrupt()).context("failed to install the SIGINT handler")?;
    let mut terminate =
        signal(SignalKind::terminate()).context("failed to install the SIGTERM handler")?;
    Ok(async move {
        tokio::select! {
            _ = interrupt.recv() => {}
            _ = terminate.recv() => {}
        }
    })
}

/// Destroys expired instances and forgets expired templates' slots, once
/// a second. Templates expire themselves, on their owner threads; this
/// only keeps the map from accumulating their keys.
async fn sweep(app: Arc<App>) {
    let mut interval = tokio::time::interval(Duration::from_secs(1));
    loop {
        interval.tick().await;
        for entry in app.registry.remove_expired() {
            tracing::info!(id = entry.id, service = entry.service, "instance expired");
        }
        app.templates.prune();
    }
}

#[derive(utoipa::OpenApi)]
#[openapi(info(
    title = "servicecache",
    description = "Fast disposable services for tests",
    license(name = "MIT")
))]
struct ApiDoc;

fn router(app: Arc<App>) -> Router {
    let (router, document) = OpenApiRouter::with_openapi(ApiDoc::openapi())
        .routes(routes!(list_services))
        .routes(routes!(create_instance, list_instances))
        .routes(routes!(get_instance, delete_instance))
        .routes(routes!(renew_instance))
        .split_for_parts();
    let document = Arc::new(document);
    router
        .route(
            "/openapi.json",
            axum::routing::get(move || std::future::ready(Json((*document).clone()))),
        )
        .fallback(|| std::future::ready(api::Problem::unknown_route()))
        .method_not_allowed_fallback(|| std::future::ready(api::Problem::method_not_allowed()))
        .layer(axum::extract::DefaultBodyLimit::max(MAX_BODY))
        .layer(axum::middleware::from_fn(access_log))
        .with_state(app)
}

/// The request log: one line per answered request. `serve` shows them by
/// default (its log level starts at `-v`).
async fn access_log(request: Request, next: Next) -> Response {
    let method = request.method().clone();
    let path = request.uri().path().to_owned();
    let started = std::time::Instant::now();
    let response = next.run(request).await;
    tracing::info!(
        %method,
        %path,
        status = response.status().as_u16(),
        elapsed = ?started.elapsed(),
        "request"
    );
    response
}

/// List the installed services.
#[utoipa::path(get, path = "/v1/services",
    responses((status = 200, body = [api::ServiceEntry])))]
async fn list_services(State(app): State<Arc<App>>) -> Json<Vec<api::ServiceEntry>> {
    Json(
        app.services
            .iter()
            .map(|package| api::ServiceEntry {
                name: package.manifest.service.name.clone(),
                version: package.manifest.service.version.clone(),
            })
            .collect(),
    )
}

/// List the running instances.
#[utoipa::path(get, path = "/v1/instances",
    responses((status = 200, body = [api::Instance])))]
async fn list_instances(State(app): State<Arc<App>>) -> Json<Vec<api::Instance>> {
    Json(
        app.registry
            .list()
            .iter()
            .map(|entry| entry.describe())
            .collect(),
    )
}

/// Create an instance: bring the service up and answer with its endpoint.
#[utoipa::path(post, path = "/v1/instances", request_body = api::CreateInstance,
    responses(
        (status = 201, body = api::Instance,
            headers(("Location" = String, description = "The instance's URL"))),
        (status = 400, body = api::Problem, content_type = "application/problem+json"),
        (status = 403, body = api::Problem, content_type = "application/problem+json"),
        (status = 404, body = api::Problem, content_type = "application/problem+json"),
        (status = 409, body = api::Problem, content_type = "application/problem+json"),
        (status = 413, body = api::Problem, content_type = "application/problem+json"),
        (status = 500, body = api::Problem, content_type = "application/problem+json")))]
async fn create_instance(
    State(app): State<Arc<App>>,
    axum::extract::ConnectInfo(peer): axum::extract::ConnectInfo<Peer>,
    body: Bytes,
) -> Result<
    (
        StatusCode,
        [(header::HeaderName, String); 1],
        Json<api::Instance>,
    ),
    api::Problem,
> {
    let request: api::CreateInstance =
        serde_json::from_slice(&body).map_err(api::Problem::invalid_body)?;
    let ttl = ttl_duration(request.ttl_seconds)?.unwrap_or(DEFAULT_TTL);
    let recipe = recipe_bytes(&app, peer, &request).await?;
    let manifest = app
        .services
        .select(&request.service, request.version.as_deref())
        .map_err(|error| match error {
            SelectError::NotFound => {
                api::Problem::unknown_service(&request.service, request.version.as_deref())
            }
            SelectError::Ambiguous(versions) => {
                api::Problem::ambiguous_version(&request.service, &versions)
            }
        })?;
    if recipe.is_some() && manifest.initializer.is_none() {
        return Err(api::Problem::no_initializer(&request.service));
    }

    let service = manifest.service.name.clone();
    let version = manifest.service.version.clone();
    let id = new_id().map_err(api::Problem::internal)?;
    tracing::info!(id, service, version, "creating an instance");
    let template = app
        .templates
        .obtain(manifest, recipe.as_deref(), &app.cache_dir)
        .await?;
    let (host, endpoint) = match template.fork().await {
        Ok(forked) => forked,
        Err(problem) => {
            // The template died since it was filled; rebuild it once.
            tracing::warn!(id, service, %problem, "the template failed; rebuilding");
            app.templates.forget(manifest, recipe.as_deref());
            app.templates
                .obtain(manifest, recipe.as_deref(), &app.cache_dir)
                .await?
                .fork()
                .await?
        }
    };

    let entry = instances::adopt(id.clone(), service, version, host, endpoint, ttl)
        .map_err(|error| api::Problem::internal(format!("{error:#}")))?;
    let described = entry.describe();
    app.registry.insert(Arc::new(entry));
    tracing::info!(id, %endpoint, "instance forked");
    Ok((
        StatusCode::CREATED,
        [(header::LOCATION, format!("/v1/instances/{id}"))],
        Json(described),
    ))
}

/// An instance's state.
#[utoipa::path(get, path = "/v1/instances/{id}",
    params(("id" = String, Path, description = "The instance's identifier")),
    responses(
        (status = 200, body = api::Instance),
        (status = 404, body = api::Problem, content_type = "application/problem+json")))]
async fn get_instance(
    State(app): State<Arc<App>>,
    PathParam(id): PathParam<String>,
) -> Result<Json<api::Instance>, api::Problem> {
    app.registry
        .get(&id)
        .map(|entry| Json(entry.describe()))
        .ok_or_else(|| api::Problem::unknown_instance(&id))
}

/// Destroy an instance.
#[utoipa::path(delete, path = "/v1/instances/{id}",
    params(("id" = String, Path, description = "The instance's identifier")),
    responses(
        (status = 204),
        (status = 404, body = api::Problem, content_type = "application/problem+json")))]
async fn delete_instance(
    State(app): State<Arc<App>>,
    PathParam(id): PathParam<String>,
) -> Result<StatusCode, api::Problem> {
    let entry = app
        .registry
        .remove(&id)
        .ok_or_else(|| api::Problem::unknown_instance(&id))?;
    tracing::info!(id, service = entry.service, "instance destroyed");
    drop(entry);
    Ok(StatusCode::NO_CONTENT)
}

/// Restart an instance's TTL so it lives on.
#[utoipa::path(post, path = "/v1/instances/{id}/renew", request_body = api::RenewInstance,
    params(("id" = String, Path, description = "The instance's identifier")),
    responses(
        (status = 200, body = api::Instance),
        (status = 400, body = api::Problem, content_type = "application/problem+json"),
        (status = 404, body = api::Problem, content_type = "application/problem+json"),
        (status = 409, body = api::Problem, content_type = "application/problem+json")))]
async fn renew_instance(
    State(app): State<Arc<App>>,
    PathParam(id): PathParam<String>,
    body: Bytes,
) -> Result<Json<api::Instance>, api::Problem> {
    let request: api::RenewInstance = if body.is_empty() {
        api::RenewInstance::default()
    } else {
        serde_json::from_slice(&body).map_err(api::Problem::invalid_body)?
    };
    let ttl = ttl_duration(request.ttl_seconds)?;
    let entry = app
        .registry
        .get(&id)
        .ok_or_else(|| api::Problem::unknown_instance(&id))?;
    if entry.state() != instances::GuestState::Running {
        return Err(api::Problem::instance_exited(&id));
    }
    entry.renew(ttl);
    Ok(Json(entry.describe()))
}

/// The recipe a request carries: decoded from `recipe`, or read from
/// `recipe_files` when the server opted in with `--recipe-root` and the
/// connection is from the server's own user. The peer gate matters
/// because anything forwarding foreign traffic — a proxy on this socket —
/// connects as itself; only same-uid peers could already read the files
/// themselves, and the roots bound the exposure even then.
async fn recipe_bytes(
    app: &Arc<App>,
    peer: Peer,
    request: &api::CreateInstance,
) -> Result<Option<Vec<u8>>, api::Problem> {
    match (&request.recipe, request.recipe_files.as_slice()) {
        (None, []) => Ok(None),
        (Some(_), [_, ..]) => Err(api::Problem::invalid_body(
            "give recipe or recipe_files, not both",
        )),
        (Some(recipe), []) => Ok(Some(api::decode_recipe(recipe)?)),
        (None, files) => {
            if app.recipe_roots.is_empty() {
                return Err(api::Problem::recipe_files_refused(
                    "the server was not started with --recipe-root",
                ));
            }
            let server = unsafe { libc::geteuid() };
            if peer.uid != Some(server) {
                return Err(api::Problem::recipe_files_refused(
                    "recipe files are accepted only from the server's own user",
                ));
            }
            // Off the async workers: the files can be large, and a
            // synchronous read here would stall every request.
            let app = Arc::clone(app);
            let files = files.to_vec();
            tokio::task::spawn_blocking(move || {
                recipes::read(
                    &app.recipe_roots,
                    &files,
                    crate::host::protocol::MAX_PAYLOAD_LEN,
                )
            })
            .await
            .map_err(|_| api::Problem::internal("the recipe reader died"))?
            .map(Some)
        }
    }
}

fn ttl_duration(seconds: Option<u64>) -> Result<Option<Duration>, api::Problem> {
    match seconds {
        None => Ok(None),
        Some(seconds) if (1..=MAX_TTL_SECONDS).contains(&seconds) => {
            Ok(Some(Duration::from_secs(seconds)))
        }
        Some(seconds) => Err(api::Problem::invalid_ttl(seconds)),
    }
}

/// A fresh instance identifier: 16 hex digits of randomness.
fn new_id() -> Result<String> {
    use std::fmt::Write as _;

    let mut bytes = [0_u8; 8];
    std::fs::File::open("/dev/urandom")
        .and_then(|mut file| file.read_exact(&mut bytes))
        .context("failed to read /dev/urandom")?;
    let mut id = String::with_capacity(bytes.len() * 2);
    for byte in bytes {
        let _ = write!(id, "{byte:02x}");
    }
    Ok(id)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ttls_are_bounded() {
        assert_eq!(ttl_duration(None).expect("default"), None);
        assert_eq!(
            ttl_duration(Some(2)).expect("in range"),
            Some(Duration::from_secs(2))
        );
        assert!(ttl_duration(Some(0)).is_err());
        assert!(ttl_duration(Some(MAX_TTL_SECONDS + 1)).is_err());
    }

    #[test]
    fn ids_are_distinct_hex() {
        let first = new_id().expect("id");
        let second = new_id().expect("id");
        assert_eq!(first.len(), 16);
        assert!(first.chars().all(|c| c.is_ascii_hexdigit()));
        assert_ne!(first, second);
    }

    #[test]
    fn the_document_covers_the_routes() {
        let app = Arc::new(App {
            services: ServiceIndex::default(),
            cache_dir: PathBuf::new(),
            registry: Registry::default(),
            templates: Templates::new(DEFAULT_TEMPLATE_TTL),
            recipe_roots: recipes::Roots::default(),
        });
        drop(router(app));
        let document = ApiDoc::openapi();
        // The routes are merged into the served copy, not the derive's;
        // assert the derive holds the identity and the merge the paths.
        assert_eq!(document.info.title, "servicecache");
        let (_, merged) = OpenApiRouter::with_openapi(ApiDoc::openapi())
            .routes(routes!(create_instance, list_instances))
            .split_for_parts();
        assert!(merged.paths.paths.contains_key("/v1/instances"));
    }
}
