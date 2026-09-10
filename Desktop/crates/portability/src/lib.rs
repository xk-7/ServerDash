//! File and wire compatibility with the shipping Apple client. No UI or credential persistence.
pub mod ai;
pub mod config;
pub mod recording;
pub mod sessions;

use serde::{Deserialize, Deserializer, Serializer};
use uuid::Uuid;

/// Foundation JSONEncoder writes UUID strings in uppercase. In particular this spelling
/// is input to the local configuration identity hash; using Rust's lowercase display is wrong.
pub(crate) mod swift_uuid {
    use super::*;
    pub fn serialize<S: Serializer>(
        id: &Uuid,
        serializer: S,
    ) -> std::result::Result<S::Ok, S::Error> {
        serializer.serialize_str(&id.to_string().to_uppercase())
    }
    pub fn deserialize<'de, D: Deserializer<'de>>(
        deserializer: D,
    ) -> std::result::Result<Uuid, D::Error> {
        let text = String::deserialize(deserializer)?;
        Uuid::parse_str(&text).map_err(serde::de::Error::custom)
    }
}

/// Foundation Date's default Codable representation is seconds since 2001-01-01 UTC.
pub const FOUNDATION_EPOCH_UNIX_SECONDS: f64 = 978_307_200.0;

#[derive(Debug, thiserror::Error)]
pub enum Error {
    #[error("Invalid or unsupported data")]
    Invalid,
    #[error("Data exceeds the supported size limit")]
    TooLarge,
    #[error("Operation cancelled")]
    Cancelled,
    #[error("Unsupported endpoint or parameters")]
    Configuration,
    #[error("Invalid recovery key or encrypted package")]
    Crypto,
    #[error("Resolve every conflict before applying changes")]
    Conflict,
    #[error("Configuration changed after the preview; preview again")]
    Changed,
    #[error("Server does not support reliable strong ETag conditional writes")]
    ConditionalWrites,
    #[error("Request failed (HTTP {0})")]
    Http(u16),
    #[error("Network request failed")]
    Network,
    #[error("AI response stream ended without a valid completion")]
    IncompleteStream,
    #[error("Format is awaiting external client validation")]
    UnvalidatedExport,
    #[error("File operation failed: {0}")]
    Io(#[from] std::io::Error),
    #[error("Invalid JSON data")]
    Json(#[from] serde_json::Error),
}
pub type Result<T> = std::result::Result<T, Error>;
