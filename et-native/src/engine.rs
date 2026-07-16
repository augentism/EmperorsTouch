//! The background engine: one tokio runtime thread owning the Buttplug
//! client. The FFI layer (lib.rs) never blocks on it — commands go in
//! through a channel, state comes out through `Shared` snapshots. LuaJIT
//! is never entered from these threads.

use std::collections::{HashMap, HashSet};
use std::sync::atomic::{AtomicBool, AtomicI32, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use buttplug_client::connector::ButtplugRemoteClientConnector;
use buttplug_client::serializer::ButtplugClientJSONSerializer;
use buttplug_client::{ButtplugClient, ButtplugClientDevice};
use buttplug_transport_websocket_tungstenite::ButtplugWebsocketClientTransport;
use tokio::sync::mpsc;
use tokio::task::JoinHandle;

use crate::command::ToyCommand;
use crate::schedule;

pub const ST_DISCONNECTED: i32 = 0;
pub const ST_CONNECTING: i32 = 1;
pub const ST_CONNECTED: i32 = 2;
pub const ST_FAILED: i32 = 3;

const RETRY_INTERVAL: Duration = Duration::from_secs(5);

/// State shared between the FFI thread and the engine task.
pub struct Shared {
    pub status: AtomicI32,
    pub enabled: AtomicBool,
    pub url: Mutex<String>,
    pub last_error: Mutex<String>,
    /// Lovense-shaped toys map, pre-serialized: {"bp0":{"id":"bp0",...}}.
    /// The Lua side wraps it in the GetToys envelope.
    pub devices_json: Mutex<String>,
    /// Device indices currently known, for cheap toy-id validation in
    /// BP_Command without touching the runtime.
    pub known_indices: Mutex<HashSet<u32>>,
}

impl Shared {
    pub fn new() -> Self {
        Shared {
            status: AtomicI32::new(ST_DISCONNECTED),
            enabled: AtomicBool::new(false),
            url: Mutex::new(String::new()),
            last_error: Mutex::new(String::new()),
            devices_json: Mutex::new("{}".to_string()),
            known_indices: Mutex::new(HashSet::new()),
        }
    }

    pub fn set_error(&self, msg: impl Into<String>) {
        *self.last_error.lock().unwrap() = msg.into();
    }
}

pub enum EngineCmd {
    Command(ToyCommand),
    /// Re-check the connection now (sent by BP_Connect so the first
    /// connect doesn't wait for the retry tick).
    Poke,
    /// Stop everything and disconnect (enabled has been cleared).
    Disconnect,
}

struct Connection {
    client: ButtplugClient,
    url: String,
    /// device index -> running schedule task. A new command for the
    /// device aborts the old task (abort, not zero — hardware semantics).
    timers: HashMap<u32, JoinHandle<()>>,
    /// Battery read once per device on discovery (probing every tick
    /// spams the device); None while the probe is in flight/failed.
    batteries: HashMap<u32, Option<u32>>,
}

impl Connection {
    fn cancel_timer(&mut self, index: u32) {
        if let Some(task) = self.timers.remove(&index) {
            task.abort();
        }
    }

    fn cancel_all_timers(&mut self) {
        for (_, task) in self.timers.drain() {
            task.abort();
        }
    }
}

pub async fn engine_main(shared: Arc<Shared>, mut rx: mpsc::Receiver<EngineCmd>) {
    let mut conn: Option<Connection> = None;
    let mut tick = tokio::time::interval(RETRY_INTERVAL);
    tick.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);

    loop {
        tokio::select! {
            _ = tick.tick() => {
                maintain(&shared, &mut conn).await;
            }
            cmd = rx.recv() => match cmd {
                None => break,
                Some(EngineCmd::Poke) => {
                    maintain(&shared, &mut conn).await;
                    tick.reset();
                }
                Some(EngineCmd::Disconnect) => {
                    teardown(&shared, &mut conn).await;
                }
                Some(EngineCmd::Command(cmd)) => {
                    handle_command(&shared, &mut conn, cmd).await;
                }
            }
        }
    }
}

/// Keeps the connection matching the desired state (enabled + url), and
/// refreshes the device snapshot.
async fn maintain(shared: &Arc<Shared>, conn: &mut Option<Connection>) {
    let enabled = shared.enabled.load(Ordering::Relaxed);
    let want_url = shared.url.lock().unwrap().clone();

    // Drop a connection that died or no longer matches the desired URL.
    if let Some(c) = conn.as_ref() {
        if !enabled || !c.client.connected() || c.url != want_url {
            teardown(shared, conn).await;
            if enabled {
                shared.status.store(ST_CONNECTING, Ordering::Relaxed);
            }
        }
    }

    if enabled && conn.is_none() && !want_url.is_empty() {
        shared.status.store(ST_CONNECTING, Ordering::Relaxed);
        match connect(&want_url).await {
            Ok(client) => {
                let _ = client.start_scanning().await;
                *conn = Some(Connection {
                    client,
                    url: want_url,
                    timers: HashMap::new(),
                    batteries: HashMap::new(),
                });
                shared.status.store(ST_CONNECTED, Ordering::Relaxed);
            }
            Err(e) => {
                shared.status.store(ST_FAILED, Ordering::Relaxed);
                shared.set_error(format!("Intiface not reachable at {want_url}: {e}"));
            }
        }
    }

    refresh_snapshot(shared, conn).await;
}

async fn connect(url: &str) -> Result<ButtplugClient, String> {
    let connector = ButtplugRemoteClientConnector::<
        ButtplugWebsocketClientTransport,
        ButtplugClientJSONSerializer,
    >::new(ButtplugWebsocketClientTransport::new_insecure_connector(url));
    let client = ButtplugClient::new("EmperorsTouch");
    client.connect(connector).await.map_err(|e| e.to_string())?;
    Ok(client)
}

async fn teardown(shared: &Arc<Shared>, conn: &mut Option<Connection>) {
    if let Some(mut c) = conn.take() {
        c.cancel_all_timers();
        if c.client.connected() {
            for (_, device) in c.client.devices() {
                schedule::stop_device(&device).await;
            }
            let _ = c.client.disconnect().await;
        }
    }
    shared.status.store(ST_DISCONNECTED, Ordering::Relaxed);
    refresh_snapshot(shared, &mut None).await;
}

/// Rebuilds the Lovense-shaped device snapshot the FFI layer serves, and
/// probes battery once for newly seen devices.
async fn refresh_snapshot(shared: &Arc<Shared>, conn: &mut Option<Connection>) {
    let mut toys = serde_json::Map::new();
    let mut indices = HashSet::new();

    if let Some(c) = conn.as_mut() {
        if c.client.connected() {
            let devices = c.client.devices();
            for (index, device) in &devices {
                if !c.batteries.contains_key(index) {
                    let battery = tokio::time::timeout(Duration::from_secs(2), device.battery())
                        .await
                        .ok()
                        .and_then(|r| r.ok());
                    c.batteries.insert(*index, battery);
                }
                let battery = c.batteries.get(index).copied().flatten();

                let toy_id = format!("bp{index}");
                let name = device
                    .name()
                    .split_whitespace()
                    .next()
                    .unwrap_or("device")
                    .to_lowercase();
                let mut toy = serde_json::Map::new();
                toy.insert("id".into(), toy_id.clone().into());
                toy.insert("name".into(), name.into());
                toy.insert("nickName".into(), device.name().to_string().into());
                if let Some(b) = battery {
                    toy.insert("battery".into(), b.into());
                }
                toy.insert("version".into(), "".into());
                toy.insert("status".into(), "1".into());
                toys.insert(toy_id, toy.into());
                indices.insert(*index);
            }
            // Forget batteries of departed devices so a re-pair re-probes.
            c.batteries.retain(|i, _| indices.contains(i));
        }
    }

    *shared.devices_json.lock().unwrap() =
        serde_json::Value::Object(toys).to_string();
    *shared.known_indices.lock().unwrap() = indices;
}

async fn handle_command(shared: &Arc<Shared>, conn: &mut Option<Connection>, cmd: ToyCommand) {
    let Some(c) = conn.as_mut() else {
        shared.set_error("not connected to Intiface");
        return;
    };

    let devices = c.client.devices();
    let targets: Vec<(u32, ButtplugClientDevice)> = match &cmd.device_indices {
        None => devices.into_iter().collect(),
        Some(indices) => indices
            .iter()
            .filter_map(|i| devices.get(i).map(|d| (*i, d.clone())))
            .collect(),
    };
    if targets.is_empty() {
        shared.set_error("no matching devices");
        return;
    }

    for (index, device) in targets {
        // Newest command replaces whatever is scheduled — same semantics
        // as real Lovense hardware.
        c.cancel_timer(index);
        match &cmd.levels {
            None => schedule::stop_device(&device).await,
            Some(levels) => {
                let task = tokio::spawn(schedule::run_schedule(
                    device,
                    levels.clone(),
                    cmd.time_sec,
                    cmd.loop_on,
                    cmd.loop_off,
                ));
                c.timers.insert(index, task);
            }
        }
    }
}
