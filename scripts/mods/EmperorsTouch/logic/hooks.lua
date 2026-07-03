--[[
    hooks.lua — Hook registry + game event wiring.

    A "hook" is a named source of intensity. Two kinds:
      * event — fired by a game hook (discrete). Calls mod:dispatch_hook(id).
      * poll  — evaluated on mod.update at `interval`. Its poll() returns a
                scale in 0..1 (or nil to skip); dispatch scales the preset by it.

    Adding a hook:
      1. Add a descriptor to HOOKS below.
      2. For an event hook, wire a mod:hook_safe that calls mod:dispatch_hook(id).
         For a poll hook, give it a poll() function.
    Nothing in dispatch.lua needs to change.
--]]

local mod = get_mod("EmperorsTouch")

local ScriptUnit = mod:original_require("scripts/foundation/utilities/script_unit")

-- ===== Shared helpers =====

-- NOTE: use local_player_safe, not local_player. local_player calls
-- Network.peer_id() unguarded, which access-violates during boot before
-- the connection manager is initialized (and pcall cannot catch it).
local function local_player_unit()
    local player = Managers.player and Managers.player:local_player_safe(1)
    return player and player.player_unit
end

-- Returns the local player's health fraction (0..1), or nil if unavailable.
local function local_health_fraction()
    local unit = local_player_unit()
    if not unit then return nil end
    local ok, frac = pcall(function()
        local ext = ScriptUnit.has_extension(unit, "health_system")
        return ext and ext:current_health_percent()
    end)
    if ok and frac then return frac end
    return nil
end

local function is_local_player(unit)
    local player = Managers.player and Managers.player:local_player_safe(1)
    return player and unit == player.player_unit
end

-- ===== Registry =====
-- cooldown: minimum seconds between this hook's own dispatches.
-- interval (poll only): seconds between poll() evaluations.

local HOOKS = {
    {
        id       = "on_damage_taken",
        name     = "Damage Taken",
        kind     = "event",
        cooldown = 0.4,
    },
    {
        id       = "health_pct",
        name     = "Health Level (Continuous)",
        kind     = "poll",
        interval = 0.25,
        cooldown = 0.1,
        -- Full strength at full health, off when downed. Invert in a future
        -- preset option if "stronger when hurt" is wanted.
        poll     = function() return local_health_fraction() end,
    },
    {
        id       = "on_victory",
        name     = "Mission Victory",
        kind     = "event",
        cooldown = 10,
    },
    {
        id       = "on_defeat",
        name     = "Mission Defeat",
        kind     = "event",
        cooldown = 10,
    },
}

local HOOKS_BY_ID = {}
for _, h in ipairs(HOOKS) do
    HOOKS_BY_ID[h.id] = h
end

mod.HOOKS        = HOOKS
mod.HOOKS_BY_ID  = HOOKS_BY_ID

-- List of poll-kind hooks, consumed by the update loop.
mod.POLL_HOOKS = {}
for _, h in ipairs(HOOKS) do
    if h.kind == "poll" then
        mod.POLL_HOOKS[#mod.POLL_HOOKS + 1] = h
    end
end

-- ===== Discrete event wiring =====
-- Each game hook simply calls mod:dispatch_hook(id); dispatch handles
-- debounce, grouping, and sending.

-- hook_safe callbacks receive the original arguments directly (no `func`
-- first parameter — that is only for mod:hook).
mod:hook_safe(CLASS.AttackReportManager, "add_attack_result", function(self, damage_profile, attacked_unit, attacking_unit, ...)
    local ok, hit_me = pcall(is_local_player, attacked_unit)
    if ok and hit_me then
        mod:dispatch_hook("on_damage_taken")
    end
end)

-- Mission outcome. _set_end_conditions_met runs on the server directly and
-- on clients via rpc_game_mode_end_conditions_met, so hooking the method
-- itself covers both host and client. Outcomes: "won" | "lost" | "n/a".
mod:hook_safe(CLASS.GameModeManager, "_set_end_conditions_met", function(self, outcome)
    if outcome == "won" then
        mod:dispatch_hook("on_victory")
    elseif outcome == "lost" then
        mod:dispatch_hook("on_defeat")
    end
end)

-- Leaving the mission state: halt everything so a Duration=0 (continuous)
-- preset can't keep running into the end screen / hub, and reset dispatch
-- debounce state for the next mission.
mod:hook_safe(CLASS.StateGameplay, "on_exit", function()
    mod:reset_dispatch()
    mod:send_toy_command(mod:make_stop_command())
end)
