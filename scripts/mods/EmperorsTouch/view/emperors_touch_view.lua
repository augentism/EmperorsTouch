--[[
    emperors_touch_view.lua
    History-style view (mimics peril_tracker/scoreboard):
    "Get Toys" button top-left queries the Lovense API, and the scrollable
    left grid is populated with the toys from the response.
--]]

local mod = get_mod("EmperorsTouch")

local ScriptWorld            = mod:original_require("scripts/foundation/utilities/script_world")
local UIRenderer             = mod:original_require("scripts/managers/ui/ui_renderer")
local UIWidget               = mod:original_require("scripts/managers/ui/ui_widget")
local UIWidgetGrid           = mod:original_require("scripts/ui/widget_logic/ui_widget_grid")
local ViewElementInputLegend = mod:original_require("scripts/ui/view_elements/view_element_input_legend/view_element_input_legend")

local DropdownHelper = mod:io_dofile("EmperorsTouch/scripts/mods/EmperorsTouch/view/dropdown_helper")

local VIEW_NAME = "emperors_touch_view"

local EmperorsTouchView = class("EmperorsTouchView", "BaseView")

DropdownHelper.install(EmperorsTouchView)

-- ===== Helpers =====

local function toy_to_entry(toy)
    local name     = toy.name or "unknown"
    local nickname = toy.nickName
    local title    = name:gsub("^%l", string.upper)
    if nickname and nickname ~= "" then
        title = string.format("%s (%s)", nickname, title)
    end

    local status = toy.status == "1" and "Connected" or "Disconnected"

    return {
        widget_type = "toy_button",
        title       = title,
        subtitle    = string.format("Battery: %d%%  |  %s  |  id: %s", toy.battery or 0, status, toy.id or "?"),
        toy         = toy,
    }
end

-- ===== Init =====

EmperorsTouchView.init = function(self, settings_arg)
    self._definitions   = mod:io_dofile("EmperorsTouch/scripts/mods/EmperorsTouch/view/emperors_touch_view_definitions")
    self._blueprints    = mod:io_dofile("EmperorsTouch/scripts/mods/EmperorsTouch/view/emperors_touch_view_blueprints")
    self._view_settings = mod:io_dofile("EmperorsTouch/scripts/mods/EmperorsTouch/view/emperors_touch_view_settings")
    self._selected_toy       = nil
    self._entry_widgets      = {}
    self._entries_grid       = nil
    self._hook_panel_widgets = {}
    EmperorsTouchView.super.init(self, self._definitions, settings_arg)
    self._pass_draw = false
    self:_setup_offscreen_gui()
end

EmperorsTouchView._setup_offscreen_gui = function(self)
    local ui_manager     = Managers.ui
    local class_name     = self.__class_name
    local timer_name     = "ui"
    local world_layer    = 10
    local world_name     = class_name .. "_ui_offscreen_world"
    local view_name      = self.view_name
    self._offscreen_world = ui_manager:create_world(world_name, world_layer, timer_name, view_name)
    local shading_env    = self._view_settings.shading_environment
    local viewport_name  = class_name .. "_ui_offscreen_world_viewport"
    local viewport_type  = "overlay_offscreen"
    local viewport_layer = 1
    self._offscreen_viewport = ui_manager:create_viewport(
        self._offscreen_world, viewport_name, viewport_type, viewport_layer, shading_env
    )
    self._offscreen_viewport_name = viewport_name
    self._ui_offscreen_renderer   = ui_manager:create_renderer(
        class_name .. "_ui_offscreen_renderer", self._offscreen_world
    )
end

-- ===== on_enter =====

EmperorsTouchView.on_enter = function(self)
    EmperorsTouchView.super.on_enter(self)
    self:_setup_input_legend()
    self:_setup_get_toys_button()

    -- Show the cached toy list; Get Toys re-polls and refreshes the cache.
    if #(mod.toys or {}) > 0 then
        self:_populate_toys(mod.toys)
    else
        self:_show_message("Press Get Toys to query connected devices.")
    end
end

EmperorsTouchView._setup_input_legend = function(self)
    self._input_legend_element = self:_add_element(ViewElementInputLegend, "input_legend", 10)
    for _, leg in ipairs(self._definitions.legend_inputs) do
        local cb = leg.on_pressed_callback and callback(self, leg.on_pressed_callback)
        self._input_legend_element:add_entry(leg.display_name, leg.input_action, nil, cb, leg.alignment)
    end
end

EmperorsTouchView._setup_get_toys_button = function(self)
    local button = self._widgets_by_name.get_toys_button
    if button then
        button.content.hotspot.pressed_callback = callback(self, "cb_get_toys_pressed")
    end
end

-- ===== Toy list =====

EmperorsTouchView._clear_entries = function(self)
    if self._entry_widgets then
        for _, w in ipairs(self._entry_widgets) do
            pcall(function() self:_unregister_widget_name(w.name) end)
        end
    end
    self._entry_widgets = {}
    self._entries_grid  = nil
end

EmperorsTouchView._show_message = function(self, text)
    self:_clear_entries()
    local def = UIWidget.create_definition({
        {
            pass_type = "text",
            value     = text,
            style     = {
                font_type                 = "proxima_nova_bold",
                font_size                 = 18,
                text_color                = { 200, 180, 180, 180 },
                text_horizontal_alignment = "left",
                text_vertical_alignment   = "top",
                size                      = { 460, 100 },
                offset                    = { 0, 0 },
            },
        },
    }, "grid_content_pivot")
    local widget = self:_create_widget("status_msg_" .. tostring(math.random(1e9)), def)
    self._entry_widgets = { widget }
end

-- Dropdown option list of presets, "None" first.
EmperorsTouchView._preset_options = function(self)
    local presets = mod:get_presets()

    local ordered = {}
    for id, p in pairs(presets) do
        ordered[#ordered + 1] = { id = id, name = p.name or "Preset" }
    end
    table.sort(ordered, function(a, b) return a.name < b.name end)

    local options = { { id = "__none", display_name = "None", ignore_localization = true } }
    for _, item in ipairs(ordered) do
        options[#options + 1] = { id = item.id, display_name = item.name, ignore_localization = true }
    end
    return options
end

EmperorsTouchView._populate_toys = function(self, toys)
    self:_clear_entries()
    self:_clear_hook_panel()

    if #toys == 0 then
        self:_show_message("No toys found.")
        return
    end

    local entries = {}
    for _, toy in ipairs(toys) do
        entries[#entries + 1] = toy_to_entry(toy)
    end

    self._entry_widgets = self:_build_entry_widgets(entries, "grid_content_pivot")

    if #self._entry_widgets > 0 then
        self._entries_grid = UIWidgetGrid:new(
            self._entry_widgets,
            self._entry_widgets,
            self._ui_scenegraph,
            "background",
            "down",
            self._view_settings.grid_spacing,
            nil,
            true
        )
        self._entries_grid:set_render_scale(self._render_scale)

        local scrollbar = self._widgets_by_name.scrollbar
        if scrollbar then
            self._entries_grid:assign_scrollbar(scrollbar, "grid_content_pivot", "background")
            self._entries_grid:set_scrollbar_progress(0)
        end
    end
end

EmperorsTouchView._build_entry_widgets = function(self, entries, scenegraph_id)
    local widgets    = {}
    local defs_cache = {}

    for i, entry in ipairs(entries) do
        local wtype    = entry.widget_type
        local template = self._blueprints[wtype]
        if template then
            if not defs_cache[wtype] then
                defs_cache[wtype] = UIWidget.create_definition(
                    template.pass_template, scenegraph_id, nil, template.size
                )
            end
            local widget = self:_create_widget(scenegraph_id .. "_widget_" .. i, defs_cache[wtype])
            if template.init then
                template.init(self, widget, entry, entry.callback_name or "cb_on_toy_pressed")
            end
            widgets[#widgets + 1] = widget
        end
    end

    return widgets
end

-- ===== Callbacks =====

EmperorsTouchView.cb_get_toys_pressed = function(self)
    self:_show_message("Querying toys...")

    mod:get_toys(function(toys, err)
        -- View may have closed while the request was in flight
        if self._destroyed or not Managers.ui:view_active(VIEW_NAME) then
            return
        end
        if err then
            self:_show_message("GetToys failed: " .. tostring(err))
            return
        end
        self:_populate_toys(toys or {})
    end)
end

EmperorsTouchView.cb_on_toy_pressed = function(self, widget, entry)
    self._selected_toy = entry.toy

    -- Mark selection in the list
    for _, w in ipairs(self._entry_widgets or {}) do
        if w.content and w.content.hotspot then
            w.content.is_selected = (w == widget)
        end
    end

    self:_build_hook_panel(entry.toy)
end

-- ===== Right-side hook panel =====

EmperorsTouchView._clear_hook_panel = function(self)
    self:close_focused_dropdown()

    for _, w in ipairs(self._hook_panel_widgets or {}) do
        for i = #self._widgets, 1, -1 do
            if self._widgets[i] == w then
                table.remove(self._widgets, i)
                break
            end
        end
        pcall(function() self:_unregister_widget_name(w.name) end)
    end
    self._hook_panel_widgets = {}

    local title = self._widgets_by_name.hook_panel_title
    if title then
        title.content.text = ""
    end
end

EmperorsTouchView._build_hook_panel = function(self, toy)
    self:_clear_hook_panel()

    -- Cached copy so dropdown get_functions don't clone settings every frame
    self._assign_cache = mod:get_assignments()

    local title = self._widgets_by_name.hook_panel_title
    if title then
        local name = (toy.nickName and toy.nickName ~= "") and toy.nickName
            or (toy.name or "toy"):gsub("^%l", string.upper)
        title.content.text = "Hooks — " .. name
    end

    local ROW_H  = 52
    local toy_id = toy.id

    for i, hook in ipairs(mod.HOOKS or {}) do
        local hook_id = hook.id
        local entry = {
            header_text = hook.name,
            size        = { 960, 44 },   -- label gets 960 - value_width; wide enough for long hook names
            value_width = 320,
            options     = self:_preset_options(),
            get_function = function()
                local by_toy = self._assign_cache[hook_id]
                return by_toy and by_toy[toy_id] or "__none"
            end,
            on_activated = function(new_id)
                local preset_id = new_id ~= "__none" and new_id or nil
                self._assign_cache[hook_id] = self._assign_cache[hook_id] or {}
                self._assign_cache[hook_id][toy_id] = preset_id
                mod:assign_preset(hook_id, toy_id, preset_id)
            end,
        }

        local widget = DropdownHelper.create(self, "hook_panel_row_" .. i, "hook_panel", entry)
        widget.offset = { 0, (i - 1) * ROW_H, 0 }

        self._widgets[#self._widgets + 1] = widget   -- drawn by BaseView
        self._hook_panel_widgets[#self._hook_panel_widgets + 1] = widget
    end
end

EmperorsTouchView.cb_on_back_pressed = function(self)
    Managers.ui:close_view(VIEW_NAME)
end

-- ===== Update =====

EmperorsTouchView.update = function(self, dt, t, input_service)
    if self._entries_grid then
        self._entries_grid:update(dt, t, input_service)
    end
    if self._entry_widgets then
        for _, widget in ipairs(self._entry_widgets) do
            local hotspot = widget.content and widget.content.hotspot
            if hotspot and hotspot.is_focused then
                hotspot.is_selected = true
            end
        end
    end
    for _, widget in ipairs(self._hook_panel_widgets or {}) do
        DropdownHelper.update(self, widget, input_service, dt, t)
    end
    DropdownHelper.handle_outside_click(self, input_service)
    return EmperorsTouchView.super.update(self, dt, t, input_service)
end

-- ===== Draw =====

EmperorsTouchView.draw = function(self, dt, t, input_service, layer)
    DropdownHelper.draw_with_focus(self, dt, t, input_service, function(effective_input)
        self:_draw_elements(dt, t, self._ui_renderer, self._render_settings, effective_input)

        if self._entry_widgets and #self._entry_widgets > 0 then
            local grid_interaction = self._widgets_by_name.grid_interaction
            self:_draw_grid(self._entries_grid, self._entry_widgets, grid_interaction, dt, t, effective_input)
        end

        EmperorsTouchView.super.draw(self, dt, t, effective_input, layer)
    end)
end

EmperorsTouchView._draw_grid = function(self, grid, widgets, interaction_widget, dt, t, input_service)
    local render_settings = self._render_settings
    local ui_renderer     = self._ui_offscreen_renderer
    local ui_scenegraph   = self._ui_scenegraph

    UIRenderer.begin_pass(ui_renderer, ui_scenegraph, input_service, dt, render_settings)
    for _, widget in ipairs(widgets) do
        local visible = not grid or grid:is_widget_visible(widget)
        if visible then
            UIWidget.draw(widget, ui_renderer)
        end
    end
    UIRenderer.end_pass(ui_renderer)
end

-- ===== on_exit =====

EmperorsTouchView.on_exit = function(self)
    self._destroyed = true

    if self._input_legend_element then
        self:_remove_element("input_legend")
        self._input_legend_element = nil
    end

    if self._ui_offscreen_renderer then
        Managers.ui:destroy_renderer(self.__class_name .. "_ui_offscreen_renderer")
        ScriptWorld.destroy_viewport(self._offscreen_world, self._offscreen_viewport_name)
        Managers.ui:destroy_world(self._offscreen_world)
        self._ui_offscreen_renderer   = nil
        self._offscreen_viewport      = nil
        self._offscreen_viewport_name = nil
        self._offscreen_world         = nil
    end

    EmperorsTouchView.super.on_exit(self)
end

return EmperorsTouchView
