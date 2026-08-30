//! The bodies of the manager's HTTP API, shared by the server, the client
//! and the API document (`/openapi.json`). Errors are RFC 9457 problem
//! details with stable `urn:servicecache:<slug>` types.

use std::net::SocketAddr;

use base64::Engine as _;
use serde::{Deserialize, Serialize};
use utoipa::ToSchema;

/// A request for a service instance.
#[derive(Debug, Clone, Default, Serialize, Deserialize, ToSchema)]
pub struct CreateInstance {
    /// The service's name.
    pub service: String,
    /// The exact version; needed when several are installed.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub version: Option<String>,
    /// The initializer's standard input, base64-encoded. Without it the
    /// initializer does not run.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub recipe: Option<String>,
    /// Seconds the instance lives without a renewal; 1 to 86400,
    /// default 300.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub ttl_seconds: Option<u64>,
}

/// A renewal; without a body or `ttl_seconds` the instance's current TTL
/// starts over.
#[derive(Debug, Clone, Default, Serialize, Deserialize, ToSchema)]
pub struct RenewInstance {
    /// The new TTL in seconds; 1 to 86400.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub ttl_seconds: Option<u64>,
}

/// Where an instance serves.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, ToSchema)]
pub struct Endpoint {
    /// The IP address, as text.
    pub host: String,
    /// The TCP port.
    pub port: u16,
}

impl Endpoint {
    /// The endpoint as a socket address.
    ///
    /// # Errors
    ///
    /// Fails when `host` is not an IP address.
    pub fn socket_addr(&self) -> Result<SocketAddr, std::net::AddrParseError> {
        Ok(SocketAddr::new(self.host.parse()?, self.port))
    }
}

impl From<SocketAddr> for Endpoint {
    fn from(address: SocketAddr) -> Self {
        Self {
            host: address.ip().to_string(),
            port: address.port(),
        }
    }
}

/// An instance's state.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, ToSchema)]
#[serde(rename_all = "snake_case")]
pub enum InstanceState {
    Running,
    Exited,
}

/// One instance, as created, listed and polled.
#[derive(Debug, Clone, Serialize, Deserialize, ToSchema)]
pub struct Instance {
    /// The instance's identifier.
    pub id: String,
    /// The service's name.
    pub service: String,
    /// The service's version.
    pub version: String,
    /// Where the instance serves.
    pub endpoint: Endpoint,
    /// Whether the guest is running or has exited.
    pub state: InstanceState,
    /// The guest's exit status, once exited; absent while it runs, or when
    /// the guest went away without reporting one.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub exit_status: Option<i32>,
    /// Seconds until the instance is destroyed unless renewed.
    pub expires_in_seconds: u64,
}

/// An installed service.
#[derive(Debug, Clone, Serialize, Deserialize, ToSchema)]
pub struct ServiceEntry {
    /// The service's name.
    pub name: String,
    /// The service's version.
    pub version: String,
}

/// Encodes recipe bytes for [`CreateInstance::recipe`].
#[must_use]
pub fn encode_recipe(recipe: &[u8]) -> String {
    base64::engine::general_purpose::STANDARD.encode(recipe)
}

/// Decodes [`CreateInstance::recipe`].
///
/// # Errors
///
/// Returns an `invalid-recipe` problem when the field is not base64.
pub fn decode_recipe(recipe: &str) -> Result<Vec<u8>, Problem> {
    base64::engine::general_purpose::STANDARD
        .decode(recipe)
        .map_err(|error| {
            Problem::new(400, "invalid-recipe", "The recipe is not valid base64").with_detail(error)
        })
}

/// An error reply, sent as `application/problem+json` (RFC 9457).
#[derive(Debug, Clone, Serialize, Deserialize, ToSchema)]
pub struct Problem {
    /// A stable identifier for the kind of problem,
    /// `urn:servicecache:<slug>`.
    #[serde(rename = "type")]
    pub kind: String,
    /// A short human-readable summary of the kind of problem.
    pub title: String,
    /// The HTTP status, repeated in the body.
    pub status: u16,
    /// What went wrong in this occurrence.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub detail: Option<String>,
}

impl Problem {
    /// The media type problems are sent as.
    pub const CONTENT_TYPE: &'static str = "application/problem+json";

    #[must_use]
    pub fn new(status: u16, slug: &str, title: &str) -> Self {
        Self {
            kind: format!("urn:servicecache:{slug}"),
            title: title.to_string(),
            status,
            detail: None,
        }
    }

    #[must_use]
    pub fn with_detail(mut self, detail: impl std::fmt::Display) -> Self {
        self.detail = Some(detail.to_string());
        self
    }

    /// Whether this is the problem `urn:servicecache:<slug>`.
    #[must_use]
    pub fn is(&self, slug: &str) -> bool {
        self.kind
            .strip_prefix("urn:servicecache:")
            .is_some_and(|kind| kind == slug)
    }

    #[must_use]
    pub fn invalid_body(error: impl std::fmt::Display) -> Self {
        Self::new(400, "invalid-body", "The request body is not valid").with_detail(error)
    }

    #[must_use]
    pub fn invalid_ttl(seconds: u64) -> Self {
        Self::new(400, "invalid-ttl", "The TTL is out of range")
            .with_detail(format!("{seconds} seconds; the range is 1 to 86400"))
    }

    #[must_use]
    pub fn unknown_service(service: &str, version: Option<&str>) -> Self {
        let spec = match version {
            Some(version) => format!("{service}@{version}"),
            None => service.to_string(),
        };
        Self::new(404, "unknown-service", "No installed service matches")
            .with_detail(format!("no installed service matches {spec}"))
    }

    #[must_use]
    pub fn ambiguous_version(service: &str, versions: &[String]) -> Self {
        Self::new(
            409,
            "ambiguous-version",
            "The service is installed in several versions",
        )
        .with_detail(format!(
            "{service} is installed in several versions ({}); name one",
            versions.join(", ")
        ))
    }

    #[must_use]
    pub fn no_initializer(service: &str) -> Self {
        Self::new(400, "no-initializer", "The service takes no recipe").with_detail(format!(
            "{service} has no initializer to give the recipe to"
        ))
    }

    #[must_use]
    pub fn unknown_instance(id: &str) -> Self {
        Self::new(404, "unknown-instance", "No such instance")
            .with_detail(format!("no instance {id}; it may have expired"))
    }

    #[must_use]
    pub fn instance_exited(id: &str) -> Self {
        Self::new(409, "instance-exited", "The instance's guest has exited")
            .with_detail(format!("instance {id} cannot be renewed"))
    }

    #[must_use]
    pub fn prepare_failed(status: i32) -> Self {
        Self::new(500, "prepare-failed", "The prepare step failed")
            .with_detail(format!("the prepare step exited with status {status}"))
    }

    #[must_use]
    pub fn initializer_failed(status: i32) -> Self {
        Self::new(500, "initializer-failed", "The initializer failed")
            .with_detail(format!("the initializer exited with status {status}"))
    }

    #[must_use]
    pub fn bring_up_failed(error: &anyhow::Error) -> Self {
        Self::new(500, "bring-up-failed", "The instance did not come up")
            .with_detail(format!("{error:#}"))
    }

    #[must_use]
    pub fn internal(detail: impl std::fmt::Display) -> Self {
        Self::new(500, "internal", "Internal error").with_detail(detail)
    }

    #[must_use]
    pub fn unknown_route() -> Self {
        Self::new(404, "unknown-route", "No such route")
    }

    #[must_use]
    pub fn method_not_allowed() -> Self {
        Self::new(
            405,
            "method-not-allowed",
            "The route does not answer this method",
        )
    }
}

impl axum::response::IntoResponse for Problem {
    fn into_response(self) -> axum::response::Response {
        let status = axum::http::StatusCode::from_u16(self.status)
            .unwrap_or(axum::http::StatusCode::INTERNAL_SERVER_ERROR);
        let body = serde_json::to_vec(&self).unwrap_or_default();
        (
            status,
            [(axum::http::header::CONTENT_TYPE, Self::CONTENT_TYPE)],
            body,
        )
            .into_response()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn recipes_round_trip() {
        let bytes = b"SELECT 1;\n\xff";
        let decoded = decode_recipe(&encode_recipe(bytes)).expect("decode");
        assert_eq!(decoded, bytes);
        assert!(decode_recipe("not base64!").is_err());
    }

    #[test]
    fn problems_have_stable_types() {
        let problem = Problem::unknown_service("example", None);
        assert_eq!(problem.kind, "urn:servicecache:unknown-service");
        assert!(problem.is("unknown-service"));
        assert!(!problem.is("unknown-instance"));
        assert_eq!(problem.status, 404);
    }

    #[test]
    fn endpoints_round_trip_through_text() {
        let address: SocketAddr = "127.0.0.1:3456".parse().expect("address");
        assert_eq!(
            Endpoint::from(address).socket_addr().expect("parse"),
            address
        );
        let v6: SocketAddr = "[::1]:80".parse().expect("address");
        assert_eq!(Endpoint::from(v6).socket_addr().expect("parse"), v6);
    }
}
