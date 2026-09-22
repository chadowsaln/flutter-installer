//! System Checker manager: OS/arch detection, environment info and
//! prerequisite checks for installing the Flutter/Dart SDKs.

use std::path::PathBuf;

use anyhow::Result;
use serde_json::{json, Value};

use crate::managers::util;
use crate::Notify;

pub fn os() -> &'static str {
    util::os()
}

pub fn arch() -> &'static str {
    util::arch()
}

fn hostname() -> String {
    #[cfg(target_os = "linux")]
    {
        std::fs::read_to_string("/proc/sys/kernel/hostname")
            .map(|s| s.trim().to_string())
            .unwrap_or_else(|_| "unknown".into())
    }
    #[cfg(target_os = "macos")]
    {
        std::process::Command::new("scutil")
            .arg("--get")
            .arg("ComputerName")
            .output()
            .ok()
            .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string())
            .filter(|s| !s.is_empty())
            .unwrap_or_else(|| "unknown".into())
    }
    #[cfg(target_os = "windows")]
    {
        std::env::var("COMPUTERNAME").unwrap_or_else(|_| "unknown".into())
    }
    #[cfg(not(any(target_os = "linux", target_os = "macos", target_os = "windows")))]
    {
        "unknown".into()
    }
}

fn tool_on_path(name: &str) -> Option<String> {
    let exe = if cfg!(windows) { format!("{name}.exe") } else { name.to_string() };
    std::env::var_os("PATH").and_then(|p| {
        std::env::split_paths(&p)
            .map(|d| d.join(&exe))
            .find(|f| f.is_file())
            .map(|f| f.to_string_lossy().to_string())
    })
    .or_else(|| util::which(name).map(|p| p.to_string_lossy().to_string()))
}

/// `system.info` - environment summary describing the host.
pub fn info() -> Value {
    let home = dirs::home_dir().unwrap_or_else(|| PathBuf::from("."));
    json!({
        "os": os(),
        "arch": arch(),
        "hostname": hostname(),
        "user": std::env::var("USER").or_else(|_| std::env::var("USERNAME")).unwrap_or_else(|_| "unknown".into()),
        "home": home.to_string_lossy().to_string(),
        "shell": std::env::var("SHELL").unwrap_or_else(|_| "unknown".into()),
        "flutterOnPath": tool_on_path("flutter"),
        "dartOnPath": tool_on_path("dart"),
        "profiles": crate::managers::path::profiles(),
    })
}

/// `system.check` - evaluates prerequisites for installing Flutter/Dart.
pub fn check(notify: &Notify) -> Result<Value> {
    let mut checks: Vec<Value> = Vec::new();

    let mut add = |id: &'static str, name: &'static str, ok: bool, detail: String, fix: String| {
        checks.push(json!({
            "id": id, "name": name, "ok": ok, "detail": detail, "fix": fix,
        }));
    };

    add(
        "arch",
        "CPU architecture supported",
        arch() != "unknown",
        format!("Detected architecture: {}", arch()),
        "Flutter supports x86_64 and arm64 hosts.".into(),
    );

    for (id, name, cmd) in [
        ("curl", "curl", "curl"),
        ("tar", "tar", "tar"),
        ("unzip", "unzip", "unzip"),
        ("git", "git", "git"),
    ] {
        let found = util::which(cmd).is_some();
        add(
            id,
            name,
            found,
            if found {
                format!("{cmd}: found on PATH")
            } else {
                format!("{cmd}: not found")
            },
            format!("Install {cmd} using your package manager (e.g. `sudo dnf install {cmd}`)."),
        );
    }

    let xz = util::which("xz").is_some() && {
        // Windows ships tar which understands xz; POSIX needs the xz binary.
        if cfg!(windows) { true } else { util::which("xz").is_some() }
    };
    add(
        "xz",
        "xz compression",
        xz,
        if xz { "xz: found on PATH".into() } else { "xz: not found".into() },
        "Install xz (`sudo dnf install xz`).".into(),
    );

    if cfg!(target_os = "linux") {
        let libs = util::which("pkg-config").is_some()
            && std::process::Command::new("pkg-config")
                .args(["--exists", "gtk+-3.0"])
                .status()
                .map(|s| s.success())
                .unwrap_or(false);
        add(
            "gtk",
            "GTK3 development libraries",
            libs,
            if libs { "gtk+-3.0: available".into() } else { "gtk+-3.0: missing".into() },
            "See the Linux desktop setup guide: install libgtk-3-dev.".into(),
        );
        for (id, name, cmd) in [
            ("clang", "clang", "clang"),
            ("cmake", "cmake", "cmake"),
            ("ninja", "ninja", "ninja"),
        ] {
            let ok = util::which(cmd).is_some();
            add(
                id,
                name,
                ok,
                if ok { format!("{cmd}: found on PATH") } else { format!("{cmd}: not found") },
                format!("Install {cmd} (`sudo dnf install {cmd}`)."),
            );
        }
    }

    if cfg!(target_os = "macos") {
        let xcode = std::process::Command::new("xcode-select")
            .args(["--print-path"])
            .output()
            .map(|o| o.status.success())
            .unwrap_or(false);
        add(
            "xcode",
            "Xcode command line tools",
            xcode,
            if xcode { "xcode-select: configured".into() } else { "xcode-select: not found".into() },
            "Run `xcode-select --install`.".into(),
        );
    }

    // Network reachability to Google's storage (needed for downloads).
    let net_url = format!("{}/releases/releases_{}.json", util::RELEASE_BASE, os());
    let net_ok = util::http_head(&net_url).is_ok();
    add(
        "network",
        "Network access to flutter storage",
        net_ok,
        if net_ok { format!("reachable: {net_url}") } else { format!("unreachable: {net_url}") },
        "Check your internet connection and proxy settings.".into(),
    );

    notify(json!({
        "jsonrpc": "2.0",
        "method": "log",
        "params": { "level": "info", "message": "System check complete" }
    }));

    Ok(json!({ "os": os(), "arch": arch(), "checks": checks }))
}