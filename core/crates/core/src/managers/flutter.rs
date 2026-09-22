//! Flutter Manager: resolve releases from Flutter's official release feed,
//! install the SDK, list installed SDKs and uninstall them.

use std::fs;
use std::path::{Path, PathBuf};

use anyhow::{bail, Context, Result};
use serde_json::{json, Value};

use crate::managers::util::{self, expand_home};
use crate::Notify;

const RELEASES_URL: &str = "https://storage.googleapis.com/flutter_infra_release/releases";

/// Parsed Flutter release info.
#[derive(Debug, Clone)]
pub struct Release {
    pub version: String,
    pub channel: String,
    pub hash: String,
    pub archive: String,
    pub dart_version: Option<String>,
}

fn fetch_feed() -> Result<Value> {
    let url = format!("{RELEASES_URL}/releases_{}.json", util::os());
    let bytes = util::http_get(&url)?;
    serde_json::from_slice(&bytes).context("invalid release feed JSON")
}

/// Resolves a release. Prefers an explicit version, otherwise the latest on
/// the requested channel.
pub fn resolve(version: Option<&str>, channel: &str) -> Result<Release> {
    let feed = fetch_feed()?;
    let releases = feed
        .get("releases")
        .and_then(|r| r.as_array())
        .context("release feed has no releases array")?;

    let mut pick: Option<&Value> = None;
    if let Some(version) = version {
        for r in releases {
            if r.get("version").and_then(|v| v.as_str()) == Some(version) {
                pick = Some(r);
                break;
            }
        }
        if pick.is_none() {
            bail!("Flutter version {version} was not found in the release feed");
        }
    } else if channel == "master" {
        for r in releases {
            if r.get("channel").and_then(|c| c.as_str()) == Some("master") {
                pick = Some(r);
                break;
            }
        }
    } else {
        let hash = feed
            .get("current_release")
            .and_then(|c| c.get(channel))
            .and_then(|h| h.as_str())
            .with_context(|| format!("channel '{channel}' has no current release"))?;
        for r in releases {
            if r.get("hash").and_then(|h| h.as_str()) == Some(hash) {
                pick = Some(r);
                break;
            }
        }
    }

    let r = pick.context("no matching release found")?.clone();
    Ok(Release {
        version: r
            .get("version")
            .and_then(|v| v.as_str())
            .unwrap_or("unknown")
            .to_string(),
        channel: r
            .get("channel")
            .and_then(|v| v.as_str())
            .unwrap_or(channel)
            .to_string(),
        hash: r.get("hash").and_then(|v| v.as_str()).unwrap_or("").to_string(),
        archive: r.get("archive").and_then(|v| v.as_str()).unwrap_or("").to_string(),
        dart_version: r.get("dart_sdk_version").and_then(|v| v.as_str()).map(|s| s.to_string()),
    })
}

fn release_to_value(r: &Release) -> Value {
    json!({
        "version": r.version,
        "channel": r.channel,
        "hash": r.hash,
        "archive": r.archive,
        "dartVersion": r.dart_version,
    })
}

/// `flutter.latest` - the newest release on a channel (plus download size).
pub fn latest(channel: &str) -> Result<Value> {
    let r = resolve(None, channel)?;
    let url = format!("{RELEASES_URL}/{}", r.archive);
    let size = util::http_head(&url).ok().and_then(|s| s.map(|(n, _)| n as u64));
    let mut v = release_to_value(&r);
    v["url"] = json!(url);
    v["size"] = json!(size);
    Ok(v)
}

/// `flutter.install` - download + extract + PATH-export a Flutter SDK.
#[allow(clippy::too_many_arguments)]
pub fn install(
    version: Option<&str>,
    channel: &str,
    parent_dir: Option<&str>,
    add_to_path: bool,
    replace: bool,
    notify: &Notify,
) -> Result<Value> {
    let release = resolve(version, channel)?;

    let parent = parent_dir
        .map(expand_home)
        .unwrap_or_else(|| dirs::home_dir().unwrap_or_else(|| PathBuf::from(".")).join("development"));

    let url = format!("{RELEASES_URL}/{}", release.archive);
    let archive_name = release
        .archive
        .rsplit('/')
        .next()
        .unwrap_or("flutter-archive")
        .to_string();
    let tmp = std::env::temp_dir().join(format!("flutter_installer_{archive_name}"));

    notify(json!({ "jsonrpc": "2.0", "method": "task.started", "params": {
        "task": "install", "id": "flutter", "version": release.version
    }}));

    util::download(&url, &tmp, notify)?;

    let flutter_root = parent.join("flutter");
    if flutter_root.exists() {
        if !replace {
            bail!("{} already exists; pass 'replace: true' to overwrite", flutter_root.display());
        }
        fs::remove_dir_all(&flutter_root)
            .with_context(|| format!("cannot remove {}", flutter_root.display()))?;
    }
    fs::create_dir_all(&parent)?;

    notify(json!({ "jsonrpc": "2.0", "method": "log", "params": {
        "level": "info", "message": format!("Extracting {} ...", flutter_root.display())
    }}));
    util::extract_archive(&tmp, &parent, notify)?;
    fs::remove_file(&tmp).ok();

    let bin = flutter_root.join("bin").join("flutter");
    #[cfg(target_os = "windows")]
    let bin = flutter_root.join("bin").join("flutter.bat");
    if !bin.exists() {
        bail!("extraction did not produce {}", bin.display());
    }

    let mut result = json!({
        "path": flutter_root.to_string_lossy().to_string(),
        "version": release.version,
        "channel": release.channel,
        "dartVersion": release.dart_version,
        "addToPath": add_to_path,
    });

    if add_to_path {
        let bin_dir = flutter_root.join("bin");
        match crate::managers::path::ensure(bin_dir.to_string_lossy().as_ref(), None, notify) {
            Ok(v) => {
                result["pathResult"] = v;
            }
            Err(e) => {
                result["pathWarning"] = json!(format!("{e:#}"));
            }
        }
    }

    notify(json!({ "jsonrpc": "2.0", "method": "task.completed", "params": {
        "task": "install", "id": "flutter", "version": release.version
    }}));
    Ok(result)
}

/// `flutter.list` - find installed Flutter SDKs and read their versions.
pub fn list() -> Value {
    let mut roots: Vec<PathBuf> = Vec::new();
    if let Some(home) = dirs::home_dir() {
        for c in ["development/flutter", "flutter"] {
            roots.push(home.join(c));
        }
    }
    roots.push(PathBuf::from("/opt/flutter"));
    if let Ok(paths) = std::env::var("PATH") {
        for d in std::env::split_paths(&paths) {
            // A PATH entry of `<root>/flutter/bin` implies an installed root.
            if d.file_name().map(|f| f == "bin").unwrap_or(false) {
                if d.join("flutter").is_file() || d.join("flutter.bat").is_file() {
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
        .filter(|p| p.join("bin").join("flutter").exists() || p.join("bin").join("flutter.bat").exists())
        .filter(|p| seen.insert(p.clone()))
        .map(|root| {
            let (version, channel, dart) = read_sdk_version(&root);
            json!({
                "path": root.to_string_lossy().to_string(),
                "version": version,
                "channel": channel,
                "dartVersion": dart,
                "onPath": on_path(&root),
            })
        })
        .collect();
    json!({ "sdks": sdks })
}

/// Reads version/channel/dart from a Flutter SDK root, cheaply.
fn read_sdk_version(root: &Path) -> (Option<String>, Option<String>, Option<String>) {
    let cache = root.join("bin/cache/flutter.version.json");
    if let Ok(text) = fs::read_to_string(&cache) {
        if let Ok(v) = serde_json::from_str::<Value>(&text) {
            return (
                v.get("frameworkVersion").and_then(|x| x.as_str()).map(|s| s.to_string()),
                v.get("channel").and_then(|x| x.as_str()).map(|s| s.to_string()),
                v.get("dartSdkVersion").and_then(|x| x.as_str()).map(|s| s.to_string()),
            );
        }
    }
    let repo_version = fs::read_to_string(root.join("version"))
        .ok()
        .map(|s| s.trim().to_string())
        .filter(|s| util::looks_like_version(s));
    (repo_version, None, None)
}

fn on_path(root: &Path) -> bool {
    let bin = root.join("bin").to_string_lossy().to_string();
    std::env::var("PATH")
        .map(|p| std::env::split_paths(&p).any(|d| d.to_string_lossy().eq(&bin)))
        .unwrap_or(false)
}

/// `flutter.uninstall` - delete an SDK directory.
pub fn uninstall(flutter_root: &str) -> Result<Value> {
    let root = expand_home(flutter_root);
    let marker = root.join("bin").join("flutter");
    if !marker.exists() {
        bail!("{} does not look like a Flutter SDK", root.display());
    }
    fs::remove_dir_all(&root).with_context(|| format!("cannot remove {}", root.display()))?;
    Ok(json!({ "path": root.to_string_lossy().to_string(), "removed": true }))
}