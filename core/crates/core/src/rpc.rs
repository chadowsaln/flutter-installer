//! JSON-RPC 2.0 method dispatcher. Maps `method` strings onto the manager
//! implementations. Long-running calls (downloads, SDK installs) intentionally
//! block the calling thread; the daemon calls `dispatch` from a fresh thread
//! per request, so the stdio loop stays responsive.

use std::sync::Arc;

use serde_json::{json, Value};

use crate::managers::{dart, flutter, path, process, sdk, system};
use crate::{CoreError, Notify};

/// Shared application state: the process registry and any long-lived handles.
pub struct App {
    pub processes: Arc<process::ProcessManager>,
}

impl App {
    pub fn new() -> Self {
        Self {
            processes: Arc::new(process::ProcessManager::new()),
        }
    }

    pub fn dispatch(&self, method: &str, params: Value, notify: &Notify) -> Result<Value, CoreError> {
        match method {
            // ---------- system ----------
            "system.info" => Ok(system::info()),
            "system.check" => system::check(notify).map_err(Into::into),

            // ---------- sdk ----------
            "sdk.list" => Ok(sdk::list()),
            "sdk.known" => Ok(sdk::known()),
            "sdk.install" => {
                let kind = param_str(&params, "kind").ok_or_else(|| missing("kind"))?;
                let version = param_str(&params, "version");
                let dir = param_str(&params, "dir");
                let add_to_path = param_bool(&params, "addToPath").unwrap_or(true);
                let replace = param_bool(&params, "replace").unwrap_or(true);
                sdk::install(kind, version, dir, add_to_path, replace, notify)
            }

            // ---------- flutter ----------
            "flutter.latest" => {
                let channel = param_str(&params, "channel").unwrap_or("stable");
                flutter::latest(channel).map_err(Into::into)
            }
            "flutter.list" => Ok(flutter::list()),
            "flutter.install" => {
                let version = param_str(&params, "version");
                let channel = param_str(&params, "channel").unwrap_or("stable");
                let dir = param_str(&params, "dir");
                let add_to_path = param_bool(&params, "addToPath").unwrap_or(true);
                let replace = param_bool(&params, "replace").unwrap_or(true);
                flutter::install(version, channel, dir, add_to_path, replace, notify).map_err(Into::into)
            }
            "flutter.uninstall" => {
                let root = param_str(&params, "flutterRoot").ok_or_else(|| missing("flutterRoot"))?;
                flutter::uninstall(root).map_err(Into::into)
            }

            // ---------- dart ----------
            "dart.latest" => dart::latest().map_err(Into::into),
            "dart.list" => Ok(dart::list()),
            "dart.install" => {
                let version = param_str(&params, "version");
                let dir = param_str(&params, "dir");
                let add_to_path = param_bool(&params, "addToPath").unwrap_or(true);
                let replace = param_bool(&params, "replace").unwrap_or(true);
                dart::install(version, dir, add_to_path, replace, notify).map_err(Into::into)
            }
            "dart.uninstall" => {
                let root = param_str(&params, "dartRoot").ok_or_else(|| missing("dartRoot"))?;
                dart::uninstall(root).map_err(Into::into)
            }

            // ---------- path ----------
            "path.get" => Ok(path::get()),
            "path.profiles" => Ok(path::profiles()),
            "path.ensure" => {
                let dir = param_str(&params, "binDir").ok_or_else(|| missing("binDir"))?;
                let profile = param_str(&params, "profile");
                path::ensure(dir, profile, notify).map_err(Into::into)
            }
            "path.remove" => {
                let dir = param_str(&params, "binDir").ok_or_else(|| missing("binDir"))?;
                path::remove(dir).map_err(Into::into)
            }

            // ---------- process ----------
            "process.spawn" => {
                let cmd = param_str(&params, "cmd").ok_or_else(|| missing("cmd"))?;
                let args = param_array_of_str(&params, "args");
                let cwd = param_str(&params, "cwd").map(ToString::to_string);
                let env = params.get("env").cloned().unwrap_or_else(|| json!({}));
                self.processes.spawn(cmd, &args, cwd, env, notify).map_err(Into::into)
            }
            "process.list" => Ok(self.processes.list()),
            "process.terminate" => {
                let pid = param_u64(&params, "pid").ok_or_else(|| missing("pid"))? as u32;
                self.processes.terminate(pid).map_err(Into::into)
            }
            "process.exec" => {
                let cmd = param_str(&params, "cmd").ok_or_else(|| missing("cmd"))?;
                let args = param_array_of_str(&params, "args");
                let cwd = param_str(&params, "cwd").map(ToString::to_string);
                let env = params.get("env").cloned().unwrap_or_else(|| json!({}));
                let timeout = param_u64(&params, "timeoutMs");
                self.processes.exec(cmd, &args, cwd, env, timeout).map_err(Into::into)
            }

            "ping" => Ok(json!({ "pong": true })),
            _ => Err(CoreError::new(-32601, format!("method not found: {method}"))),
        }
    }
}

impl Default for App {
    fn default() -> Self {
        Self::new()
    }
}

fn missing(name: &str) -> CoreError {
    CoreError::new(-32602, format!("missing required parameter: {name}"))
}

fn param_str<'a>(params: &'a Value, name: &str) -> Option<&'a str> {
    params.get(name).and_then(|v| v.as_str())
}

fn param_bool(params: &Value, name: &str) -> Option<bool> {
    params.get(name).and_then(|v| v.as_bool())
}

fn param_u64(params: &Value, name: &str) -> Option<u64> {
    params.get(name).and_then(|v| v.as_u64())
}

fn param_array_of_str(params: &Value, name: &str) -> Vec<String> {
    params
        .get(name)
        .and_then(|v| v.as_array())
        .map(|a| {
            a.iter()
                .filter_map(|v| v.as_str())
                .map(ToString::to_string)
                .collect()
        })
        .unwrap_or_default()
}