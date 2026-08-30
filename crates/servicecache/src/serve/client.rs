//! A blocking client for a manager's API on its Unix socket, used by
//! `servicecache request` and the tests. One connection per call.

use std::path::PathBuf;

use anyhow::{Context as _, Result, anyhow};
use http_body_util::{BodyExt as _, Full};
use hyper::{Method, Request, StatusCode, body::Bytes, header};
use serde::de::DeserializeOwned;

use super::api::{CreateInstance, Instance, Problem, RenewInstance, ServiceEntry};

/// The manager refused a request; carries the problem it answered with.
#[derive(Debug, Clone)]
pub struct ApiError(pub Problem);

impl std::fmt::Display for ApiError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(
            f,
            "the manager refused ({}): {}",
            self.0.status, self.0.title
        )?;
        if let Some(detail) = &self.0.detail {
            write!(f, ": {detail}")?;
        }
        Ok(())
    }
}

impl std::error::Error for ApiError {}

/// A client for one manager.
pub struct Client {
    socket: PathBuf,
    runtime: tokio::runtime::Runtime,
}

impl Client {
    /// A client for the manager on `socket`.
    ///
    /// # Errors
    ///
    /// Fails when the client's runtime cannot be created.
    pub fn new(socket: PathBuf) -> Result<Self> {
        let runtime = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .context("failed to start the client's runtime")?;
        Ok(Self { socket, runtime })
    }

    /// The installed services.
    ///
    /// # Errors
    ///
    /// Fails when the manager cannot be reached or refuses.
    pub fn services(&self) -> Result<Vec<ServiceEntry>> {
        self.expect_json(Method::GET, "/v1/services", None, StatusCode::OK)
    }

    /// Creates an instance; blocks through the service's bring-up.
    ///
    /// # Errors
    ///
    /// Fails when the manager cannot be reached or refuses ([`ApiError`]).
    pub fn create(&self, request: &CreateInstance) -> Result<Instance> {
        let body = serde_json::to_vec(request).context("failed to encode the request")?;
        self.expect_json(
            Method::POST,
            "/v1/instances",
            Some(body),
            StatusCode::CREATED,
        )
    }

    /// The running instances.
    ///
    /// # Errors
    ///
    /// Fails when the manager cannot be reached or refuses.
    pub fn instances(&self) -> Result<Vec<Instance>> {
        self.expect_json(Method::GET, "/v1/instances", None, StatusCode::OK)
    }

    /// One instance's state.
    ///
    /// # Errors
    ///
    /// Fails when the manager cannot be reached or refuses ([`ApiError`],
    /// 404 once the instance is gone).
    pub fn instance(&self, id: &str) -> Result<Instance> {
        self.expect_json(
            Method::GET,
            &format!("/v1/instances/{id}"),
            None,
            StatusCode::OK,
        )
    }

    /// Restarts an instance's TTL, changing it when `ttl_seconds` is given.
    ///
    /// # Errors
    ///
    /// Fails when the manager cannot be reached or refuses ([`ApiError`],
    /// 409 when the guest has exited).
    pub fn renew(&self, id: &str, ttl_seconds: Option<u64>) -> Result<Instance> {
        let body = serde_json::to_vec(&RenewInstance { ttl_seconds })
            .context("failed to encode the request")?;
        self.expect_json(
            Method::POST,
            &format!("/v1/instances/{id}/renew"),
            Some(body),
            StatusCode::OK,
        )
    }

    /// Destroys an instance.
    ///
    /// # Errors
    ///
    /// Fails when the manager cannot be reached or refuses ([`ApiError`]).
    pub fn delete(&self, id: &str) -> Result<()> {
        let (status, body) = self.call(Method::DELETE, &format!("/v1/instances/{id}"), None)?;
        if status != StatusCode::NO_CONTENT {
            return Err(refusal(status, &body));
        }
        Ok(())
    }

    fn expect_json<T: DeserializeOwned>(
        &self,
        method: Method,
        path: &str,
        body: Option<Vec<u8>>,
        expected: StatusCode,
    ) -> Result<T> {
        let (status, bytes) = self.call(method, path, body)?;
        if status != expected {
            return Err(refusal(status, &bytes));
        }
        serde_json::from_slice(&bytes).context("the manager answered with an undecodable body")
    }

    fn call(
        &self,
        method: Method,
        path: &str,
        body: Option<Vec<u8>>,
    ) -> Result<(StatusCode, Bytes)> {
        self.runtime.block_on(async {
            let stream = tokio::net::UnixStream::connect(&self.socket)
                .await
                .with_context(|| format!("failed to connect to {}", self.socket.display()))?;
            let (mut sender, connection) =
                hyper::client::conn::http1::handshake(hyper_util::rt::TokioIo::new(stream))
                    .await
                    .context("the HTTP handshake failed")?;
            let connection = tokio::spawn(connection);
            let request = Request::builder()
                .method(method)
                .uri(path)
                .header(header::HOST, "servicecache")
                .header(header::CONNECTION, "close")
                .header(header::CONTENT_TYPE, "application/json")
                .body(Full::new(Bytes::from(body.unwrap_or_default())))
                .context("failed to build the request")?;
            let response = sender
                .send_request(request)
                .await
                .context("the request failed")?;
            let status = response.status();
            let bytes = response
                .into_body()
                .collect()
                .await
                .context("failed to read the reply")?
                .to_bytes();
            drop(sender);
            connection.await.ok();
            Ok((status, bytes))
        })
    }
}

/// The error for a reply with the wrong status: the problem it carried,
/// or a description of what came instead.
fn refusal(status: StatusCode, body: &[u8]) -> anyhow::Error {
    match serde_json::from_slice::<Problem>(body) {
        Ok(problem) => anyhow::Error::new(ApiError(problem)),
        Err(_) => anyhow!(
            "the manager answered {status}: {}",
            String::from_utf8_lossy(body)
        ),
    }
}
