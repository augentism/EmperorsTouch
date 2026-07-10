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

-- Returns the local player's peril/warp charge fraction (0..1), or nil if
-- unavailable (not a Psyker, not in a mission). Reads the warp_charge
-- component from the unit_data extension, same as Skitarius does.
local function local_peril_fraction()
    local unit = local_player_unit()
    if not unit then return nil end
    local ok, frac = pcall(function()
        local ext = ScriptUnit.has_extension(unit, "unit_data_system")
        local warp_charge = ext and ext:read_component("warp_charge")
        return warp_charge and warp_charge.current_percentage
    end)
    if ok and frac then return frac end
    return nil
end

-- Nearest-bomber proximity: broadphase query around the player (same
-- pattern the minimap mod uses for its enemy radar), filtered to the
-- poxwalker bomber breed. Returns 1 at touch range fading to 0 at
-- BOMBER_MAX_RANGE, or nil when no bomber is in range (the nil-poll stop
-- then winds the output down).
local BOMBER_BREED     = "chaos_poxwalker_bomber"
local BOMBER_MAX_RANGE = 25
local bomber_query_results = {}

local function bomber_proximity_scale()
    local unit = local_player_unit()
    if not unit then return nil end

    local ok, scale = pcall(function()
        if not Unit.alive(unit) then return nil end

        local ext_manager = Managers.state.extension
        if not ext_manager then return nil end
        local broadphase_system = ext_manager:system("broadphase_system")
        local broadphase = broadphase_system and broadphase_system.broadphase
        if not broadphase then return nil end
        local side_system = ext_manager:system("side_system")
        local side = side_system and side_system.side_by_unit[unit]
        if not side then return nil end

        local from_pos = Unit.world_position(unit, 1)
        local enemy_side_names = side:relation_side_names("enemy")

        table.clear(bomber_query_results)
        local count = broadphase.query(broadphase, from_pos, BOMBER_MAX_RANGE, bomber_query_results, enemy_side_names)

        local closest
        for i = 1, count do
            local enemy = bomber_query_results[i]
            if Unit.alive(enemy) then
                local unit_data = ScriptUnit.has_extension(enemy, "unit_data_system")
                local breed = unit_data and unit_data:breed()
                if breed and breed.name == BOMBER_BREED then
                    local distance = Vector3.distance(from_pos, Unit.world_position(enemy, 1))
                    if not closest or distance < closest then
                        closest = distance
                    end
                end
            end
        end

        if not closest then return nil end
        return 1 - math.min(closest, BOMBER_MAX_RANGE) / BOMBER_MAX_RANGE
    end)

    if ok then return scale end
    return nil
end

-- ===== Registry =====
-- cooldown: minimum seconds between this hook's own dispatches.
-- interval (poll only): seconds between poll() evaluations.

local HOOKS = {
    {
        id       = "on_damage_taken",
        name     = "Health Damage Taken",
        kind     = "event",
        cooldown = 0.4,
    },
    {
        id       = "health_pct",
        name     = "Health Level (Continuous)",
        kind     = "poll",
        interval = 0.5,
        cooldown = 0.4,
        -- Full strength at full health, off when downed. Invert in a future
        -- preset option if "stronger when hurt" is wanted.
        poll     = function() return local_health_fraction() end,
    },
    {
        id       = "peril_pct",
        name     = "Peril Level (Continuous)",
        kind     = "poll",
        interval = 0.5,
        cooldown = 0.4,
        -- 0 at no peril, 1 at max. Non-Psykers have no warp_charge
        -- component, so poll returns nil and the hook stays idle.
        poll     = function() return local_peril_fraction() end,
    },
    {
        -- The breed is internally "chaos_poxwalker_bomber" but the unit's
        -- in-game name is Poxburster (the id stays put — it's the
        -- assignments persistence key)
        id       = "bomber_proximity",
        name     = "Poxburster Proximity (Continuous)",
        kind     = "poll",
        interval = 0.2,
        cooldown = 0.15,
        -- 0 at 25m, 1 point-blank; nil (wind-down) when none in range
        poll     = function() return bomber_proximity_scale() end,
    },
    {
        id       = "on_overload",
        name     = "Peril Overload",
        kind     = "event",
        cooldown = 4,   -- overload anim lasts ~4s; no double-fires
    },
    {
        id       = "on_knocked_down",
        name     = "Knocked Down",
        kind     = "event",
        cooldown = 5,
    },
    {
        id       = "on_toughness_broken",
        name     = "Toughness Broken",
        kind     = "event",
        cooldown = 2,
    },
    {
        id       = "on_grabbed_mutant",
        name     = "Grabbed by Mutant",
        kind     = "event",
        cooldown = 5,
    },
    {
        id       = "on_netted",
        name     = "Trapped by Trapper",
        kind     = "event",
        cooldown = 5,
    },
    {
        id       = "on_pounced",
        name     = "Pounced by Hound",
        kind     = "event",
        cooldown = 5,
    },
    {
        id       = "on_consumed",
        name     = "Eaten by Beast of Nurgle",
        kind     = "event",
        cooldown = 5,
    },
    {
        id       = "on_grabbed_spawn",
        name     = "Grabbed by Chaos Spawn",
        kind     = "event",
        cooldown = 5,
    },
    {
        id       = "on_boss_spawn",
        name     = "Boss Spawned",
        kind     = "event",
        cooldown = 10,
    },
    {
        id       = "on_backstab_warning",
        name     = "Backstab Warning",
        kind     = "event",
        cooldown = 2,
    },
    {
        id       = "on_game_enter",
        name     = "Mission Start",
        kind     = "event",
        cooldown = 30,
    },
    {
        id       = "on_elite_kill",
        name     = "Elite Killed",
        kind     = "event",
        cooldown = 0.5,
    },
    {
        id       = "on_death",
        name     = "Player Death",
        kind     = "event",
        cooldown = 10,
    },
    {
        id       = "on_ability_used",
        name     = "Ability Used",
        kind     = "event",
        cooldown = 1,
    },
    {
        id       = "on_cheer",
        name     = "For the Emperor! (You)",
        kind     = "event",
        cooldown = 1,
    },
    {
        id       = "on_ally_cheer",
        name     = "For the Emperor! (Ally)",
        kind     = "event",
        cooldown = 1,
    },
    {
        id       = "on_hack_complete",
        name     = "Hacking Complete",
        kind     = "event",
        cooldown = 5,
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
-- Elite kills (attacker == me, target died with the elite/special breed
-- tag) come from the attack report. NOTE: the attack report is NOT used
-- for damage taken — minion→player hits don't reliably pass through it
-- (scoreboard reads the husk health extension for the same reason).
-- Health damage taken is detected by watching the health fraction drop
-- (see the per-frame watcher below).
mod:hook_safe(CLASS.AttackReportManager, "add_attack_result", function(self, damage_profile, attacked_unit, attacking_unit, attack_direction, hit_world_position, hit_weakspot, damage, attack_result, ...)
    if attack_result == "died" then
        local ok_kill, my_elite_kill = pcall(function()
            if not is_local_player(attacking_unit) then return false end
            local unit_data = ScriptUnit.has_extension(attacked_unit, "unit_data_system")
            local breed = unit_data and unit_data:breed()
            return breed and breed.tags and (breed.tags.elite or breed.tags.special) or false
        end)
        if ok_kill and my_elite_kill then
            mod:dispatch_hook("on_elite_kill")
        end
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

-- Disabler states + death. Darktide models each as a character state (the
-- Vermintide PlayerUnitHealthExtension:_knock_down equivalent); on_enter
-- receives the affected unit; only fire for the local player.
local function state_event(state_class, my_hook_id)
    mod:hook_safe(state_class, "on_enter", function(self, unit, ...)
        local ok, is_me = pcall(is_local_player, unit)
        if ok and is_me then
            mod:dispatch_hook(my_hook_id)
        end
    end)
end

state_event(CLASS.PlayerCharacterStateKnockedDown,   "on_knocked_down")
state_event(CLASS.PlayerCharacterStateDead,          "on_death")
state_event(CLASS.PlayerCharacterStateMutantCharged, "on_grabbed_mutant")
state_event(CLASS.PlayerCharacterStateNetted,        "on_netted")
state_event(CLASS.PlayerCharacterStatePounced,       "on_pounced")
state_event(CLASS.PlayerCharacterStateConsumed,      "on_consumed")       -- Beast of Nurgle swallow
state_event(CLASS.PlayerCharacterStateGrabbed,       "on_grabbed_spawn")  -- Chaos Spawn grab

-- Boss/monster spawn: BossExtension is created on every machine when the
-- unit spawns (SpawnFeed uses the same hook), so this works as a client too.
mod:hook_safe(CLASS.BossExtension, "extensions_ready", function(self)
    local breed = self._breed
    if breed and breed.tags and breed.tags.monster then
        mod:dispatch_hook("on_boss_spawn")
    end
end)

-- Toughness break: the extension records this exact moment (toughness
-- fully depleted from a nonzero start) for the stats system.
mod:hook_safe(CLASS.PlayerUnitToughnessExtension, "_record_toughness_broken", function(self)
    local ok, is_me = pcall(is_local_player, self._unit)
    if ok and is_me then
        mod:dispatch_hook("on_toughness_broken")
    end
end)

-- Backstab warning: the game plays a warning sound when a minion attacks
-- from behind. MinionAttack is a utility table, not a class, and we need
-- the return value (true = the sound actually triggered) — hence mod:hook.
local MinionAttack = mod:original_require("scripts/utilities/minion_attack")

mod:hook(MinionAttack, "check_and_trigger_backstab_sound", function(func, attacking_unit, action_data, target_unit, ...)
    local triggered = func(attacking_unit, action_data, target_unit, ...)
    if triggered then
        local ok, is_me = pcall(is_local_player, target_unit)
        if ok and is_me then
            mod:dispatch_hook("on_backstab_warning")
        end
    end
    return triggered
end)

-- Combat ability use (a charge is consumed).
mod:hook_safe(CLASS.PlayerUnitAbilityExtension, "use_ability_charge", function(self, ability_type, ...)
    if ability_type ~= "combat_ability" then return end
    local ok, is_me = pcall(is_local_player, self._unit)
    if ok and is_me then
        mod:dispatch_hook("on_ability_used")
    end
end)

-- Hacking complete: MinigameBase.complete runs on the server directly and
-- on clients via rpc_minigame_sync_completed. Only fire when the local
-- player was the one running the minigame.
mod:hook_safe(CLASS.MinigameBase, "complete", function(self)
    local ok, is_mine = pcall(function()
        local session_id = self:player_session_id()
        local local_player = Managers.player and Managers.player:local_player_safe(1)
        return session_id ~= nil and local_player ~= nil and session_id == local_player:session_id()
    end)
    if ok and is_mine then
        mod:dispatch_hook("on_hack_complete")
    end
end)

-- Mission start (real missions only — not the hub or the Psykhanium).
mod:hook_safe(CLASS.StateGameplay, "on_enter", function(self, parent, params, ...)
    local mission_name = params and params.mission_name
    if mission_name and mission_name ~= "hub_ship" and mission_name ~= "tg_shooting_range" then
        mod:dispatch_hook("on_game_enter")
    end
end)

-- Per-frame watcher on the local player (via the player buffs HUD element,
-- same technique peril_tracker uses):
--  * Peril overload: weapon action transitions to the warp-charge explosion.
--  * Health damage taken: the health fraction dropped since last frame.
--    (The attack report stream doesn't reliably carry minion→player hits,
--    so we watch the value itself. Catches melee, ranged, and DoT alike.)
local last_action_name  = nil
local last_health_frac  = nil

mod:hook_safe(CLASS.HudElementPlayerBuffs, "_update_buffs", function(self)
    if self.__class_name ~= "HudElementPlayerBuffs" or self._filter then return end

    local player_extensions = self._parent and self._parent:player_extensions()
    local unit_data = player_extensions and player_extensions.unit_data
    if not unit_data then return end

    -- Overload detection
    local ok, current_action = pcall(function()
        return unit_data:read_component("weapon_action").current_action_name
    end)
    if ok and current_action and current_action ~= last_action_name then
        if current_action == "action_warp_charge_explode" then
            mod:dispatch_hook("on_overload")
        end
        last_action_name = current_action
    end

    -- Health-drop detection
    local health_frac = local_health_fraction()
    if health_frac then
        if last_health_frac and health_frac < last_health_frac - 0.001 then
            mod:dispatch_hook("on_damage_taken")
        end
        last_health_frac = health_frac
    else
        -- Unit gone (death, end of round): forget, so respawning at full
        -- health doesn't register as a change.
        last_health_frac = nil
    end
end)

-- "For the Emperor!" com-wheel cheer. The VO plays through this dialogue
-- system method on every machine (host directly, clients via
-- rpc_play_dialogue_event), so it catches any player's cheer; the actor
-- unit tells us whose it was. The dialogue rule itself also has a 5s
-- per-character cooldown game-side.
mod:hook_safe(CLASS.DialogueSystem, "_play_dialogue_event_implementation", function(self, go_id, is_level_unit, level_name_hash, dialogue_id, ...)
    local ok, is_cheer = pcall(function()
        return NetworkLookup.dialogue_names[dialogue_id] == "com_wheel_vo_for_the_emperor"
    end)
    if not ok or not is_cheer then return end

    local ok_unit, unit = pcall(function()
        return Managers.state.unit_spawner:unit(go_id, is_level_unit, level_name_hash)
    end)
    if not ok_unit or not unit then return end

    local ok_me, is_me = pcall(is_local_player, unit)
    if ok_me and is_me then
        mod:dispatch_hook("on_cheer")
    else
        mod:dispatch_hook("on_ally_cheer")
    end
end)

-- Leaving the mission state: halt everything so a Duration=0 (continuous)
-- preset can't keep running into the end screen / hub, and reset dispatch
-- debounce state for the next mission.
mod:hook_safe(CLASS.StateGameplay, "on_exit", function()
    mod:reset_dispatch()
    mod:send_toy_command(mod:make_stop_command())
end)
