--[[
    dispatch.lua — The shared command dispatcher.

    mod:dispatch_hook(hook_id, scale) is the single entry point every hook
    (discrete or polled) uses to drive toys. It:
      1. Debounces on this hook's cooldown AND a global minimum gap.
      2. Groups the hook's assigned toys by preset.
      3. Builds ONE command per distinct preset (batching its toys) and sends.

    Because a Lovense Function request accepts an array of toy ids, toys that
    share a preset go out in a single request — so the request count per fire
    equals the number of distinct presets in use for the hook.
--]]

local mod = get_mod("EmperorsTouch")

local GLOBAL_MIN_GAP = 0.1    -- min seconds between ANY two dispatches
local SCALE_EPSILON  = 0.03   -- poll: skip if scale barely changed

-- Debounce / change-tracking state.
local last_fire     = {}      -- [hook_id] = clock seconds of last send
local last_scale    = {}      -- [hook_id] = last scale actually sent
local last_any_fire = -math.huge

-- Per-toy "hold" window: while now < hold_until[toy_id], continuous (poll)
-- hooks skip that toy so a timed burst (e.g. Knocked Down) isn't overwritten
-- mid-flight by the next Health/Peril poll tick. Event hooks always fire
-- regardless of holds — a burst is allowed to interrupt another burst or a
-- continuous hook, it just also claims the toy for its own duration.
local hold_until = {}

-- Poll hooks that skipped a held toy. While set, the epsilon check is
-- bypassed so the hook re-sends its level as soon as the hold expires —
-- otherwise the toy would sit silent after the burst until the value
-- happened to move more than SCALE_EPSILON.
local pending_reassert = {}

-- Monotonic clock for debounce. Prefers the always-running "main" timer.
function mod:clock()
    local tm = Managers.time
    if tm then
        if tm:has_timer("main")     then return tm:time("main")     end
        if tm:has_timer("gameplay") then return tm:time("gameplay") end
    end
    return 0
end

-- Set of currently-connected toy ids, for filtering stale assignments.
local function connected_ids()
    local set = {}
    for _, toy in ipairs(mod.toys or {}) do
        if toy.id then set[toy.id] = true end
    end
    return set
end

-- hook_id : registry id
-- scale   : 0..1 multiplier for poll hooks; nil/1 for discrete (full strength)
function mod:dispatch_hook(hook_id, scale)
    local hook = mod.HOOKS_BY_ID and mod.HOOKS_BY_ID[hook_id]
    if not hook then return end

    local now = mod:clock()

    -- Per-hook cooldown
    if now - (last_fire[hook_id] or -math.huge) < (hook.cooldown or 0) then
        return
    end
    -- Global minimum gap applies to poll traffic only. Event hooks are
    -- exempt: they are rare, cooldown-protected, and fire exactly once per
    -- trigger — dropping one here loses it entirely (e.g. an overload burst
    -- always lands right after the peril poll that just sent 100%).
    if hook.kind == "poll" and now - last_any_fire < GLOBAL_MIN_GAP then
        return
    end
    -- Poll change-threshold: skip near-identical intensities (unless a
    -- hold ended and this hook still owes its toys a re-assert)
    if scale ~= nil and last_scale[hook_id] ~= nil and not pending_reassert[hook_id] then
        if math.abs(scale - last_scale[hook_id]) < SCALE_EPSILON then
            return
        end
    end

    local presets     = mod:get_presets()
    local assignments = mod:get_assignments()
    local hook_assign = assignments[hook_id]
    if not hook_assign then return end

    local inversions = mod:get_inversions()
    local hook_inv   = inversions[hook_id] or {}

    -- Group connected, assigned toys by preset id + inversion flag, since
    -- inverted toys get a different scale and need their own request.
    -- Poll (continuous) hooks skip any toy currently held by a burst.
    local live = connected_ids()
    local skipped_held = false
    local groups = {}   -- [key] = { preset_id, inverted, toy_ids }
    for toy_id, preset_id in pairs(hook_assign) do
        if preset_id and live[toy_id] and presets[preset_id] then
            if hook.kind == "poll" and (hold_until[toy_id] or 0) > now then
                skipped_held = true
            else
                local inverted = hook_inv[toy_id] and true or false
                local key = preset_id .. (inverted and "|inv" or "")
                local group = groups[key]
                if not group then
                    group = { preset_id = preset_id, inverted = inverted, toy_ids = {} }
                    groups[key] = group
                end
                group.toy_ids[#group.toy_ids + 1] = toy_id
            end
        end
    end

    -- Track the re-assert debt: set while any toy is held, cleared once a
    -- dispatch reaches every assigned toy again.
    if hook.kind == "poll" then
        pending_reassert[hook_id] = skipped_held or nil
    end

    -- One request per distinct preset+inversion, batching its toys
    local sent = 0
    for _, group in pairs(groups) do
        local p = presets[group.preset_id]
        local effective_scale = scale
        if scale ~= nil and group.inverted then
            effective_scale = 1 - scale
        end
        local cmd = mod:make_toy_command({
            actions  = mod:scale_actions(p.actions, effective_scale),
            duration = p.duration,
            loop_on  = p.loop_on,
            loop_off = p.loop_off,
            toy      = group.toy_ids,
            -- Bursts interrupt (stopPrevious 1): hardware ignores a new
            -- command while an old one runs, so without this a newer event
            -- is hidden by an older burst still playing. Continuous stays
            -- at 0 so ramp steps don't stop-restart; the per-toy hold +
            -- re-assert handles resuming continuous after a burst.
            stop_previous = hook.kind ~= "poll",
        })
        mod:send_toy_command(cmd)
        sent = sent + 1

        -- A timed, non-continuous burst claims its toys for its duration.
        -- The newest burst's window REPLACES any existing hold (it also
        -- interrupted the previous burst via stopPrevious), so continuous
        -- output resumes as soon as the currently-playing burst ends.
        if hook.kind ~= "poll" and p.duration and p.duration > 0 then
            local until_t = now + p.duration
            for _, toy_id in ipairs(group.toy_ids) do
                hold_until[toy_id] = until_t
            end
        end
    end

    if sent > 0 then
        last_fire[hook_id] = now
        last_any_fire      = now
        last_scale[hook_id] = scale
    end
end

-- Zeroes this hook's output: sends its assigned presets at zero intensity
-- to the assigned toys. Deliberately NOT a blanket "Stop" — only the
-- actions this hook's presets drive are zeroed, so other hooks running on
-- the same toy are unaffected. No-op if the hook has nothing active.
function mod:stop_hook(hook_id)
    if last_scale[hook_id] == nil then
        return
    end
    last_scale[hook_id] = nil

    local presets     = mod:get_presets()
    local assignments = mod:get_assignments()
    local hook_assign = assignments[hook_id]
    if not hook_assign then return end

    local live = connected_ids()
    local by_preset = {}
    for toy_id, preset_id in pairs(hook_assign) do
        if preset_id and live[toy_id] and presets[preset_id] then
            by_preset[preset_id] = by_preset[preset_id] or {}
            table.insert(by_preset[preset_id], toy_id)
        end
    end

    for preset_id, toy_ids in pairs(by_preset) do
        local p = presets[preset_id]
        mod:send_toy_command(mod:make_toy_command({
            actions  = mod:scale_actions(p.actions, 0),
            duration = 0,
            toy      = toy_ids,
        }))
    end
end

-- Clears debounce/change-tracking state, so the first dispatch of the next
-- mission always sends. Called on mission end.
function mod:reset_dispatch()
    table.clear(last_fire)
    table.clear(last_scale)
    table.clear(hold_until)
    table.clear(pending_reassert)
    last_any_fire = -math.huge
end
