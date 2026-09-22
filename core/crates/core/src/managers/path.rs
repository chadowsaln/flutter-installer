//! PATH Manager: read/modify the PATH and install `export PATH=...` lines
//! into the user's shell profile on POSIX (best-effort on Windows via setx).

use std::fs;
use std::path::PathBuf;

use anyhow::{bail, Context, Result};
use serde_json::{json, Value};

use crate::managers::util::expand_home;

/// POSIX shell profiles a Flutter/Dart install may be added to.
fn profile_candidates() -> Vec<PathBuf> {
    let home = dirs::home_dir().unwrap_or_else(|| PathBuf::from("."));
    let mut v = vec![home.join(".zshrc"), home.join(".bashrc"), home.join(".profile")];
    if cfg!(target_os = "macos") {
        v.push(home.join(".bash_profile"));
    }
    // De-duplicate while preserving order.
    let mut seen = std::collections::HashSet::new();
    v.into_iter().filter(|p| seen.insert(p.clone())).collect()
}

fn default_profile() -> PathBuf {
    profile_candidates()
        .into_iter()
        .find(|p| p.exists())
        .unwrap_or_else(|| dirs::home_dir().map(|h| h.join(".bashrc")).unwrap_or_else(|| PathBuf::from(".bashrc")))
}

/// `path.get` - current PATH entries.
pub fn get() -> Value {
    let entries: Vec<String> = std::env::var("PATH")
        .map(|p| {
            std::env::split_paths(&p)
                .map(|d| d.to_string_lossy().to_string())
                .collect()
        })
        .unwrap_or_default();
    json!({ "entries": entries })
}

/// `path.profiles` - shell profiles that PATH lines can be merged into.
pub fn profiles() -> Value {
    let list: Vec<Value> = profile_candidates()
        .into_iter()
        .map(|p| json!({ "path": p.to_string_lossy().to_string(), "exists": p.exists() }))
        .collect();
    json!({ "profiles": list })
}

/// `path.ensure` - make `bin_dir` available in the given (or default) profile.
pub fn ensure(bin_dir: &str, profile: Option<&str>, notify: &crate::Notify) -> Result<Value> {
    let abs = expand_home(bin_dir);

    if cfg!(target_os = "windows") {
        // Best-effort Windows integration via the user environment variables.
        let status = std::process::Command::new("setx")
            .args(["PATH", &format!("%PATH%;{}", abs.to_string_lossy())])
            .status()
            .context("setx not available")?;
        if !status.success() {
            bail!("setx failed to update the user PATH");
        }
        return Ok(json!({ "platform": "windows", "path": abs.to_string_lossy(), "added": true }));
    }

    if !abs.is_absolute() {
        bail!("expected an absolute bin directory, got: {}", abs.display());
    }

    let file = profile
        .map(expand_home)
        .unwrap_or_else(default_profile);
    let content = fs::read_to_string(&file).unwrap_or_default();
    let line = format!("export PATH=\"{}$PATH\"", abs.to_string_lossy());
    let marker = format!("# flutter-installer: {}", abs.to_string_lossy());

    if content.contains(&abs.to_string_lossy().to_string()) {
        return Ok(json!({
            "profile": file.to_string_lossy().to_string(),
            "path": abs.to_string_lossy().to_string(),
            "line": line,
            "added": false,
        }));
    }

    let mut next = content.trim_end().to_string();
    if !next.is_empty() {
        next.push('\n');
    }
    next.push_str(&format!("\n{marker}\n{line}\n"));
    fs::write(&file, next).with_context(|| format!("cannot write {}", file.display()))?;
    let _ = notify;

    Ok(json!({
        "profile": file.to_string_lossy().to_string(),
        "path": abs.to_string_lossy().to_string(),
        "line": line,
        "added": true,
    }))
}

/// `path.remove` - remove PATH export lines referencing `bin_dir` from all profiles.
pub fn remove(bin_dir: &str) -> Result<Value> {
    let abs = expand_home(bin_dir).to_string_lossy().to_string();
    let mut removed: Vec<Value> = Vec::new();
    for profile in profile_candidates() {
        if !profile.exists() {
            continue;
        }
        let content = fs::read_to_string(&profile)?;
        let kept: Vec<&str> = content
            .lines()
            .filter(|l| !l.contains(&abs))
            .collect();
        if kept.len() != content.lines().count() {
            let next = format!("{}\n", kept.join("\n")).replace("\n\n\n", "\n\n");
            fs::write(&profile, next)?;
            removed.push(json!({ "profile": profile.to_string_lossy().to_string() }));
        }
    }
    Ok(json!({ "path": abs, "removed": removed }))
}