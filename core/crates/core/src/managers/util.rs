//! Shared utilities used by all managers: OS/arch detection, HTTP download
//! with progress notification, archive extraction and command lookup.

use std::fs::File;
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::time::Duration;

use anyhow::{bail, Context, Result};
use serde_json::json;

use crate::Notify;

pub const RELEASE_BASE: &str = "https://storage.googleapis.com/flutter_infra_release";

/// Normalized OS name used by Flutter's release archives.
pub fn os() -> &'static str {
    #[cfg(target_os = "linux")]
    {
        "linux"
    }
    #[cfg(target_os = "macos")]
    {
        "macos"
    }
    #[cfg(target_os = "windows")]
    {
        "windows"
    }
    #[cfg(not(any(target_os = "linux", target_os = "macos", target_os = "windows")))]
    {
        "unknown"
    }
}

/// Normalized CPU architecture used by Flutter's release archives.
pub fn arch() -> &'static str {
    #[cfg(target_arch = "x86_64")]
    {
        "x64"
    }
    #[cfg(target_arch = "aarch64")]
    {
        "arm64"
    }
    #[cfg(target_arch = "x86")]
    {
        "ia32"
    }
    #[cfg(not(any(target_arch = "x86_64", target_arch = "aarch64", target_arch = "x86")))]
    {
        "unknown"
    }
}

/// Locates a command on PATH using `which` / `where`.
pub fn which(name: &str) -> Option<PathBuf> {
    let cmd = if cfg!(windows) { "where" } else { "which" };
    let out = std::process::Command::new(cmd).arg(name).output().ok()?;
    if !out.status.success() {
        return None;
    }
    let first = String::from_utf8_lossy(&out.stdout).lines().next()?.trim().to_string();
    if first.is_empty() {
        None
    } else {
        Some(PathBuf::from(first))
    }
}

/// A shared HTTP agent with sane timeouts.
fn agent() -> ureq::Agent {
    ureq::AgentBuilder::new()
        .timeout_connect(Duration::from_secs(15))
        .timeout_read(Duration::from_secs(30))
        .build()
}

/// A lightweight agent for small metadata requests (release feeds, HEADs):
/// fails fast instead of keeping the UI spinner waiting.
fn meta_agent() -> ureq::Agent {
    ureq::AgentBuilder::new()
        .timeout_connect(Duration::from_secs(8))
        .timeout_read(Duration::from_secs(12))
        .build()
}

/// GET a URL into memory.
pub fn http_get(url: &str) -> Result<Vec<u8>> {
    let agent = meta_agent();
    let resp = agent
        .get(url)
        .call()
        .with_context(|| format!("GET {url} failed"))?;
    let mut buf = Vec::new();
    resp.into_reader().read_to_end(&mut buf)?;
    Ok(buf)
}

/// HEAD a URL, returning `(size_bytes, final_url)`.
pub fn http_head(url: &str) -> Result<Option<(u64, String)>> {
    let resp = meta_agent().head(url).call()?;
    let final_url = resp.get_url().to_string();
    let size = resp
        .header("Content-Length")
        .and_then(|v| v.parse::<u64>().ok());
    Ok(size.map(|s| (s, final_url)))
}

/// Downloads `url` to `dest`, emitting throttled `progress` notifications.
pub fn download(url: &str, dest: &Path, notify: &Notify) -> Result<u64> {
    let resp = agent().get(url).call().with_context(|| format!("GET {url} failed"))?;
    let total: Option<u64> = resp.header("Content-Length").and_then(|v| v.parse().ok());
    let mut reader = resp.into_reader();
    let mut file = File::create(dest).with_context(|| format!("cannot create {}", dest.display()))?;
    let mut buf = vec![0u8; 128 * 1024];
    let mut done: u64 = 0;
    let mut last_pct: i32 = -1;
    loop {
        let n = reader.read(&mut buf)?;
        if n == 0 {
            break;
        }
        file.write_all(&buf[..n])?;
        done += n as u64;
        if let Some(total) = total {
            let pct = (done as f64 / total as f64 * 100.0).min(100.0) as i32;
            // Emit at most ~1 notification per 2% (or none if total unknown).
            if pct - last_pct >= 2 || (pct >= 100 && last_pct < 100) {
                last_pct = pct;
                notify(json!({
                    "jsonrpc": "2.0",
                    "method": "progress",
                    "params": { "task": "download", "url": url, "done": done, "total": total, "percent": pct as f64 }
                }));
            }
        }
    }
    file.flush()?;
    Ok(done)
}

/// Extracts an archive by extension using the platform archive tool.
pub fn extract_archive(archive: &Path, dest: &Path, notify: &Notify) -> Result<()> {
    let name = archive
        .file_name()
        .map(|n| n.to_string_lossy().to_string())
        .unwrap_or_default();
    if name.ends_with(".zip") {
        run(
            "unzip",
            &["-q", "-o", &archive.to_string_lossy(), "-d", &dest.to_string_lossy()],
            None,
            notify,
            true,
        )?;
    } else if name.ends_with(".tar.xz") {
        run(
            "tar",
            &["-xJf", &archive.to_string_lossy(), "-C", &dest.to_string_lossy()],
            None,
            notify,
            true,
        )?;
    } else {
        bail!("unsupported archive type: {name}");
    }
    Ok(())
}

/// Runs a command, streaming output through `log` notifications, and waits
/// for completion. Returns Ok(exit_status.success()).
pub fn run(
    cmd: &str,
    args: &[&str],
    cwd: Option<&Path>,
    notify: &Notify,
    stream: bool,
) -> Result<bool> {
    let mut command = std::process::Command::new(cmd);
    command.args(args);
    if let Some(cwd) = cwd {
        command.current_dir(cwd);
    }
    if stream {
        command.stdout(std::process::Stdio::piped()).stderr(std::process::Stdio::piped());
    }
    let mut child = command.spawn().with_context(|| format!("failed to run {cmd}"))?;

    if stream {
        if let Some(mut out) = child.stdout.take() {
            let n = notify.clone();
            let tag = cmd.to_string();
            std::thread::spawn(move || stream_cmd(&mut out, n, &tag, "info"));
        }
        if let Some(mut err) = child.stderr.take() {
            let n = notify.clone();
            let tag = cmd.to_string();
            std::thread::spawn(move || stream_cmd(&mut err, n, &tag, "warn"));
        }
    }

    let status = child.wait()?;
    Ok(status.success())
}

fn stream_cmd<R: Read>(r: &mut R, notify: Notify, cmdtag: &str, level: &'static str) {
    let mut buf = vec![0u8; 4096];
    loop {
        match r.read(&mut buf) {
            Ok(0) | Err(_) => break,
            Ok(n) => {
                let text = String::from_utf8_lossy(&buf[..n]).trim_end().to_string();
                if !text.is_empty() {
                    notify(json!({
                        "jsonrpc": "2.0",
                        "method": "log",
                        "params": { "level": level, "message": format!("[{cmdtag}] {text}") }
                    }));
                }
            }
        }
    }
}

/// Expands `~` to the home directory.
pub fn expand_home(path: &str) -> PathBuf {
    if path == "~" {
        return dirs::home_dir().unwrap_or_else(|| PathBuf::from("."));
    }
    if let Some(rest) = path.strip_prefix("~/") {
        if let Some(home) = dirs::home_dir() {
            return home.join(rest);
        }
    }
    PathBuf::from(path)
}

/// Verifies a version string looks sane (things like `3.47.5` or `3.48.0-0.5.pre`).
pub fn looks_like_version(s: &str) -> bool {
    let t = s.trim();
    !t.is_empty() && t.chars().next().map(|c| c.is_ascii_digit()).unwrap_or(false)
}