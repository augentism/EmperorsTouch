//! End-to-end smoke test against a public websocket echo server.
//! Requires network access; run with `cargo test --release -- --nocapture`.

use std::ffi::CString;
use std::thread;
use std::time::{Duration, Instant};

use darktide_ws::*;

fn last_error() -> String {
    let mut buf = vec![0i8; 1024];
    let n = WS_LastError(buf.as_mut_ptr(), buf.len() as i32);
    String::from_utf8_lossy(
        &buf[..n as usize].iter().map(|&b| b as u8).collect::<Vec<_>>(),
    )
    .into_owned()
}

#[test]
fn echo_roundtrip() {
    let url = CString::new("wss://echo.websocket.org").unwrap();
    assert_eq!(WS_Connect(url.as_ptr()), 1, "connect should start");

    // wait for connected (or fail)
    let deadline = Instant::now() + Duration::from_secs(15);
    loop {
        match WS_Status() {
            2 => break,
            3 => panic!("connection failed: {}", last_error()),
            _ if Instant::now() > deadline => panic!("timed out connecting"),
            _ => thread::sleep(Duration::from_millis(50)),
        }
    }

    let msg = CString::new(r#"{"hello":"darktide"}"#).unwrap();
    assert_eq!(WS_Send(msg.as_ptr()), 1, "send should queue");

    // poll for the echo (the server may send a greeting first)
    let mut buf = vec![0i8; 65536];
    let deadline = Instant::now() + Duration::from_secs(15);
    let mut got_echo = false;
    while Instant::now() < deadline {
        match WS_Poll(buf.as_mut_ptr(), buf.len() as i32) {
            1 => {
                let n = buf.iter().position(|&b| b == 0).unwrap();
                let text: String = buf[..n].iter().map(|&b| b as u8 as char).collect();
                println!("received: {text}");
                if text.contains("darktide") {
                    got_echo = true;
                    break;
                }
            }
            0 => thread::sleep(Duration::from_millis(50)),
            e => panic!("poll error {e}"),
        }
    }
    assert!(got_echo, "never received our echoed message");

    WS_Disconnect();
    let deadline = Instant::now() + Duration::from_secs(5);
    while WS_Status() == 2 && Instant::now() < deadline {
        thread::sleep(Duration::from_millis(50));
    }
    println!("final status: {}", WS_Status());
}
