//! Lovense-command parsing: the mod sends the exact JSON its Lovense
//! backend already builds (make_toy_command in EmperorsTouch.lua), so the
//! Lua diff for the native backend is one transport branch. Semantics are
//! a 1:1 port of bridge.py.

use std::collections::BTreeMap;

/// Lovense action name -> (max strength, preferred Buttplug output kinds,
/// in priority order). Kinds are matched in engine.rs against what the
/// device actually exposes; the last-resort fallback there is Vibrate.
pub const ACTIONS: &[(&str, f64, &[OutputKind])] = &[
    ("Vibrate", 20.0, &[OutputKind::Vibrate]),
    ("Rotate", 20.0, &[OutputKind::Rotate]),
    ("Pump", 3.0, &[OutputKind::Constrict]),
    ("Thrusting", 20.0, &[OutputKind::Oscillate, OutputKind::Position]),
    ("Fingering", 20.0, &[OutputKind::Oscillate, OutputKind::Vibrate]),
    ("Suction", 20.0, &[OutputKind::Constrict]),
    ("Depth", 3.0, &[OutputKind::Position]),
    ("Stroke", 100.0, &[OutputKind::Stroke]),
    ("Oscillate", 20.0, &[OutputKind::Oscillate]),
];

/// Abstract output kinds, decoupled from buttplug types so this module
/// stays pure/testable. engine.rs maps them onto OutputType.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum OutputKind {
    Vibrate,
    Rotate,
    Oscillate,
    Constrict,
    Position,
    /// Linear sweep (HwPositionWithDuration); speed derived from strength.
    Stroke,
}

fn action_spec(name: &str) -> Option<(f64, &'static [OutputKind])> {
    ACTIONS
        .iter()
        .find(|(n, _, _)| *n == name)
        .map(|(_, max, kinds)| (*max, *kinds))
}

/// "Vibrate:12,Rotate:5" -> { Vibrate: 0.6, Rotate: 0.25 } (0..1 scaled);
/// "Stop" -> None. Unknown actions and bad numbers are skipped, matching
/// bridge.py.
pub fn parse_action_string(action: &str) -> Option<BTreeMap<String, Level>> {
    if action == "Stop" {
        return None;
    }
    let mut levels = BTreeMap::new();
    for part in action.split(',') {
        let (name, value) = match part.split_once(':') {
            Some((n, v)) => (n.trim(), v.trim()),
            None => continue,
        };
        if let Some((max, kinds)) = action_spec(name) {
            if let Ok(raw) = value.parse::<f64>() {
                let strength = (raw / max).clamp(0.0, 1.0);
                levels.insert(name.to_string(), Level { strength, kinds });
            }
        }
    }
    Some(levels)
}

#[derive(Debug, Clone, Copy)]
pub struct Level {
    /// 0.0..1.0, already scaled by the action's Lovense max.
    pub strength: f64,
    pub kinds: &'static [OutputKind],
}

/// A parsed Function/Stop command ready for the engine.
#[derive(Debug)]
pub struct ToyCommand {
    /// None = "Stop" action (halt devices). Some(map) may be empty (all
    /// actions zeroed) — still applied.
    pub levels: Option<BTreeMap<String, Level>>,
    /// None = all devices; Some(list) = device indices parsed from
    /// "bp<idx>" ids (unknown/malformed ids are dropped, like bridge.py).
    pub device_indices: Option<Vec<u32>>,
    pub time_sec: f64,
    pub loop_on: f64,
    pub loop_off: f64,
}

/// Lovense `toy` field: absent, "bp3", or ["bp0", "bp3"].
fn parse_toy_field(toy: Option<&serde_json::Value>) -> Option<Vec<u32>> {
    let toy = toy?;
    let ids: Vec<&str> = match toy {
        serde_json::Value::String(s) => vec![s.as_str()],
        serde_json::Value::Array(arr) => arr.iter().filter_map(|v| v.as_str()).collect(),
        _ => vec![],
    };
    Some(
        ids.iter()
            .filter_map(|id| id.strip_prefix("bp"))
            .filter_map(|idx| idx.parse::<u32>().ok())
            .collect(),
    )
}

fn num(body: &serde_json::Value, key: &str) -> f64 {
    body.get(key).and_then(|v| v.as_f64()).unwrap_or(0.0)
}

/// Parses the mod's command JSON. Returns Err(reason) for anything that
/// should surface as a rejected command (BP_Command -> 0).
pub fn parse_command(json: &str) -> Result<ToyCommand, String> {
    let body: serde_json::Value =
        serde_json::from_str(json).map_err(|e| format!("bad JSON: {e}"))?;
    let command = body.get("command").and_then(|v| v.as_str()).unwrap_or("");

    match command {
        "Function" => {
            let action = body.get("action").and_then(|v| v.as_str()).unwrap_or("");
            Ok(ToyCommand {
                levels: parse_action_string(action),
                device_indices: parse_toy_field(body.get("toy")),
                time_sec: num(&body, "timeSec"),
                loop_on: num(&body, "loopRunningSec"),
                loop_off: num(&body, "loopPauseSec"),
            })
        }
        // Blanket stop (the mod's make_stop_command uses Function+"Stop",
        // but accept the bare commands the bridge accepted too).
        "Stop" | "StopAll" => Ok(ToyCommand {
            levels: None,
            device_indices: None,
            time_sec: 0.0,
            loop_on: 0.0,
            loop_off: 0.0,
        }),
        other => Err(format!("unknown command: {other}")),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_action_string_with_scaling() {
        let levels = parse_action_string("Vibrate:10,Rotate:5,Pump:3").unwrap();
        assert!((levels["Vibrate"].strength - 0.5).abs() < 1e-9);
        assert!((levels["Rotate"].strength - 0.25).abs() < 1e-9);
        assert!((levels["Pump"].strength - 1.0).abs() < 1e-9);
    }

    #[test]
    fn clamps_and_skips_garbage() {
        let levels = parse_action_string("Vibrate:999,Nonsense:5,Rotate:abc").unwrap();
        assert_eq!(levels.len(), 1);
        assert!((levels["Vibrate"].strength - 1.0).abs() < 1e-9);
    }

    #[test]
    fn stop_action_is_none() {
        assert!(parse_action_string("Stop").is_none());
    }

    #[test]
    fn parses_function_command() {
        let cmd = parse_command(
            r#"{"command":"Function","action":"Vibrate:20","timeSec":3,
                "loopRunningSec":1,"loopPauseSec":0.5,"toy":["bp0","bp3","junk"]}"#,
        )
        .unwrap();
        assert_eq!(cmd.device_indices, Some(vec![0, 3]));
        assert_eq!(cmd.time_sec, 3.0);
        assert_eq!(cmd.loop_on, 1.0);
        assert_eq!(cmd.loop_off, 0.5);
        assert!(cmd.levels.is_some());
    }

    #[test]
    fn toy_string_and_absent() {
        let one = parse_command(r#"{"command":"Function","action":"Stop","toy":"bp2"}"#).unwrap();
        assert_eq!(one.device_indices, Some(vec![2]));
        assert!(one.levels.is_none());

        let all = parse_command(r#"{"command":"Function","action":"Stop"}"#).unwrap();
        assert_eq!(all.device_indices, None);
    }

    #[test]
    fn rejects_unknown_and_bad_json() {
        assert!(parse_command(r#"{"command":"GetToys"}"#).is_err());
        assert!(parse_command("not json").is_err());
    }
}
