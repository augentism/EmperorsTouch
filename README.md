# Emperor's Touch

Lovense integration for Warhammer 40,000: Darktide. Game events (taking
damage, mission outcome) and polled game state (health) drive toy commands
through the Lovense Remote local HTTP API.

## Architecture at a glance

```
game event / poll tick
        │
        ▼
logic/hooks.lua      -- hook registry + game wiring; calls mod:dispatch_hook(id, scale)
        │
        ▼
logic/dispatch.lua   -- debounce, group assigned toys by preset, batch commands
        │
        ▼
EmperorsTouch.lua    -- make_toy_command / send_toy_command → backend transport
                        (Lovense HTTP API, et_native.dll FFI, or bridge HTTP)
```

Users create **presets** (action strengths + timing) in the preset editor
view, then assign a preset to each **hook × toy** pair in the toys view.
Both are persisted via DMF settings (`user_settings.config`).

## Adding a new hook

Everything lives in `scripts/mods/EmperorsTouch/logic/hooks.lua`. The UI
(toys view dropdown panel) and the dispatcher are registry-driven, so **no
other file needs to change**.

### 1. Decide the kind

| Kind    | Use for                                | Fires via                              |
|---------|----------------------------------------|----------------------------------------|
| `event` | Discrete moments (took damage, won)     | a `mod:hook_safe` you write             |
| `poll`  | Continuous state (health %, peril %)    | a `poll()` function, called on a timer  |

### 2. Add a descriptor to the `HOOKS` table

```lua
-- event kind
{
    id       = "on_dodge",          -- unique, stable; used as the persistence key
    name     = "Dodge",             -- label shown in the toys view
    kind     = "event",
    cooldown = 0.4,                 -- min seconds between dispatches of THIS hook
},

-- poll kind
{
    id       = "peril_pct",
    name     = "Peril Level",
    kind     = "poll",
    interval = 0.25,                -- seconds between poll() evaluations
    cooldown = 0.1,
    poll     = function() return get_peril_fraction() end,
},
```

Descriptor fields:

- **`id`** — unique string. This is the key assignments are saved under, so
  renaming it orphans users' saved hook→preset assignments.
- **`name`** — display name in the hook panel.
- **`kind`** — `"event"` or `"poll"`.
- **`cooldown`** — per-hook debounce in seconds. Dispatch also enforces a
  global 0.1s minimum gap between any two sends.
- **`interval`** (poll only) — how often `poll()` runs.
- **`poll`** (poll only) — returns a **scale in 0..1**, or `nil` to skip this
  tick. The scale multiplies the assigned preset's action strengths.
  Dispatch skips sends when the scale changed less than `SCALE_EPSILON`
  (3%) since the last *sent* value.

### 3. Wire it (event hooks only)

Add a `mod:hook_safe` in the "Discrete event wiring" section that calls
`mod:dispatch_hook("your_id")`:

```lua
mod:hook_safe(CLASS.SomeManager, "some_method", function(self, arg1, ...)
    if <this event is about the local player> then
        mod:dispatch_hook("on_dodge")
    end
end)
```

Poll hooks need no wiring — `mod.update` (in `EmperorsTouch.lua`) walks
`mod.POLL_HOOKS` automatically.

### 4. That's it — verify

1. Reload the mod
2. Open the toys view (default **F10**), select a toy: the new hook appears
   in the right-hand panel with a preset dropdown.
3. Assign a preset and trigger the event in-game (Psykhanium works for
   damage-style hooks).

## Conventions and sharp edges

- **Always `mod:hook_safe`, never `mod:hook`** unless you must intercept
  arguments/returns. Note the signature difference: `hook_safe` callbacks
  receive the original arguments directly, `mod:hook` callbacks receive
  `func` first. Getting this wrong shifts every argument by one and fails
  silently.
- **Local player checks**: use the shared helpers in hooks.lua
  (`is_local_player`, `local_player_unit`). They use
  `Managers.player:local_player_safe(1)` — the unsafe `local_player(1)`
  access-violates during boot, and `pcall` cannot catch it.
- **Continuous vs burst presets**: for poll hooks users should set preset
  Duration to 0 (run until replaced); dispatch re-sends on change and a
  `StateGameplay.on_exit` hook stops all toys at mission end. Event hooks
  pair better with a short nonzero Duration.
- **Mission-end reset**: `mod:reset_dispatch()` clears debounce state on
  mission exit. If your hook keeps its own state, reset it there too.
- **Testing without a device**: set the Toy Backend to
  "Intiface / buttplug.io (native)" and add a virtual device in Intiface
  Central — commands are visible in its device panel. (The Lovense Connect
  phone app can also simulate toys, via the bridge's relay mode.)

## Backends

The `backend` setting picks the transport inside `mod:send_command`; the
hooks/dispatch layers are transport-agnostic.

- **lovense_remote** (default): HTTP to Lovense Remote on this PC
  (`https://127-0-0-1.lovense.club:30010/command`, port fixed by the app).
- **native**: LuaJIT FFI to `bin/et_native.dll`, an in-process buttplug.io
  client (official `buttplug` Rust crate) talking to Intiface Central's
  websocket (`ws://127.0.0.1:12345` by default; the `/et_ws_url` chat
  command overrides it). The DLL emulates Lovense timeSec/loop semantics on
  a background tokio thread; glue lives in `logic/native_backend.lua`, Rust
  source in `et-native/`. Rebuild with `pwsh et-native/build.ps1` (runs
  tests, stages the DLL into `bin/`). Toy ids are `bp<index>`, matching the
  bridge, so assignments survive switching between the two.
- **bridge**: HTTP to `bridge/bridge.py` on `localhost:20010` — kept for
  the phone-relay use case (Lovense Connect on another device).
