//! Process Manager: spawn processes with streamed output, monitor a registry
//! of running processes, and terminate them (including process trees).

use std::collections::HashMap;
use std::io::BufRead;
use std::process::{Child, Command, Stdio};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use anyhow::{Context, Result};
use serde_json::{json, Value};

use crate::Notify;

struct Entry {
    exe: String,
    slot: Arc<Mutex<Option<Child>>>,
}

/// Registry of spawned processes, shared across the application.
pub struct ProcessManager {
    procs: Arc<Mutex<HashMap<u32, Entry>>>,
}

impl ProcessManager {
    pub fn new() -> Self {
        Self {
            procs: Arc::new(Mutex::new(HashMap::new())),
        }
    }

    /// `process.spawn` - start a process, capturing stdout/stderr as events.
    pub fn spawn(&self, cmd: &str, args: &[String], cwd: Option<String>, env: Value, notify: &Notify) -> Result<Value> {
        let mut command = Command::new(cmd);
        command.args(args);
        if let Some(cwd) = &cwd {
            command.current_dir(cwd);
        }
        if let Some(env) = env.as_object() {
            for (k, v) in env {
                if let Some(v) = v.as_str() {
                    command.env(k, v);
                }
            }
        }
        command
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .stdin(Stdio::inherit());

        let child = command.spawn().with_context(|| format!("failed to spawn {cmd}"))?;
        let pid = child.id();
        let slot = Arc::new(Mutex::new(Some(child)));
        self.procs.lock().unwrap().insert(
            pid,
            Entry {
                exe: cmd.to_string(),
                slot: slot.clone(),
            },
        );

        // Stream stdout / stderr lines as notifications.
        let stdout = slot.lock().unwrap().as_mut().unwrap().stdout.take();
        let stderr = slot.lock().unwrap().as_mut().unwrap().stderr.take();
        if let Some(out) = stdout {
            let n = notify.clone();
            std::thread::spawn(move || stream_lines(out, &n, pid, "process.stdout"));
        }
        if let Some(err) = stderr {
            let n = notify.clone();
            std::thread::spawn(move || stream_lines(err, &n, pid, "process.stderr"));
        }

        // Reap the process and notify exit.
        let map = self.procs.clone();
        let n = notify.clone();
        std::thread::spawn(move || {
            let mut guard = slot.lock().unwrap();
            let mut child = guard.take();
            drop(guard);
            let code = match child {
                Some(ref mut c) => c.wait().ok().and_then(|s| s.code()),
                None => None,
            };
            map.lock().unwrap().remove(&pid);
            n(json!({
                "jsonrpc": "2.0",
                "method": "process.exit",
                "params": { "pid": pid, "code": code }
            }));
        });

        Ok(json!({ "pid": pid, "cmd": cmd, "cwd": cwd }))
    }

    /// `process.list` - running processes managed by this daemon.
    pub fn list(&self) -> Value {
        let map = self.procs.lock().unwrap();
        let procs: Vec<Value> = map
            .iter()
            .map(|(pid, e)| json!({ "pid": pid, "exe": e.exe }))
            .collect();
        json!({ "processes": procs })
    }

    /// `process.terminate` - kill a managed process (and its tree on Windows).
    pub fn terminate(&self, pid: u32) -> Result<Value> {
        let entry = self
            .procs
            .lock()
            .unwrap()
            .remove(&pid)
            .with_context(|| format!("no such managed process: {pid}"))?;
        let mut guard = entry.slot.lock().unwrap();
        if let Some(child) = guard.as_mut() {
            kill(child);
        }
        Ok(json!({ "pid": pid, "terminated": true }))
    }

    /// `process.exec` - run a command to completion, returning captured output.
    pub fn exec(&self, cmd: &str, args: &[String], cwd: Option<String>, env: Value, timeout_ms: Option<u64>) -> Result<Value> {
        let mut command = Command::new(cmd);
        command.args(args);
        if let Some(cwd) = &cwd {
            command.current_dir(cwd);
        }
        if let Some(env) = env.as_object() {
            for (k, v) in env {
                if let Some(v) = v.as_str() {
                    command.env(k, v);
                }
            }
        }
        command.stdout(Stdio::piped()).stderr(Stdio::piped()).stdin(Stdio::null());

        let mut child = command.spawn().with_context(|| format!("failed to spawn {cmd}"))?;
        let stdout = child.stdout.take().unwrap();
        let stderr = child.stderr.take().unwrap();

        let out = Arc::new(Mutex::new(Vec::<u8>::new()));
        let err = Arc::new(Mutex::new(Vec::<u8>::new()));
        {
            let out = out.clone();
            std::thread::spawn(move || {
                let mut r = std::io::BufReader::new(stdout);
                let mut buf = Vec::new();
                let _ = std::io::Read::read_to_end(&mut r, &mut buf);
                *out.lock().unwrap() = buf;
            });
        }
        {
            let err = err.clone();
            std::thread::spawn(move || {
                let mut r = std::io::BufReader::new(stderr);
                let mut buf = Vec::new();
                let _ = std::io::Read::read_to_end(&mut r, &mut buf);
                *err.lock().unwrap() = buf;
            });
        }

        let timeout = timeout_ms.map(Duration::from_millis).unwrap_or(Duration::MAX);
        let started = Instant::now();
        loop {
            match child.try_wait()? {
                Some(status) => {
                    let stdout = String::from_utf8_lossy(&out.lock().unwrap().clone()).into_owned();
                    let stderr = String::from_utf8_lossy(&err.lock().unwrap().clone()).into_owned();
                    return Ok(json!({
                        "code": status.code(),
                        "success": status.success(),
                        "stdout": stdout,
                        "stderr": stderr,
                    }));
                }
                None => {
                    if started.elapsed() > timeout {
                        kill(&mut child);
                        return Ok(json!({
                            "code": null,
                            "success": false,
                            "timedOut": true,
                            "timeoutMs": timeout_ms,
                            "stdout": String::from_utf8_lossy(&out.lock().unwrap().clone()).into_owned(),
                            "stderr": String::from_utf8_lossy(&err.lock().unwrap().clone()).into_owned(),
                        }));
                    }
                    std::thread::sleep(Duration::from_millis(30));
                }
            }
        }
    }
}

impl Default for ProcessManager {
    fn default() -> Self {
        Self::new()
    }
}

fn stream_lines<R: std::io::Read>(r: R, notify: &Notify, pid: u32, method: &'static str) {
    let reader = std::io::BufReader::new(r);
    for line in reader.lines() {
        match line {
            Ok(line) if !line.is_empty() => notify(json!({
                "jsonrpc": "2.0",
                "method": method,
                "params": { "pid": pid, "data": line }
            })),
            _ => {}
        }
    }
}

/// Terminates a process, killing the whole tree on Windows.
fn kill(child: &mut Child) {
    #[cfg(target_os = "windows")]
    {
        let _ = Command::new("taskkill")
            .args(["/PID", &child.id().to_string(), "/T", "/F"])
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status();
    }
    let _ = child.kill();
    let _ = child.wait();
}