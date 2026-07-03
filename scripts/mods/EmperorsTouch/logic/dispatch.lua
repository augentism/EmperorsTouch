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
    -- Global minimum gap across all hooks
    if now - last_any_fire < GLOBAL_MIN_GAP then
        return
    end
    -- Poll change-threshold: skip near-identical intensities
    if scale ~= nil and last_scale[hook_id] ~= nil then
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
    local live = connected_ids()
    local groups = {}   -- [key] = { preset_id, inverted, toy_ids }
    for toy_id, preset_id in pairs(hook_assign) do
        if preset_id and live[toy_id] and presets[preset_id] then
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
        })
        mod:send_toy_command(cmd)
        sent = sent + 1
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
    last_any_fire = -math.huge
end
