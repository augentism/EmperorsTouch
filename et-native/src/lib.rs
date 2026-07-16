//! et_native.dll — native buttplug.io backend for the EmperorsTouch
//! Darktide mod, called from the game's LuaJIT via `Mods.lua.ffi`.
//!
//! Contract with the Lua side (logic/native_backend.lua):
//!   * All exports are C ABI, panic-proof (catch_unwind), and safe to call
//!     from the game thread at any time. Nothing here ever calls back into
//!     Lua or blocks on network I/O — device traffic happens on a
//!     background tokio thread owned by engine.rs.
//!   * The DLL is loaded once per game process and never unloaded (LuaJIT
//!     cannot unload; mod hot-reload just re-uses it), so BP_Connect is
//!     idempotent and re-entrant.
//!   * String out-params: caller passes (buf, size); return is bytes
//!     written (NUL appended), or -needed if the buffer is too small — the
//!     call can simply be retried with a bigger buffer, nothing is lost.

mod command;
mod engine;
mod schedule;

use std::ffi::{c_char, CStr};
use std::panic::catch_unwind;
use std::sync::atomic::Ordering;
use std::sync::Arc;

use once_cell::sync::OnceCell;
use tokio::sync::mpsc;

use engine::{EngineCmd, Shared};

struct Engine {
    _runtime: tokio::runtime::Runtime,
    tx: mpsc::Sender<EngineCmd>,
    shared: Arc<Shared>,
}

static ENGINE: OnceCell<Engine> = OnceCell::new();

fn engine() -> &'static Engine {
    ENGINE.get_or_init(|| {
        let runtime = tokio::runtime::Builder::new_multi_thread()
            .worker_threads(2)
            .enable_all()
            .thread_name("et-native")
            .build()
            .expect("tokio runtime");
        let shared = Arc::new(Shared::new());
        let (tx, rx) = mpsc::channel(64);
        runtime.spawn(engine::engine_main(shared.clone(), rx));
        Engine { _runtime: runtime, tx, shared }
    })
}

/// Copies `s` (+ NUL) into the caller's buffer. Returns bytes written, or
/// -needed when the buffer is too small.
fn write_out(s: &str, buf: *mut c_char, size: i32) -> i32 {
    let bytes = s.as_bytes();
    let needed = bytes.len() as i32 + 1;
    if buf.is_null() || size < needed {
        return -needed;
    }
    unsafe {
        std::ptr::copy_nonoverlapping(bytes.as_ptr(), buf as *mut u8, bytes.len());
        *buf.add(bytes.len()) = 0;
    }
    bytes.len() as i32
}

fn read_in(ptr: *const c_char) -> Option<String> {
    if ptr.is_null() {
        return None;
    }
    unsafe { CStr::from_ptr(ptr) }
        .to_str()
        .ok()
        .map(|s| s.to_string())
}

/// Starts (or retargets) the connection to Intiface at `url`
/// (e.g. "ws://127.0.0.1:12345"). Idempotent; safe across mod hot-reloads.
/// Returns 1 on accept, 0 on bad input.
#[no_mangle]
pub extern "C" fn BP_Connect(url: *const c_char) -> i32 {
    catch_unwind(|| {
        let Some(url) = read_in(url) else {
            return 0;
        };
        if !url.starts_with("ws://") && !url.starts_with("wss://") {
            engine().shared.set_error(format!("not a websocket url: {url}"));
            return 0;
        }
        let e = engine();
        *e.shared.url.lock().unwrap() = url;
        e.shared.enabled.store(true, Ordering::Relaxed);
        let _ = e.tx.try_send(EngineCmd::Poke);
        1
    })
    .unwrap_or(0)
}

/// Stops all devices, disconnects, and disables reconnection until the
/// next BP_Connect.
#[no_mangle]
pub extern "C" fn BP_Disconnect() {
    let _ = catch_unwind(|| {
        if let Some(e) = ENGINE.get() {
            e.shared.enabled.store(false, Ordering::Relaxed);
            let _ = e.tx.try_send(EngineCmd::Disconnect);
        }
    });
}

/// 0 = disconnected, 1 = connecting, 2 = connected, 3 = failed (retrying).
#[no_mangle]
pub extern "C" fn BP_Status() -> i32 {
    catch_unwind(|| {
        ENGINE
            .get()
            .map(|e| e.shared.status.load(Ordering::Relaxed))
            .unwrap_or(engine::ST_DISCONNECTED)
    })
    .unwrap_or(engine::ST_DISCONNECTED)
}

/// Accepts the mod's Lovense-style command JSON (the exact structure
/// make_toy_command builds: Function/Stop, action string, timeSec, loops,
/// toy id(s) "bp<idx>"). Returns 1 = accepted and queued (the same
/// contract as the bridge's HTTP 200 — before hardware ack), 0 = rejected
/// (bad JSON, unknown command, not connected, or no target toy exists);
/// details via BP_LastError.
#[no_mangle]
pub extern "C" fn BP_Command(json: *const c_char) -> i32 {
    catch_unwind(|| {
        let Some(json) = read_in(json) else {
            return 0;
        };
        let e = engine();
        if e.shared.status.load(Ordering::Relaxed) != engine::ST_CONNECTED {
            e.shared.set_error("not connected to Intiface");
            return 0;
        }
        let cmd = match command::parse_command(&json) {
            Ok(cmd) => cmd,
            Err(err) => {
                e.shared.set_error(err);
                return 0;
            }
        };
        // Cheap validation so targeted sends to vanished toys fail fast
        // (the mod's per-toy retry/error paths rely on this signal).
        if let Some(indices) = &cmd.device_indices {
            let known = e.shared.known_indices.lock().unwrap();
            if !indices.iter().any(|i| known.contains(i)) {
                e.shared.set_error("toy not found");
                return 0;
            }
        }
        match e.tx.try_send(EngineCmd::Command(cmd)) {
            Ok(()) => 1,
            Err(_) => {
                e.shared.set_error("engine busy (queue full)");
                0
            }
        }
    })
    .unwrap_or(0)
}

/// Writes the current device snapshot as a Lovense-shaped toys map:
/// {"bp0":{"id":"bp0","name":...,"battery":...,"status":"1"},...} ("{}"
/// when none). The Lua side wraps it in the GetToys response envelope.
#[no_mangle]
pub extern "C" fn BP_GetDevices(buf: *mut c_char, size: i32) -> i32 {
    catch_unwind(|| {
        let snapshot = ENGINE
            .get()
            .map(|e| e.shared.devices_json.lock().unwrap().clone())
            .unwrap_or_else(|| "{}".to_string());
        write_out(&snapshot, buf, size)
    })
    .unwrap_or(0)
}

/// Writes the last error message (empty string if none).
#[no_mangle]
pub extern "C" fn BP_LastError(buf: *mut c_char, size: i32) -> i32 {
    catch_unwind(|| {
        let msg = ENGINE
            .get()
            .map(|e| e.shared.last_error.lock().unwrap().clone())
            .unwrap_or_default();
        write_out(&msg, buf, size)
    })
    .unwrap_or(0)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::ffi::CString;

    #[test]
    fn write_out_roundtrip_and_too_small() {
        let mut buf = [0 as c_char; 8];
        let n = write_out("hello", buf.as_mut_ptr(), buf.len() as i32);
        assert_eq!(n, 5);
        let s = unsafe { CStr::from_ptr(buf.as_ptr()) };
        assert_eq!(s.to_str().unwrap(), "hello");

        let n = write_out("hello world", buf.as_mut_ptr(), buf.len() as i32);
        assert_eq!(n, -12); // 11 bytes + NUL needed
    }

    #[test]
    fn connect_rejects_non_ws_url() {
        let url = CString::new("http://127.0.0.1:12345").unwrap();
        assert_eq!(BP_Connect(url.as_ptr()), 0);
        assert_eq!(BP_Connect(std::ptr::null()), 0);
    }

    #[test]
    fn command_rejected_while_disconnected() {
        // Relies on the test engine never being connected to Intiface.
        let cmd = CString::new(r#"{"command":"Function","action":"Vibrate:10"}"#).unwrap();
        assert_eq!(BP_Command(cmd.as_ptr()), 0);
        let mut buf = [0 as c_char; 256];
        let n = BP_LastError(buf.as_mut_ptr(), buf.len() as i32);
        assert!(n > 0);
    }
}
