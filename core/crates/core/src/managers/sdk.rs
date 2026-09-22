//! SDK Manager: orchestrates Flutter + Dart SDK discovery and installation.

use serde_json::{json, Value};

use crate::managers::{dart, flutter};

/// `sdk.list` - all SDKs (Flutter + Dart) this machine knows about.
pub fn list() -> Value {
    json!({
        "flutter": flutter::list(),
        "dart": dart::list(),
    })
}

/// `sdk.known` - the newest available Flutter + Dart versions.
pub fn known() -> Value {
    let flutter = flutter::latest("stable").unwrap_or_else(|_| {
        json!({ "version": null, "channel": "stable", "error": "unable to reach release feed" })
    });
    let dart = dart::latest().unwrap_or_else(|_| {
        json!({ "version": null, "error": "unable to reach dart-archive" })
    });
    json!({ "flutter": flutter, "dart": dart })
}

/// `sdk.install` - install whichever SDK kind is requested.
pub fn install(kind: &str, version: Option<&str>, dir: Option<&str>, add_to_path: bool, replace: bool, notify: &crate::Notify) -> Result<Value, crate::CoreError> {
    match kind {
        "flutter" => Ok(flutter::install(version, "stable", dir, add_to_path, replace, notify)?),
        "dart" => Ok(dart::install(version, dir, add_to_path, replace, notify)?),
        other => Err(crate::CoreError::new(-32602, format!("unknown SDK kind: {other}"))),
    }
}