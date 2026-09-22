//! Flutter Installer core.
//!
//! A platform-neutral Rust library exposing six managers consumed by the
//! JSON-RPC daemon (and, in the future, by Tauri commands):
//!
//! - `sdk`      : SDK Manager - orchestrates Flutter + Dart SDK installs
//! - `dart`     : Dart Manager - standalone Dart SDK install/listing
//! - `flutter`  : Flutter Manager - Flutter SDK install/listing
//! - `path`     : PATH Manager - shell profile / PATH manipulation
//! - `process`  : Process Manager - spawn/stream/terminate sub-processes
//! - `system`   : System Checker - OS/arch/prerequisite/network detection

pub mod managers;
pub mod rpc;

use serde_json::Value;

pub type Notify = std::sync::Arc<dyn Fn(Value) + Send + Sync>;

/// Error returned to the RPC layer; carries a JSON-RPC error code.
#[derive(Debug, Clone)]
pub struct CoreError {
    pub code: i64,
    pub message: String,
    pub data: Option<Value>,
}

impl CoreError {
    pub fn new(code: i64, message: impl Into<String>) -> Self {
        Self {
            code,
            message: message.into(),
            data: None,
        }
    }
}

impl std::fmt::Display for CoreError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}", self.message)
    }
}

impl std::error::Error for CoreError {}

impl From<anyhow::Error> for CoreError {
    fn from(e: anyhow::Error) -> Self {
        CoreError::new(-32000, format!("{e:#}"))
    }
}