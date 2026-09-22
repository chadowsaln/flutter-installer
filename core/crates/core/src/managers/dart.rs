//! Dart Manager: resolve and install standalone Dart SDKs, and list the ones
//! already installed on the machine.

use std::fs;
use std::path::{Path, PathBuf};

use anyhow::{bail, Context, Result};
use serde_json::{json, Value};

use crate::managers::util::{self, expand_home};
use crate::Notify;

const DART_BASE: &str = "https://storage.googleapis.com/dart-archive/channels/stable/release";

/// Latest stable Dart SDK version line.
pub fn latest() -> Result<Value> {
    let bytes = util::http_get(&format!("{DART_BASE}/latest/VERSION"))?;
    let v: Value = serde_json::from_slice(&bytes).context("invalid dart VERSION json")?;
    let version = v
        .get("version")
        .and_then(|x| x.as_str())
        .context("dart VERSION missing 'version'")?
        .to_string();
    Ok(json!({ "version": version, "date": v.get("date") }))
}

fn archive_name() -> String {
    format!("dartsdk-{}-{}-release.zip", util::os(), util::arch())
}

/// `dart.install` - download and extract a standalone Dart SDK.
pub fn install(
    version: Option<&str>,
    parent_dir: Option<&str>,
    add_to_path: bool,
    replace: bool,
    notify: &Notify,
) -> Result<Value> {
    let resolved = match version {
        Some(v) => v.to_string(),
        None => latest()?.get("version").and_then(|x| x.as_str()).unwrap_or("").to_string(),
    };
    if !util::looks_like_version(&resolved) {
        bail!("could not resolve a Dart SDK version");
    }

    let url = format!("{DART_BASE}/{resolved}/sdk/{}", archive_name());
    let tmp = std::env::temp_dir().join(format!("flutter_installer_{}.zip", archive_name()));

    notify(json!({ "jsonrpc": "2.0", "method": "task.started", "params": {
        "task": "install", "id": "dart", "version": resolved
    }}));

    util::download(&url, &tmp, notify)?;

    let parent = parent_dir
        .map(expand_home)
        .unwrap_or_else(|| dirs::home_dir().unwrap_or_else(|| PathBuf::from(".")).join("development"));
    fs::create_dir_all(&parent)?;

    // Extract into a staging dir, then move the inner `dart-sdk` folder out.
    let stage = std::env::temp_dir().join(format!("flutter_installer_dart_stage_{resolved}"));
    if stage.exists() {
        fs::remove_dir_all(&stage)?;
    }
    fs::create_dir_all(&stage)?;
    util::extract_archive(&tmp, &stage, notify)?;

    let inner = find_dart_sdk(&stage)?;
    let target = parent.join("dart-sdk");
    if target.exists() {
        if !replace {
            fs::remove_dir_all(&stage).ok();
            bail!("{} already exists; pass 'replace: true' to overwrite", target.display());
        }
        fs::remove_dir_all(&target)?;
    }
    fs::rename(&inner, &target).with_context(|| "failed to finalize dart-sdk directory")?;
    fs::remove_dir_all(&stage).ok();
    fs::remove_file(&tmp).ok();

    let mut result = json!({
        "path": target.to_string_lossy().to_string(),
        "version": resolved,
        "addToPath": add_to_path,
    });
    if add_to_path {
        let bin = target.join("bin");
        match crate::managers::path::ensure(bin.to_string_lossy().as_ref(), None, notify) {
            Ok(v) => result["pathResult"] = v,
            Err(e) => result["pathWarning"] = json!(format!("{e:#}")),
        }
    }

    notify(json!({ "jsonrpc": "2.0", "method": "task.completed", "params": {
        "task": "install", "id": "dart", "version": resolved
    }}));
    Ok(result)
}

fn find_dart_sdk(stage: &Path) -> Result<PathBuf> {
    for entry in fs::read_dir(stage)? {
        let entry = entry?;
        if entry.path().join("bin").join("dart").exists()
            || entry.path().join("bin").join("dart.exe").exists()
        {
            return Ok(entry.path());
        }
    }
    // Some archives land the dart-sdk as the only child.
    if let Ok(one) = fs::read_dir(stage) {
        let first = one.flatten().next();
        if let Some(f) = first {
            if f.path().is_dir() {
                return Ok(f.path());
            }
        }
    }
    bail!("extraction did not produce a dart-sdk directory")
}

/// `dart.list` - find installed standalone Dart SDKs.
pub fn list() -> Value {
    let mut roots: Vec<PathBuf> = Vec::new();
    if let Some(home) = dirs::home_dir() {
        for c in ["development/dart-sdk", "dart-sdk", "dev/dart"] {
            roots.push(home.join(c));
        }
    }
    roots.push(PathBuf::from("/opt/dart-sdk"));
    if let Ok(paths) = std::env::var("PATH") {
        for d in std::env::split_paths(&paths) {
            if d.file_name().map(|f| f == "bin").unwrap_or(false) {
                if d.join("dart").is_file() || d.join("dart.exe").is_file() {
                    if let Some(root) = d.parent() {
                        roots.push(root.to_path_buf());
                    }
                }
            }
        }
    }

    let mut seen = std::collections::HashSet::new();
    let sdks: Vec<Value> = roots
        .into_iter()
        .filter(|p| p.join("bin").join("dart").exists() || p.join("bin").join("dart.exe").exists())
        .filter(|p| seen.insert(p.clone()))
        .map(|root| {
            let version = read_dart_version(&root);
            json!({
                "path": root.to_string_lossy().to_string(),
                "version": version,
                "onPath": on_path(&root),
            })
        })
        .collect();
    json!({ "sdks": sdks })
}

fn read_dart_version(root: &Path) -> Option<String> {
    fs::read_to_string(root.join("version"))
        .ok()
        .map(|s| s.trim().to_string())
        .filter(|s| util::looks_like_version(s))
        .or_else(|| {
            let exe = root.join("bin").join("dart");
            #[cfg(target_os = "windows")]
            let exe = root.join("bin").join("dart.exe");
            let out = std::process::Command::new(exe).arg("--version").output().ok()?;
            let text = String::from_utf8_lossy(&out.stderr).into_owned();
            let text = if text.trim().is_empty() {
                String::from_utf8_lossy(&out.stdout).into_owned()
            } else {
                text
            };
            // "Dart SDK version: 3.13.4 (stable) ..." -> "3.13.4"
            let parsed = text.split_once("version:")
                .map(|(_, rest)| rest.trim_start().split_whitespace().next().unwrap_or("").to_string())
                .filter(|v| util::looks_like_version(v));
            match parsed {
                Some(v) => Some(v),
                None => {
                    let t = text.trim().to_string();
                    if t.is_empty() { None } else { Some(t) }
                }
            }
        })
}

fn on_path(root: &Path) -> bool {
    let bin = root.join("bin").to_string_lossy().to_string();
    std::env::var("PATH")
        .map(|p| std::env::split_paths(&p).any(|d| d.to_string_lossy().eq(&bin)))
        .unwrap_or(false)
}

/// `dart.uninstall` - delete an SDK directory.
pub fn uninstall(dart_root: &str) -> Result<Value> {
    let root = expand_home(dart_root);
    let marker = if cfg!(windows) { root.join("bin").join("dart.exe") } else { root.join("bin").join("dart") };
    if !marker.exists() {
        bail!("{} does not look like a Dart SDK", root.display());
    }
    fs::remove_dir_all(&root).with_context(|| format!("cannot remove {}", root.display()))?;
    Ok(json!({ "path": root.to_string_lossy().to_string(), "removed": true }))
}