--[[
    preset_editor_view.lua
    Left: scrollable list of presets (select). Right: value steppers editing the
    selected preset's actions/duration/loop. Top-left: New Preset. Persists to
    mod:set("presets", ...) on every change.
--]]

local mod = get_mod("EmperorsTouch")

local ScriptWorld            = mod:original_require("scripts/foundation/utilities/script_world")
local UIRenderer             = mod:original_require("scripts/managers/ui/ui_renderer")
local UIWidget               = mod:original_require("scripts/managers/ui/ui_widget")
local UIWidgetGrid           = mod:original_require("scripts/ui/widget_logic/ui_widget_grid")
local ViewElementInputLegend = mod:original_require("scripts/ui/view_elements/view_element_input_legend/view_element_input_legend")

local DropdownHelper = mod:io_dofile("EmperorsTouch/scripts/mods/EmperorsTouch/view/dropdown_helper")

local VIEW_NAME = "emperors_touch_preset_editor"

local PresetEditorView = class("PresetEditorView", "BaseView")

DropdownHelper.install(PresetEditorView)

-- ===== Field helpers =====

local function field_get(preset, f)
    if f.action then return (preset.actions or {})[f.key] or 0 end
    return preset[f.key] or 0
end

local function field_set(preset, f, v)
    if f.action then
        preset.actions = preset.actions or {}
        preset.actions[f.key] = v
    else
        preset[f.key] = v
    end
end

local function preset_summary(preset)
    local parts = {}
    for action, strength in pairs(preset.actions or {}) do
        if strength and strength > 0 then
            parts[#parts + 1] = string.format("%s:%d", action, strength)
        end
    end
    local a = #parts > 0 and table.concat(parts, ", ") or "(no actions)"
    local dur = (preset.duration and preset.duration > 0) and string.format("  dur %ds", preset.duration) or ""
    local loop = ""
    if (preset.loop_on or 0) > 0 or (preset.loop_off or 0) > 0 then
        loop = string.format("  loop %d/%d", preset.loop_on or 0, preset.loop_off or 0)
    end
    return a .. dur .. loop
end

-- ===== Init =====

PresetEditorView.init = function(self, settings_arg)
    self._definitions   = mod:io_dofile("EmperorsTouch/scripts/mods/EmperorsTouch/view/preset_editor_view_definitions")
    local bp            = mod:io_dofile("EmperorsTouch/scripts/mods/EmperorsTouch/view/preset_editor_view_blueprints")
    self._blueprints    = bp.blueprints
    self._fields        = bp.fields
    self._slider_passes = bp.slider_passes
    self._view_settings = mod:io_dofile("EmperorsTouch/scripts/mods/EmperorsTouch/view/preset_editor_view_settings")

    self._presets       = mod:get_presets()   -- working copy, persisted on change
    self._selected_id   = nil
    self._entry_widgets = {}
    self._entries_grid  = nil
    self._row_by_id     = {}
    self._stepper_widgets = {}

    PresetEditorView.super.init(self, self._definitions, settings_arg)
    self._pass_draw = false
    self:_setup_offscreen_gui()
end

PresetEditorView._setup_offscreen_gui = function(self)
    local ui_manager     = Managers.ui
    local class_name     = self.__class_name
    self._offscreen_world = ui_manager:create_world(class_name .. "_world", 10, "ui", self.view_name)
    local viewport_name  = class_name .. "_viewport"
    self._offscreen_viewport = ui_manager:create_viewport(
        self._offscreen_world, viewport_name, "overlay_offscreen", 1, self._view_settings.shading_environment
    )
    self._offscreen_viewport_name = viewport_name
    self._ui_offscreen_renderer   = ui_manager:create_renderer(class_name .. "_renderer", self._offscreen_world)
end

-- ===== on_enter =====

PresetEditorView.on_enter = function(self)
    PresetEditorView.super.on_enter(self)

    -- Input legend
    self._input_legend_element = self:_add_element(ViewElementInputLegend, "input_legend", 10)
    for _, leg in ipairs(self._definitions.legend_inputs) do
        local cb = leg.on_pressed_callback and callback(self, leg.on_pressed_callback)
        self._input_legend_element:add_entry(leg.display_name, leg.input_action, nil, cb, leg.alignment)
    end

    -- Top buttons
    local new_button = self._widgets_by_name.new_button
    if new_button then
        new_button.content.hotspot.pressed_callback = callback(self, "cb_new_preset")
    end
    local del_button = self._widgets_by_name.delete_button
    if del_button then
        del_button.content.hotspot.pressed_callback = callback(self, "cb_delete_preset")
    end
    local test_button = self._widgets_by_name.test_button
    if test_button then
        test_button.content.hotspot.pressed_callback = callback(self, "cb_test_preset")
    end
    -- Target dropdown for the test button: All Toys + each cached toy
    local toy_options = { { id = "__all", display_name = "All Toys", ignore_localization = true } }
    for _, toy in ipairs(mod.toys or {}) do
        local name = (toy.nickName and toy.nickName ~= "") and toy.nickName
            or (toy.name or "toy"):gsub("^%l", string.upper)
        toy_options[#toy_options + 1] = { id = toy.id, display_name = name, ignore_localization = true }
    end
    self._test_target_id   = "__all"
    self._test_target_name = "All Toys"

    self._test_toy_dropdown = DropdownHelper.create(self, "test_toy_dropdown", "test_toy_selector", {
        header_text = "Target",
        size        = { 440, 44 },
        value_width = 280,
        options     = toy_options,
        get_function = function()
            return self._test_target_id
        end,
        on_activated = function(new_id)
            self._test_target_id = new_id
            for _, opt in ipairs(toy_options) do
                if opt.id == new_id then
                    self._test_target_name = opt.display_name
                    break
                end
            end
        end,
    })
    self._widgets[#self._widgets + 1] = self._test_toy_dropdown

    self:_build_steppers()
    self:_load_presets()
    self:_select(nil)
end

-- ===== Sliders =====

local function slider_label(field, value)
    return string.format("%s  %d", field.label, value)
end

PresetEditorView._build_steppers = function(self)
    for i, f in ipairs(self._fields) do
        local node = "stepper_" .. i
        local def  = UIWidget.create_definition(self._slider_passes, node)
        local widget = self:_create_widget(node, def)
        self._widgets[#self._widgets + 1] = widget   -- ensure it is drawn

        local range   = f.max - f.min
        local content = widget.content
        content.field          = f
        content.step_size      = f.step / range   -- normalized, quantizes drag
        content.slider_value   = 0
        content.applied_value  = f.min
        content.value_text     = slider_label(f, f.min)

        self._stepper_widgets[i] = widget
    end
end

PresetEditorView._sync_steppers = function(self)
    local preset  = self._selected_id and self._presets[self._selected_id]
    local visible = preset ~= nil
    for i, f in ipairs(self._fields) do
        local widget = self._stepper_widgets[i]
        widget.visible = visible
        if preset then
            local v = field_get(preset, f)
            local content = widget.content
            content.slider_value  = (v - f.min) / (f.max - f.min)
            content.applied_value = v
            content.value_text    = slider_label(f, v)
        end
    end

    local del_button = self._widgets_by_name.delete_button
    if del_button then del_button.visible = visible end

    local label = self._widgets_by_name.selected_label
    if label then
        label.visible = visible
        label.content.text = preset and (preset.name or "Preset") or ""
    end
end

-- Called every frame: applies quantized slider movement to the preset.
PresetEditorView._update_sliders = function(self)
    local preset = self._selected_id and self._presets[self._selected_id]
    if not preset then return end

    local changed = false
    for i, f in ipairs(self._fields) do
        local content = self._stepper_widgets[i].content
        local range   = f.max - f.min
        local raw     = f.min + (content.slider_value or 0) * range
        local value   = math.min(f.max, math.max(f.min, math.floor(raw / f.step + 0.5) * f.step))

        if value ~= content.applied_value then
            content.applied_value = value
            content.value_text    = slider_label(f, value)
            field_set(preset, f, value)
            changed = true
        end
    end

    if changed then
        mod:set_presets(self._presets)
        local row = self._row_by_id[self._selected_id]
        if row then row.content.text2 = preset_summary(preset) end
    end
end

-- ===== Preset list =====

PresetEditorView._clear_entries = function(self)
    for _, w in ipairs(self._entry_widgets) do
        pcall(function() self:_unregister_widget_name(w.name) end)
    end
    self._entry_widgets = {}
    self._entries_grid  = nil
    self._row_by_id     = {}
end

PresetEditorView._load_presets = function(self)
    self:_clear_entries()

    -- Ordered array of {id, preset}
    local order = {}
    for id, preset in pairs(self._presets) do
        order[#order + 1] = { id = id, preset = preset }
    end
    table.sort(order, function(a, b) return (a.preset.name or "") < (b.preset.name or "") end)
    self._order = order

    local template = self._blueprints.preset_row
    local def      = UIWidget.create_definition(template.pass_template, "grid_content_pivot", nil, template.size)

    for i, item in ipairs(order) do
        local widget = self:_create_widget("preset_row_" .. i, def)
        template.init(self, widget, {
            title    = item.preset.name or "Preset",
            subtitle = preset_summary(item.preset),
            id       = item.id,
        }, "cb_on_preset_pressed")
        self._entry_widgets[#self._entry_widgets + 1] = widget
        self._row_by_id[item.id] = widget
    end

    if #self._entry_widgets > 0 then
        self._entries_grid = UIWidgetGrid:new(
            self._entry_widgets, self._entry_widgets, self._ui_scenegraph,
            "background", "down", self._view_settings.grid_spacing, nil, true
        )
        self._entries_grid:set_render_scale(self._render_scale)
        local scrollbar = self._widgets_by_name.scrollbar
        if scrollbar then
            self._entries_grid:assign_scrollbar(scrollbar, "grid_content_pivot", "background")
            self._entries_grid:set_scrollbar_progress(0)
        end
    end
end

PresetEditorView._select = function(self, id)
    self._selected_id = id
    for row_id, widget in pairs(self._row_by_id) do
        widget.content.is_selected = (row_id == id)
    end
    self:_sync_steppers()
end

-- ===== Callbacks =====

PresetEditorView.cb_on_preset_pressed = function(self, widget, entry)
    self:_select(entry.id)
end

PresetEditorView.cb_new_preset = function(self)
    local n = 1
    for _ in pairs(self._presets) do n = n + 1 end
    local id = string.format("preset_%d_%d", math.floor(mod:clock() * 1000), math.random(1000, 9999))
    self._presets[id] = {
        name     = "Preset " .. n,
        actions  = { Vibrate = 10 },
        duration = 0,
        loop_on  = 0,
        loop_off = 0,
    }
    mod:set_presets(self._presets)
    self:_load_presets()
    self:_select(id)
end

PresetEditorView.cb_delete_preset = function(self)
    local id = self._selected_id
    if not id then return end
    self._presets[id] = nil
    mod:set_presets(self._presets)

    -- Purge any assignments that referenced this preset
    local assignments = mod:get_assignments()
    local changed = false
    for _, toy_map in pairs(assignments) do
        for toy_id, preset_id in pairs(toy_map) do
            if preset_id == id then
                toy_map[toy_id] = nil
                changed = true
            end
        end
    end
    if changed then mod:set_assignments(assignments) end

    self:_load_presets()
    self:_select(nil)
end

PresetEditorView.cb_test_preset = function(self)
    local preset = self._selected_id and self._presets[self._selected_id]
    if not preset then
        mod:echo("Select a preset to test.")
        return
    end

    local target_id   = self._test_target_id ~= "__all" and self._test_target_id or nil
    local target_name = self._test_target_name or "All Toys"

    -- A duration of 0 means "run until stopped"; cap tests at 3s so a
    -- test can't leave a toy running indefinitely.
    local duration = preset.duration or 0
    if duration <= 0 then duration = 3 end

    local cmd = mod:make_toy_command({
        actions  = mod:scale_actions(preset.actions, 1),
        duration = duration,
        loop_on  = preset.loop_on,
        loop_off = preset.loop_off,
        toy      = target_id,
    })
    mod:send_toy_command(cmd, function(ok, err)
        if ok then
            mod:echo(string.format("Testing '%s' on %s", preset.name or "preset", target_name))
        else
            mod:echo("Test failed: " .. tostring(err))
        end
    end)
end

PresetEditorView.cb_on_back_pressed = function(self)
    Managers.ui:close_view(VIEW_NAME)
end

-- ===== Update / Draw =====

PresetEditorView.update = function(self, dt, t, input_service)
    if self._entries_grid then
        self._entries_grid:update(dt, t, input_service)
    end
    self:_update_sliders()
    if self._test_toy_dropdown then
        DropdownHelper.update(self, self._test_toy_dropdown, input_service, dt, t)
    end
    DropdownHelper.handle_outside_click(self, input_service)
    return PresetEditorView.super.update(self, dt, t, input_service)
end

PresetEditorView.draw = function(self, dt, t, input_service, layer)
    DropdownHelper.draw_with_focus(self, dt, t, input_service, function(effective_input)
        self:_draw_elements(dt, t, self._ui_renderer, self._render_settings, effective_input)

        if self._entry_widgets and #self._entry_widgets > 0 then
            self:_draw_grid(dt, t, effective_input)
        end

        PresetEditorView.super.draw(self, dt, t, effective_input, layer)
    end)
end

PresetEditorView._draw_grid = function(self, dt, t, input_service)
    local ui_renderer = self._ui_offscreen_renderer
    UIRenderer.begin_pass(ui_renderer, self._ui_scenegraph, input_service, dt, self._render_settings)
    for _, widget in ipairs(self._entry_widgets) do
        local visible = not self._entries_grid or self._entries_grid:is_widget_visible(widget)
        if visible then
            UIWidget.draw(widget, ui_renderer)
        end
    end
    UIRenderer.end_pass(ui_renderer)
end

-- ===== on_exit =====

PresetEditorView.on_exit = function(self)
    if self._input_legend_element then
        self:_remove_element("input_legend")
        self._input_legend_element = nil
    end
    if self._ui_offscreen_renderer then
        Managers.ui:destroy_renderer(self.__class_name .. "_renderer")
        ScriptWorld.destroy_viewport(self._offscreen_world, self._offscreen_viewport_name)
        Managers.ui:destroy_world(self._offscreen_world)
        self._ui_offscreen_renderer   = nil
        self._offscreen_viewport      = nil
        self._offscreen_viewport_name = nil
        self._offscreen_world         = nil
    end
    PresetEditorView.super.on_exit(self)
end

return PresetEditorView
