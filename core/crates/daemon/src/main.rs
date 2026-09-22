//! Flutter Installer daemon.
//!
//! Speaks JSON-RPC 2.0 over stdio, one JSON object per line:
//!
//!   request:      {"jsonrpc":"2.0","id":1,"method":"flutter.latest","params":{...}}
//!   response:     {"jsonrpc":"2.0","id":1,"result":{...}}
//!   error:        {"jsonrpc":"2.0","id":1,"error":{"code":-32601,"message":"..."}}
//!   notification: {"jsonrpc":"2.0","method":"progress","params":{...}}
//!
//! The Flutter UI launches this as a sidecar process and drives it via stdin.

use std::io::{BufRead, Write};
use std::sync::mpsc;
use std::sync::Arc;

use serde_json::{json, Value};

fn main() -> anyhow::Result<()> {
    let app = Arc::new(core::rpc::App::new());

    // All output (responses + notifications) is funneled through one writer
    // thread so concurrent requests can't interleave partial JSON lines.
    let (tx, rx) = mpsc::channel::<Value>();
    std::thread::spawn(move || {
        let stdout = std::io::stdout();
        let mut out = stdout.lock();
        for value in rx {
            // Ignore write errors: the host process may close the pipe.
            let _ = serde_json::to_writer(&mut out, &value);
            let _ = out.write_all(b"\n");
            let _ = out.flush();
        }
    });

    let notify: core::Notify = {
        let tx = tx.clone();
        Arc::new(move |v: Value| {
            let _ = tx.send(v);
        })
    };

    let stdin = std::io::stdin();
    for line in stdin.lock().lines() {
        let line = match line {
            Ok(l) => l,
            Err(_) => break,
        };
        if line.trim().is_empty() {
            continue;
        }
        let msg: Value = match serde_json::from_str(&line) {
            Ok(m) => m,
            Err(_) => {
                let _ = tx.send(json!({
                    "jsonrpc": "2.0", "id": null,
                    "error": { "code": -32700, "message": "parse error" }
                }));
                continue;
            }
        };

        let id = msg.get("id").cloned();
        let method = msg
            .get("method")
            .and_then(|m| m.as_str())
            .unwrap_or("")
            .to_string();
        let params = msg.get("params").cloned().unwrap_or_else(|| json!({}));

        let app = app.clone();
        let tx = tx.clone();
        let notify = notify.clone();
        std::thread::spawn(move || {
            let result = app.dispatch(&method, params, &notify);
            let id = id.unwrap_or(Value::Null);
            let out = match result {
                Ok(value) => json!({ "jsonrpc": "2.0", "id": id, "result": value }),
                Err(e) => json!({
                    "jsonrpc": "2.0", "id": id,
                    "error": { "code": e.code, "message": e.message, "data": e.data }
                }),
            };
            let _ = tx.send(out);
        });
    }

    Ok(())
}