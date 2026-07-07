local mod = get_mod("EmperorsTouch")

mod:io_dofile("EmperorsTouch/scripts/mods/EmperorsTouch/libs/json")

local VIEW_NAME = "emperors_touch_view"

-- Both ports are fixed: Lovense Remote always serves on 30010, and the
-- bridge always listens on 20010 (bridge/bridge.py matches).
local function lovense_url()
    if mod:get("backend") == "bridge" then
        return "http://localhost:20010/command"
    end
    return "https://127-0-0-1.lovense.club:30010/command"
end

local function register_view()
    mod:add_require_path("EmperorsTouch/scripts/mods/EmperorsTouch/view/emperors_touch_view")
    mod:add_require_path("EmperorsTouch/scripts/mods/EmperorsTouch/view/emperors_touch_view_definitions")
    mod:add_require_path("EmperorsTouch/scripts/mods/EmperorsTouch/view/emperors_touch_view_blueprints")
    mod:add_require_path("EmperorsTouch/scripts/mods/EmperorsTouch/view/emperors_touch_view_settings")

    mod:register_view({
        view_name = VIEW_NAME,
        view_settings = {
            init_view_function = function(_) return true end,
            class               = "EmperorsTouchView",
            disable_game_world  = false,
            display_name        = "Emperor's Touch",
            game_world_blur     = 1.1,
            load_always         = true,
            load_in_hub         = true,
            package             = "packages/ui/views/options_view/options_view",
            path                = "EmperorsTouch/scripts/mods/EmperorsTouch/view/emperors_touch_view",
            state_bound         = true,
            enter_sound_events  = { "wwise/events/ui/play_ui_enter_short" },
            exit_sound_events   = { "wwise/events/ui/play_ui_back_short" },
            wwise_states        = { options = "ingame_menu" },
        },
        view_transitions = {},
        view_options = {
            close_all             = true,
            close_previous        = true,
            close_transition_time = nil,
            transition_time       = nil,
        },
    })
    mod:io_dofile("EmperorsTouch/scripts/mods/EmperorsTouch/view/emperors_touch_view")
end

register_view()

local PRESET_EDITOR_VIEW_NAME = "emperors_touch_preset_editor"

local function register_preset_editor_view()
    local base = "EmperorsTouch/scripts/mods/EmperorsTouch/view/preset_editor_view"
    mod:add_require_path(base)
    mod:add_require_path(base .. "_definitions")
    mod:add_require_path(base .. "_blueprints")
    mod:add_require_path(base .. "_settings")

    mod:register_view({
        view_name = PRESET_EDITOR_VIEW_NAME,
        view_settings = {
            init_view_function = function(_) return true end,
            class               = "PresetEditorView",
            disable_game_world  = false,
            display_name        = "Emperor's Touch Presets",
            game_world_blur     = 1.1,
            load_always         = true,
            load_in_hub         = true,
            package             = "packages/ui/views/options_view/options_view",
            path                = base,
            state_bound         = true,
            enter_sound_events  = { "wwise/events/ui/play_ui_enter_short" },
            exit_sound_events   = { "wwise/events/ui/play_ui_back_short" },
            wwise_states        = { options = "ingame_menu" },
        },
        view_transitions = {},
        view_options = {
            close_all             = true,
            close_previous        = true,
            close_transition_time = nil,
            transition_time       = nil,
        },
    })
    mod:io_dofile(base)
end

register_preset_editor_view()

-- ===== Lovense API =====

-- Sends a command table to the Lovense API. on_done(body, err) is called
-- with the decoded response body, or nil + error message.
function mod:send_command(command_table, on_done)
    Managers.backend:url_request(lovense_url(), {
        method = "POST",
        body   = command_table,
    }):next(function(result)
        on_done(result and result.body, nil)
    end):catch(function(err)
        on_done(nil, err and err.description or tostring(err))
    end)
end

-- Most recent toy list, as an array of:
-- { id, name, nickName, battery, status, version }
-- Refreshed every time get_toys succeeds.
mod.toys = {}

-- Queries connected toys. on_done(toys, err) receives the same array
-- that is stored on mod.toys.
function mod:get_toys(on_done)
    mod:send_command({ command = "GetToys" }, function(body, err)
        if err then
            on_done(nil, err)
            return
        end
        -- "Reachable but no toys paired" is an empty list, not an error.
        -- Lovense Remote (PC) answers code 402; Lovense Connect (phone)
        -- answers code 404.
        if body and (body.code == 402 or body.code == 404) then
            mod.toys = {}
            on_done(mod.toys, nil)
            return
        end
        if not body or body.code ~= 200 then
            on_done(nil, "Lovense returned code " .. tostring(body and body.code))
            return
        end
        -- The toys field is a JSON string inside the JSON response
        local toys_str = body.data and body.data.toys
        if not toys_str or toys_str == "" then
            mod.toys = {}
            on_done(mod.toys, nil)
            return
        end
        local toys_by_id, decode_err = mod.json.decode(toys_str)
        if not toys_by_id then
            on_done(nil, "Failed to decode toys: " .. tostring(decode_err))
            return
        end

        local toys = {}
        for id, toy in pairs(toys_by_id) do
            toy.id = toy.id or id
            toys[#toys + 1] = toy
        end
        table.sort(toys, function(a, b) return (a.name or "") < (b.name or "") end)

        mod.toys = toys
        on_done(toys, nil)
    end)
end

-- ===== Toy commands =====

-- Max strength per action, used for clamping.
local ACTION_MAX = {
    Vibrate   = 20,
    Rotate    = 20,
    Pump      = 3,
    Thrusting = 20,
    Fingering = 20,
    Suction   = 20,
    Depth     = 3,
    Stroke    = 100,
    Oscillate = 20,
}

-- Returns a copy of an actions table with each strength multiplied by scale
-- and clamped to that action's valid range. scale defaults to 1.
function mod:scale_actions(actions, scale)
    scale = scale or 1
    local out = {}
    for action, strength in pairs(actions or {}) do
        local max = ACTION_MAX[action] or 20
        local v = math.floor(strength * scale + 0.5)
        out[action] = math.max(0, math.min(max, v))
    end
    return out
end

-- Normalizes opts.toy into a list of id strings. Accepts:
--   nil                       -> {} (all toys)
--   "id"                      -> { "id" }
--   toy struct { id = ... }   -> { "id" }
--   array of ids/structs      -> { "id1", "id2", ... }
local function resolve_toy_ids(toy)
    if toy == nil then return {} end
    if type(toy) == "string" then return { toy } end
    if type(toy) == "table" then
        if toy[1] ~= nil then
            local ids = {}
            for _, entry in ipairs(toy) do
                local id = type(entry) == "table" and entry.id or entry
                if id then ids[#ids + 1] = id end
            end
            return ids
        end
        if toy.id then return { toy.id } end
    end
    return {}
end

-- Factory: builds a command structure for the Lovense "Function" API.
--
-- opts:
--   actions  (required) table of action -> strength, e.g.
--            { Vibrate = 10 }  or  { Vibrate = 15, Rotate = 5 }
--            Ranges: Vibrate/Rotate 0-20, Pump 0-3. 0 stops that action.
--   duration (optional) seconds to run; 0 or nil = run until stopped
--   toy      (optional) toy id string, toy struct, or an array of either;
--            nil/empty = all toys
--   loop_on  (optional) seconds running per cycle
--   loop_off (optional) seconds paused per cycle
--
-- Returns a structure for mod:send_toy_command.
function mod:make_toy_command(opts)
    local parts = {}
    for action, strength in pairs(opts.actions or {}) do
        parts[#parts + 1] = string.format("%s:%d", action, strength)
    end

    -- stopPrevious semantics (verified on hardware):
    --   1 (API default) = kill everything running, then apply. Right for
    --     event bursts and stops; wrong for ramps (stutters every step).
    --   0 = apply without stopping what's running. Right for continuous
    --     ramp updates; wrong for bursts (the running command wins and the
    --     burst never manifests).
    -- Dispatch coordinates the two: bursts pass stop_previous = true and
    -- continuous updates are held back per-toy while a burst is running.
    local cmd = {
        command = "Function",
        action  = table.concat(parts, ","),
        timeSec = opts.duration or 0,
        apiVer  = 1,
        stopPrevious = opts.stop_previous and 1 or 0,
    }

    local ids = resolve_toy_ids(opts.toy)
    if #ids == 1 then
        cmd.toy = ids[1]
    elseif #ids > 1 then
        cmd.toy = ids   -- array form (Lovense Remote v7.71.0+)
    end

    if opts.loop_on  then cmd.loopRunningSec = opts.loop_on  end
    if opts.loop_off then cmd.loopPauseSec   = opts.loop_off end

    return cmd
end

-- Convenience factory for stopping: all actions on one toy, or everything.
-- Uses the API's dedicated "Stop" action, which halts every function.
function mod:make_stop_command(toy)
    local cmd = mod:make_toy_command({ actions = {}, toy = toy, stop_previous = true })
    cmd.action = "Stop"
    return cmd
end

-- Sends a command produced by make_toy_command. on_done(ok, err) is
-- optional; ok is true when the app reports success.
function mod:send_toy_command(cmd, on_done)
    mod:send_command(cmd, function(body, err)
        local ok = not err and body and body.code == 200
        if not ok and not err then
            err = "Lovense returned code " .. tostring(body and body.code)
        end
        if on_done then
            on_done(ok, err)
        elseif err then
            mod:echo("Toy command failed: " .. tostring(err))
        end
    end)
end

-- ===== Presets & assignments (persisted) =====

-- presets: { [preset_id] = { name, actions = { Vibrate = n, ... },
--                            duration, loop_on, loop_off } }
function mod:get_presets()
    return mod:get("presets") or {}
end

function mod:set_presets(presets)
    mod:set("presets", presets)
end

-- assignments: { [hook_id] = { [toy_id] = preset_id } }
function mod:get_assignments()
    return mod:get("assignments") or {}
end

function mod:set_assignments(assignments)
    mod:set("assignments", assignments)
end

-- Sets (or clears, with preset_id = nil) the preset for a hook+toy pair.
function mod:assign_preset(hook_id, toy_id, preset_id)
    local a = mod:get_assignments()
    a[hook_id] = a[hook_id] or {}
    a[hook_id][toy_id] = preset_id
    mod:set_assignments(a)
end

-- inversions: { [hook_id] = { [toy_id] = true } }
-- When set for a poll hook, the intensity scale is flipped (1 - scale),
-- e.g. Health Level becomes "stronger when hurt".
function mod:get_inversions()
    return mod:get("inversions") or {}
end

function mod:set_inverted(hook_id, toy_id, inverted)
    local inv = mod:get_inversions()
    inv[hook_id] = inv[hook_id] or {}
    inv[hook_id][toy_id] = inverted and true or nil
    mod:set("inversions", inv)
end

-- ===== Load hook logic =====

mod:io_dofile("EmperorsTouch/scripts/mods/EmperorsTouch/logic/dispatch")
mod:io_dofile("EmperorsTouch/scripts/mods/EmperorsTouch/logic/hooks")

-- ===== Poll loop for continuous hooks =====

local last_poll  = {}   -- [hook_id] = clock seconds of last poll
local nil_polls  = {}   -- [hook_id] = consecutive polls that returned nil

-- After this many consecutive nil polls the hook's output is zeroed, so a
-- vanished source (death, overload, leaving Psyker gameplay) can't leave a
-- toy stuck at its last intensity.
local NIL_POLLS_BEFORE_STOP = 3

-- Auto-query toys on game launch so hooks work without opening the menu
-- first. Retries because the backend/Lovense app may not be up yet.
local toys_bootstrap = {
    done         = false,
    attempts     = 0,
    max_attempts = 5,
    next_try     = 0,
    retry_delay  = 10,
    in_flight    = false,
}

local function bootstrap_toys(now)
    if toys_bootstrap.done or toys_bootstrap.in_flight or now < toys_bootstrap.next_try then
        return
    end

    toys_bootstrap.attempts  = toys_bootstrap.attempts + 1
    toys_bootstrap.next_try  = now + toys_bootstrap.retry_delay
    toys_bootstrap.in_flight = true

    mod:get_toys(function(toys, err)
        toys_bootstrap.in_flight = false
        if not err then
            -- Success (even with zero toys paired): the app answered.
            toys_bootstrap.done = true
        elseif toys_bootstrap.attempts >= toys_bootstrap.max_attempts then
            toys_bootstrap.done = true   -- give up quietly; Get Toys still works
        end
    end)
end

function mod.update(dt)
    local now = mod:clock()

    bootstrap_toys(now)

    for _, hook in ipairs(mod.POLL_HOOKS or {}) do
        local interval = hook.interval or 0.25
        if now - (last_poll[hook.id] or -math.huge) >= interval then
            last_poll[hook.id] = now
            local ok, scale = pcall(hook.poll)
            if ok and scale ~= nil then
                nil_polls[hook.id] = 0
                mod:dispatch_hook(hook.id, scale)
            else
                local n = (nil_polls[hook.id] or 0) + 1
                nil_polls[hook.id] = n
                if n == NIL_POLLS_BEFORE_STOP then
                    mod:stop_hook(hook.id)
                end
            end
        end
    end
end

-- ===== Stop-all keybind =====

-- Stops every action on all connected toys (no toy field = all toys).
mod.emperors_touch_stop_all = function(self)
    mod:send_toy_command(mod:make_stop_command(), function(ok, err)
        if ok then
            mod:echo("All toys stopped.")
        else
            mod:echo("Stop failed: " .. tostring(err))
        end
    end)
end

-- https://dmf-docs.darkti.de
