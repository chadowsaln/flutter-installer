//! FFI bridge for embedding the Flutter Installer core inside the UI process.
//!
//! Instead of spawning a JSON-RPC daemon sidecar ("server"), the host app
//! loads this `cdylib` via `dart:ffi` and talks to it through a tiny C ABI:
//!
//!   * `ffi_core_new()`              - create a handle (owns `App` + output queue)
//!   * `ffi_core_call(h, method, params_json, id)` - schedule a request; runs on
//!     its own thread, so long downloads never block the UI
//!   * `ffi_core_poll(h)`            - pop the next JSON message (response or
//!     notification) or NULL; the caller frees it with `ffi_core_free_string`
//!   * `ffi_core_free_string(s)`     - free a string returned by `poll`
//!   * `ffi_core_destroy(h)`         - drop the handle
//!
//! Every response and notification (progress, log, task.*, process.*) flows
//! through one shared `mpsc` channel, exactly like the daemon's writer thread,
//! so ordering is preserved and no locking is needed around `App`.

use std::ffi::{c_char, CStr};
use std::os::raw::c_void;
use std::ptr;
use std::sync::{mpsc, Arc};

use serde_json::{json, Value};

use core::rpc::App;

/// Opaque handle returned by `ffi_core_new`. Never moved; lives on the heap.
pub struct CoreHandle {
    app: Arc<App>,
    tx: mpsc::Sender<Value>,
    rx: mpsc::Receiver<Value>,
}

/// Creates a new core handle. Returns NULL on any error.
///
/// # Safety
/// The returned pointer must be freed with `ffi_core_destroy`.
#[no_mangle]
pub extern "C" fn ffi_core_new() -> *mut c_void {
    let (tx, rx) = mpsc::channel::<Value>();
    let handle = CoreHandle {
        app: Arc::new(App::new()),
        tx,
        rx,
    };
    Box::into_raw(Box::new(handle)) as *mut c_void
}

/// Schedules a JSON-RPC request (minus the envelope) on a fresh thread.
///
/// `method` and `params_json` are UTF-8 C strings; the response is enqueued
/// tagged with `id`. Returns 0 on success, -1 for a null/invalid handle or
/// method, -2 when `params_json` is not valid JSON.
///
/// # Safety
/// `core` must come from `ffi_core_new`; strings must be NUL-terminated and
/// stay valid for the duration of this call (the request is serialized
/// synchronously).
#[no_mangle]
pub extern "C" fn ffi_core_call(
    core: *mut c_void,
    method: *const c_char,
    params_json: *const c_char,
    id: i64,
) -> i32 {
    if core.is_null() || method.is_null() || params_json.is_null() {
        return -1;
    }
    let handle = unsafe { &*core.cast::<CoreHandle>() };
    let method = match read_c_string(method) {
        Some(s) => s,
        None => return -1,
    };
    let params: Value = match serde_json::from_str(&read_c_string(params_json).unwrap_or_default())
    {
        Ok(v) => v,
        Err(_) => return -2,
    };

    let app = Arc::clone(&handle.app);
    let tx = handle.tx.clone();
    std::thread::spawn(move || {
        let notify: core::Notify = {
            let tx = tx.clone();
            Arc::new(move |v: Value| {
                let _ = tx.send(v);
            })
        };
        let out = match app.dispatch(&method, params, &notify) {
            Ok(result) => json!({ "jsonrpc": "2.0", "id": id, "result": result }),
            Err(e) => json!({
                "jsonrpc": "2.0", "id": id,
                "error": { "code": e.code, "message": e.message, "data": e.data }
            }),
        };
        let _ = tx.send(out);
    });
    0
}

/// Pops the next pending message (response or notification) as a JSON string,
/// or NULL when the queue is empty. The returned string must be freed with
/// `ffi_core_free_string`.
///
/// # Safety
/// `core` must be a live handle from `ffi_core_new`.
#[no_mangle]
pub extern "C" fn ffi_core_poll(core: *mut c_void) -> *mut c_char {
    if core.is_null() {
        return ptr::null_mut();
    }
    let handle = unsafe { &*core.cast::<CoreHandle>() };
    // try_recv: the host drains on a timer; nothing blocks.
    match handle.rx.try_recv() {
        Ok(value) => match std::ffi::CString::new(value.to_string()) {
            Ok(cs) => cs.into_raw(),
            Err(_) => ptr::null_mut(),
        },
        Err(_) => ptr::null_mut(),
    }
}

/// Frees a string returned by `ffi_core_poll`. A no-op on NULL.
///
/// # Safety
/// `s` must come from `ffi_core_poll` (or be NULL).
#[no_mangle]
pub extern "C" fn ffi_core_free_string(s: *mut c_char) {
    if s.is_null() {
        return;
    }
    unsafe {
        drop(std::ffi::CString::from_raw(s));
    }
}

/// Destroys a handle created by `ffi_core_new`. In-flight request threads are
/// left to finish; their messages are dropped once the channel senders die.
///
/// # Safety
/// `core` must be a live handle; after this call it is dangling.
#[no_mangle]
pub extern "C" fn ffi_core_destroy(core: *mut c_void) {
    if core.is_null() {
        return;
    }
    unsafe {
        drop(Box::from_raw(core.cast::<CoreHandle>()));
    }
}

/// Reads a NUL-terminated UTF-8 C string into a Rust `String`.
fn read_c_string(s: *const c_char) -> Option<String> {
    if s.is_null() {
        return None;
    }
    unsafe { CStr::from_ptr(s).to_str().ok() }.map(str::to_owned)
}