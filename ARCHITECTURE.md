# Event-to-Device Dispatch Architecture

A game/language-agnostic description of the trigger → arbitration →
command-building pipeline. Given (a) a host that can raise discrete events
and be polled every frame/tick, and (b) fire-and-forget output devices
reachable over a request/response API, this document is sufficient to
rebuild the system.

## Device model (the constraints everything else exists to handle)

The design assumes devices with these properties (true of Lovense hardware,
and a safe worst-case assumption generally):

1. **Fire-and-forget commands.** A command sets one or more *actions*
   (channels) to an intensity, optionally for a fixed duration, optionally
   with an on/off loop pattern. There is no acknowledgement of completion
   and no way to query what is currently running.
2. **New commands replace running ones.** A device executes one command per
   action at a time. Sending a new command on the same action always
   replaces the running one — any "don't interrupt" flag the API offers may
   be a no-op on real hardware. Do not trust it.
3. **Interrupted commands do not resume.** If a 3-second burst is cut off
   after 1 second by another command, the remaining 2 seconds are gone.
   When that second command ends, the device goes silent — nothing resumes
   automatically.
4. **The connection layer lies.** The device-list endpoint may include
   previously-paired devices that are no longer connected; commanding those
   returns an error. Field types/presence in the device list vary by
   client version (numbers vs strings, optional fields) — normalize on
   ingestion.

Consequences: **all arbitration must live on our side** (the device cannot
mediate between competing sources), and every "resume after interruption"
behavior must be explicitly re-sent by us.

## Layer 1 — Source registry

Every stimulus is a *hook*: a descriptor in a single registry table. Two
kinds:

- **Event hooks** (discrete): "player took damage", "boss spawned". Wired
  once at startup to whatever host mechanism observes the trigger. On
  trigger they call `dispatch(hook_id)` — full intensity, exactly once.
- **Poll hooks** (continuous): "health level", "proximity to X". A function
  sampled on an interval that returns a normalized scale in `[0, 1]`, or
  `nil`/none when the source is unavailable. The driver calls
  `dispatch(hook_id, scale)` each sample.

Descriptor fields: `id` (stable string — this is the **persistence key**
for user configuration; renaming it orphans saved assignments), display
name, `kind` (event/poll), `cooldown` seconds, and for polls the sampling
interval and the sampler function.

Design rule: adding a new hook touches *only* the registry (plus, for
events, one wiring line). Configuration UI, persistence, and dispatch all
iterate the registry generically.

Poll lifecycle detail: if a poll sampler returns "unavailable" N
consecutive times (N=3), send an explicit stop for that hook — otherwise
the device holds its last level forever when the source disappears (death,
level transition). Also send a global stop + state reset when the host
session ends.

## Layer 2 — User configuration model

Three persisted structures, all keyed by stable ids:

- **Presets**: named bundles of `{action → intensity}` plus `duration`,
  `loop_on`, `loop_off`. Intensities are stored in device-native units.
- **Assignments**: `assignments[hook_id][device_id] = preset_id`. The full
  cross product of hooks × devices, sparse.
- **Inversions**: `inversions[hook_id][device_id] = true` — for poll hooks,
  this device receives `1 - scale` instead of `scale`.

This shape is the key extensibility decision: any device can respond to
any hook with any preset, independently, and new hooks/devices need no
schema change.

## Layer 3 — Dispatcher (the arbitration core)

Single entry point: `dispatch(hook_id, scale)` where `scale` is `nil` for
events (meaning full strength) or `[0,1]` for polls. State kept:
`last_fire[hook_id]`, `last_scale[hook_id]` (last scale **actually sent**,
not last observed), `last_any_fire`, `hold_until[device_id]`,
`pending_reassert[hook_id]`.

Gates, in order — return early if any fails:

1. **Per-hook cooldown**: `now - last_fire[hook_id] < cooldown` → drop.
2. **Global minimum gap, polls only** (~0.1 s between any two dispatches).
   Events are **exempt**: they are rare, cooldown-protected, and dropping
   one loses it forever. (Real bug: an "overload" event always fired
   immediately after the poll tick that had just sent 100%, so a blanket
   global gap silently ate every overload burst.)
3. **Change epsilon, polls only** (~3% of full scale vs `last_scale`):
   skip near-identical intensities. Bypassed while the hook has a
   `pending_reassert` debt (see below).

Then build the send set:

4. **Resolve targets**: for each `(device, preset)` in this hook's
   assignments, keep only devices that are *currently connected* (filter
   the cached device list by its live-status field — stale entries error
   when commanded).
5. **Hold check, polls only**: skip any device whose `hold_until` is in the
   future — a timed event burst owns it. If any device was skipped, set
   `pending_reassert[hook_id]`; once a dispatch reaches every assigned
   device again, clear it. The debt makes the poll re-send its current
   level immediately after the hold expires even if the value hasn't moved
   past the epsilon — without it the device sits silent after a burst
   (constraint 3: hardware doesn't resume).
   Event hooks ignore holds entirely: a burst may interrupt another burst
   or a continuous level; it just also claims the device for itself.
6. **Group** remaining devices by `(preset_id, inverted?)`. Each group
   becomes one batched request (the API accepts an array of device ids).
   Inverted devices need a separate group because their intensity differs.

Send, per group:

7. Scale the preset's actions by the effective scale (inverted →
   `1 - scale`), build one command (Layer 4), send. Set the
   "interrupt/replace" flag for **events only** — for polls it must be
   off so ramp steps don't stop-restart the device between samples (even
   where the flag is a hardware no-op, keep the intent explicit for
   clients where it isn't).
8. **Batch fallback**: if a multi-device (array) request fails, retry as
   one request per device — some client versions reject the array form.
9. **Claim holds**: for an event with `duration > 0`, set
   `hold_until[device] = now + duration` for every device in the group.
   The newest burst's window **replaces** any existing hold (it also
   physically replaced the previous burst per constraint 2) — taking the
   max instead leaves the device silent after the new burst ends.
10. On any successful send, update `last_fire`, `last_any_fire`, and
    `last_scale[hook_id] = scale`.

Two auxiliary operations:

- `stop_hook(hook_id)`: zero **only this hook's** output — re-send its
  assigned presets at zero intensity to its assigned devices. Deliberately
  not a device-wide stop, so other hooks driving the same device are
  untouched. No-op unless the hook has previously sent (guard on
  `last_scale`).
- `reset()`: clear all dispatcher state (so the next session's first
  dispatch always sends) and issue a global device stop. Called at session
  end. Also expose a user-facing panic control that stops everything.

## Layer 4 — Command builder

Pure functions, no state:

- `scale_actions(actions, scale)`: multiply each action's stored intensity
  by scale, round to the device's integer steps, clamp to a per-action
  maximum table (different actions have different ranges, e.g. 0–20 vs
  0–3 vs 0–100).
- `make_command(opts)`: assemble the wire payload — action string/map,
  duration, loop on/off times, target device id(s) (scalar or array),
  interrupt flag. Normalize here so the dispatcher never touches wire
  format.
- `send_command(cmd, on_done)`: async transport with a completion callback
  `(ok, err)`. Parse the API's envelope quirks in one place (status codes
  inside the body regardless of HTTP status, double-encoded payload
  fields, content-type strictness). Error reporting is throttled
  (identical user-visible errors at most once per ~10 s) with full detail
  behind a debug-logging switch.

## Rebuild checklist

1. Device client: list-devices (with connected-status normalization and
   caching), send-command, stop; envelope parsing and throttled errors.
2. Command builder: per-action max table, scaling, payload assembly.
3. Registry + drivers: event wiring, poll loop with per-hook intervals and
   the nil-streak auto-stop.
4. Dispatcher: the ten steps above, in order — the ordering of gates and
   the poll/event asymmetries (gap exemption, hold immunity,
   interrupt-flag) are each load-bearing.
5. Config model: presets / assignments / inversions keyed by stable ids;
   UI generated from the registry.
6. Session teardown: reset + stop on exit; panic stop control.
