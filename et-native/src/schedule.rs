//! Lovense timing emulation on top of Buttplug, which has neither
//! durations nor duty cycles. Direct port of bridge.py's run_schedule /
//! apply_levels semantics (which themselves mirror real Lovense hardware):
//!   * timeSec > 0: apply levels, wait, zero out.
//!   * loopRunningSec/loopPauseSec: on/off cycle for timeSec (forever if 0).
//!   * A newer command for the same device ABORTS the running schedule
//!     without zeroing — the new command simply takes over, exactly like
//!     hardware where a new Function replaces the running one and never
//!     resumes what it interrupted.

use std::collections::BTreeMap;
use std::time::Duration;

use buttplug_client::device::{ClientDeviceCommandValue, ClientDeviceOutputCommand};
use buttplug_client::ButtplugClientDevice;
use buttplug_core::message::OutputType;

use crate::command::{Level, OutputKind};

fn output_type(kind: OutputKind) -> OutputType {
    match kind {
        OutputKind::Vibrate => OutputType::Vibrate,
        OutputKind::Rotate => OutputType::Rotate,
        OutputKind::Oscillate => OutputType::Oscillate,
        OutputKind::Constrict => OutputType::Constrict,
        OutputKind::Position => OutputType::Position,
        OutputKind::Stroke => OutputType::HwPositionWithDuration,
    }
}

fn command_for(kind: OutputKind, strength: f64, stroke_high: bool) -> ClientDeviceOutputCommand {
    let value = ClientDeviceCommandValue::Percent(strength);
    match kind {
        OutputKind::Vibrate => ClientDeviceOutputCommand::Vibrate(value),
        OutputKind::Rotate => ClientDeviceOutputCommand::Rotate(value),
        OutputKind::Oscillate => ClientDeviceOutputCommand::Oscillate(value),
        OutputKind::Constrict => ClientDeviceOutputCommand::Constrict(value),
        OutputKind::Position => ClientDeviceOutputCommand::Position(value),
        OutputKind::Stroke => {
            // Speed -> sweep duration, same curve as bridge.py (fast
            // strokes at high strength). Alternate ends so repeated
            // applies actually stroke.
            let duration_ms = (2000.0 - 1700.0 * strength).max(100.0) as u32;
            let target = if stroke_high { 0.9 } else { 0.1 };
            ClientDeviceOutputCommand::HwPositionWithDuration(
                ClientDeviceCommandValue::Percent(target),
                duration_ms,
            )
        }
    }
}

/// Sends one set of Lovense-style levels to whatever outputs the device
/// actually has. Preferred kinds in order, falling back to Vibrate
/// (bridge.py fell back to the first scalar actuator). Per-output errors
/// are ignored — device dropouts surface via the connection loop instead.
pub async fn apply_levels(
    device: &ButtplugClientDevice,
    levels: &BTreeMap<String, Level>,
    stroke_high: &mut bool,
) {
    for level in levels.values() {
        let kind = level
            .kinds
            .iter()
            .copied()
            .find(|k| device.output_available(output_type(*k)))
            .or_else(|| {
                device
                    .output_available(OutputType::Vibrate)
                    .then_some(OutputKind::Vibrate)
            });

        let Some(kind) = kind else { continue };
        if kind == OutputKind::Stroke {
            if level.strength <= 0.0 {
                continue; // a zero stroke is "don't move", not a sweep
            }
            *stroke_high = !*stroke_high;
        }
        let _ = device
            .run_output(&command_for(kind, level.strength, *stroke_high))
            .await;
    }
}

pub async fn stop_device(device: &ButtplugClientDevice) {
    let _ = device.stop().await;
}

/// Runs one command's full Lovense schedule on one device. Spawned as a
/// task; the engine aborts it when a newer command targets the device.
pub async fn run_schedule(
    device: ButtplugClientDevice,
    levels: BTreeMap<String, Level>,
    time_sec: f64,
    loop_on: f64,
    loop_off: f64,
) {
    let mut stroke_high = false;
    let deadline = (time_sec > 0.0)
        .then(|| tokio::time::Instant::now() + Duration::from_secs_f64(time_sec));

    if loop_on > 0.0 && loop_off > 0.0 {
        loop {
            if let Some(d) = deadline {
                if tokio::time::Instant::now() >= d {
                    break;
                }
            }
            apply_levels(&device, &levels, &mut stroke_high).await;
            tokio::time::sleep(Duration::from_secs_f64(loop_on)).await;
            stop_device(&device).await;
            tokio::time::sleep(Duration::from_secs_f64(loop_off)).await;
        }
    } else {
        apply_levels(&device, &levels, &mut stroke_high).await;
        match deadline {
            None => return, // continuous: runs until replaced
            Some(d) => tokio::time::sleep_until(d).await,
        }
    }

    stop_device(&device).await;
}
