//! Minimal websocket client DLL for Darktide mods (LuaJIT FFI).
//!
//! Design: a background thread owns the socket; Lua only enqueues sends and
//! polls received messages from the game thread. No callbacks ever cross the
//! FFI boundary, and every export catches panics.

use std::ffi::{c_char, CStr};
use std::panic::catch_unwind;
use std::sync::atomic::{AtomicI32, Ordering};
use std::sync::mpsc::{channel, Receiver, Sender, TryRecvError};
use std::sync::Mutex;
use std::thread;
use std::time::Duration;

// status codes read by Lua via WS_Status
const ST_DISCONNECTED: i32 = 0;
const ST_CONNECTING: i32 = 1;
const ST_CONNECTED: i32 = 2;
const ST_FAILED: i32 = 3;

// poll results
const POLL_EMPTY: i32 = 0;
const POLL_MESSAGE: i32 = 1;
const POLL_ERR_BUFFER_TOO_SMALL: i32 = -1;

struct Conn {
    outgoing: Sender<String>,
    incoming: Receiver<String>,
}

static STATUS: AtomicI32 = AtomicI32::new(ST_DISCONNECTED);
static CONN: Mutex<Option<Conn>> = Mutex::new(None);
static LAST_ERROR: Mutex<String> = Mutex::new(String::new());

fn set_error(msg: impl Into<String>) {
    *LAST_ERROR.lock().unwrap() = msg.into();
}

fn worker(url: String, out_rx: Receiver<String>, in_tx: Sender<String>) {
    STATUS.store(ST_CONNECTING, Ordering::SeqCst);

    let mut socket = match tungstenite::connect(&url) {
        Ok((s, _resp)) => s,
        Err(e) => {
            set_error(format!("connect failed: {e}"));
            STATUS.store(ST_FAILED, Ordering::SeqCst);
            return;
        }
    };

    // Non-blocking reads so one loop can service both directions.
    match socket.get_mut() {
        tungstenite::stream::MaybeTlsStream::Plain(s) => {
            s.set_nonblocking(true).ok();
        }
        tungstenite::stream::MaybeTlsStream::NativeTls(s) => {
            s.get_mut().set_nonblocking(true).ok();
        }
        _ => {}
    }

    STATUS.store(ST_CONNECTED, Ordering::SeqCst);

    loop {
        let mut idle = true;

        // Drain Lua -> socket queue. Sender dropped = disconnect requested.
        loop {
            match out_rx.try_recv() {
                Ok(text) => {
                    idle = false;
                    if let Err(e) = socket.send(tungstenite::Message::Text(text.into())) {
                        set_error(format!("send failed: {e}"));
                        STATUS.store(ST_FAILED, Ordering::SeqCst);
                        return;
                    }
                }
                Err(TryRecvError::Empty) => break,
                Err(TryRecvError::Disconnected) => {
                    let _ = socket.close(None);
                    STATUS.store(ST_DISCONNECTED, Ordering::SeqCst);
                    return;
                }
            }
        }

        // Socket -> Lua queue. tungstenite answers ping/pong internally on read.
        match socket.read() {
            Ok(tungstenite::Message::Text(text)) => {
                idle = false;
                if in_tx.send(text.to_string()).is_err() {
                    return; // Lua side gone
                }
            }
            Ok(tungstenite::Message::Close(_)) => {
                STATUS.store(ST_DISCONNECTED, Ordering::SeqCst);
                return;
            }
            Ok(_) => idle = false, // binary/ping/pong: ignored
            Err(tungstenite::Error::Io(e)) if e.kind() == std::io::ErrorKind::WouldBlock => {}
            Err(e) => {
                set_error(format!("read failed: {e}"));
                STATUS.store(ST_FAILED, Ordering::SeqCst);
                return;
            }
        }

        if idle {
            thread::sleep(Duration::from_millis(10));
        }
    }
}

/// Connect (spawns the worker thread). 1 = started, 0 = error.
/// Replaces any existing connection.
#[no_mangle]
pub extern "C" fn WS_Connect(url: *const c_char) -> i32 {
    catch_unwind(|| {
        let url = match unsafe { CStr::from_ptr(url) }.to_str() {
            Ok(s) => s.to_owned(),
            Err(_) => {
                set_error("url is not valid UTF-8");
                return 0;
            }
        };

        let (out_tx, out_rx) = channel::<String>();
        let (in_tx, in_rx) = channel::<String>();

        *CONN.lock().unwrap() = Some(Conn {
            outgoing: out_tx,
            incoming: in_rx,
        });
        thread::spawn(move || worker(url, out_rx, in_tx));
        1
    })
    .unwrap_or(0)
}

/// Queue a text message. 1 = queued, 0 = not connected.
#[no_mangle]
pub extern "C" fn WS_Send(text: *const c_char) -> i32 {
    catch_unwind(|| {
        let text = match unsafe { CStr::from_ptr(text) }.to_str() {
            Ok(s) => s.to_owned(),
            Err(_) => return 0,
        };
        match CONN.lock().unwrap().as_ref() {
            Some(c) if c.outgoing.send(text).is_ok() => 1,
            _ => 0,
        }
    })
    .unwrap_or(0)
}

/// Pop one received message into buffer (NUL-terminated).
/// Returns POLL_MESSAGE (1), POLL_EMPTY (0), or POLL_ERR_BUFFER_TOO_SMALL (-1).
#[no_mangle]
pub extern "C" fn WS_Poll(buffer: *mut c_char, buffer_size: i32) -> i32 {
    catch_unwind(|| {
        let guard = CONN.lock().unwrap();
        let Some(conn) = guard.as_ref() else {
            return POLL_EMPTY;
        };
        match conn.incoming.try_recv() {
            Ok(msg) => {
                let bytes = msg.as_bytes();
                if bytes.len() + 1 > buffer_size as usize {
                    return POLL_ERR_BUFFER_TOO_SMALL;
                }
                unsafe {
                    std::ptr::copy_nonoverlapping(bytes.as_ptr(), buffer as *mut u8, bytes.len());
                    *buffer.add(bytes.len()) = 0;
                }
                POLL_MESSAGE
            }
            Err(_) => POLL_EMPTY,
        }
    })
    .unwrap_or(POLL_EMPTY)
}

/// 0 = disconnected, 1 = connecting, 2 = connected, 3 = failed.
#[no_mangle]
pub extern "C" fn WS_Status() -> i32 {
    STATUS.load(Ordering::SeqCst)
}

/// Drops the channels; the worker notices and closes the socket.
#[no_mangle]
pub extern "C" fn WS_Disconnect() {
    let _ = catch_unwind(|| {
        *CONN.lock().unwrap() = None;
    });
}

/// Copy last error into buffer (NUL-terminated). Returns length copied.
#[no_mangle]
pub extern "C" fn WS_LastError(buffer: *mut c_char, buffer_size: i32) -> i32 {
    catch_unwind(|| {
        if buffer_size < 1 {
            return 0;
        }
        let err = LAST_ERROR.lock().unwrap();
        let n = err.as_bytes().len().min(buffer_size as usize - 1);
        unsafe {
            std::ptr::copy_nonoverlapping(err.as_ptr(), buffer as *mut u8, n);
            *buffer.add(n) = 0;
        }
        n as i32
    })
    .unwrap_or(0)
}
