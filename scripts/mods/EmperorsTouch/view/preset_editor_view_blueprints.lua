local mod = get_mod("EmperorsTouch")

local UISoundEvents       = mod:original_require("scripts/settings/ui/ui_sound_events")
local UIFontSettings      = mod:original_require("scripts/managers/ui/ui_font_settings")
local OptionsViewSettings = mod:original_require("scripts/ui/views/options_view/options_view_settings")
local ButtonPassTemplates = mod:original_require("scripts/ui/pass_templates/button_pass_templates")

local grid_width = OptionsViewSettings.grid_size[1]

-- Editable fields. `action` fields live under preset.actions[key];
-- others live directly on the preset.
local FIELDS = {
    { key = "Vibrate",  label = "Vibrate",     min = 0, max = 20, step = 1, action = true },
    { key = "Rotate",   label = "Rotate",      min = 0, max = 20, step = 1, action = true },
    { key = "Pump",     label = "Pump",        min = 0, max = 3,  step = 1, action = true },
    { key = "duration", label = "Duration (s)", min = 0, max = 30, step = 1 },
    { key = "loop_on",  label = "Loop On (s)",  min = 0, max = 20, step = 1 },
    { key = "loop_off", label = "Loop Off (s)", min = 0, max = 20, step = 1 },
}

local hotspot_style = {
    on_hover_sound   = UISoundEvents.default_mouse_hover,
    on_pressed_sound = UISoundEvents.default_click,
}

local text_style  = table.clone(UIFontSettings.list_button)
text_style.offset[1] = 10
text_style.offset[2] = -10
text_style.font_size  = 20

local text_style2 = table.clone(UIFontSettings.list_button_second_row)
text_style2.offset[1] = 10
text_style2.offset[2] = 22

-- Reusable value stepper pass template. Reads content.{value,min,max,step}
-- and calls content.on_changed_callback(new_value) when changed.
local value_stepper_passes = {
    {
        pass_type = "logic",
        value = function(pass, ui_renderer, style, content, position, size)
            local changed = false
            if content.hotspot_left and content.hotspot_left.on_pressed then
                content.value = math.max(content.min, content.value - content.step)
                changed = true
            elseif content.hotspot_right and content.hotspot_right.on_pressed then
                content.value = math.min(content.max, content.value + content.step)
                changed = true
            end
            content.value_text = tostring(content.value)
            if changed and content.on_changed_callback then
                content.on_changed_callback(content.value)
            end
        end,
    },
    {
        pass_type = "rect",
        style     = { color = { 60, 20, 20, 24 }, offset = { 0, 0, 0 } },
    },
    {
        pass_type = "text",
        value_id  = "label",
        style     = {
            font_type                 = "proxima_nova_bold",
            font_size                 = 20,
            text_color                = { 255, 220, 200, 200 },
            text_horizontal_alignment = "left",
            text_vertical_alignment   = "center",
            offset                    = { 14, 0, 2 },
            size                      = { 220, 56 },
        },
    },
    {
        pass_type  = "hotspot",
        content_id = "hotspot_left",
        content    = hotspot_style,
        style      = {
            horizontal_alignment = "left",
            vertical_alignment   = "center",
            size                 = { 44, 44 },
            offset               = { 250, 0, 3 },
        },
    },
    {
        pass_type = "text",
        value     = "<",
        style     = {
            font_type                 = "proxima_nova_bold",
            font_size                 = 28,
            text_color                = { 255, 255, 230, 200 },
            text_horizontal_alignment = "center",
            text_vertical_alignment   = "center",
            horizontal_alignment      = "left",
            vertical_alignment        = "center",
            size                      = { 44, 44 },
            offset                    = { 250, 0, 4 },
        },
    },
    {
        pass_type = "text",
        value_id  = "value_text",
        style     = {
            font_type                 = "proxima_nova_bold",
            font_size                 = 24,
            text_color                = { 255, 255, 240, 220 },
            text_horizontal_alignment = "center",
            text_vertical_alignment   = "center",
            horizontal_alignment      = "left",
            vertical_alignment        = "center",
            size                      = { 60, 44 },
            offset                    = { 296, 0, 4 },
        },
    },
    {
        pass_type  = "hotspot",
        content_id = "hotspot_right",
        content    = hotspot_style,
        style      = {
            horizontal_alignment = "left",
            vertical_alignment   = "center",
            size                 = { 44, 44 },
            offset               = { 356, 0, 3 },
        },
    },
    {
        pass_type = "text",
        value     = ">",
        style     = {
            font_type                 = "proxima_nova_bold",
            font_size                 = 28,
            text_color                = { 255, 255, 230, 200 },
            text_horizontal_alignment = "center",
            text_vertical_alignment   = "center",
            horizontal_alignment      = "left",
            vertical_alignment        = "center",
            size                      = { 44, 44 },
            offset                    = { 356, 0, 4 },
        },
    },
}

local blueprints = {
    -- Selectable preset row in the left list.
    preset_row = {
        size = { grid_width, 64 },

        pass_template = {
            {
                style_id   = "hotspot",
                pass_type  = "hotspot",
                content_id = "hotspot",
                content    = { use_is_focused = true },
                style      = hotspot_style,
            },
            {
                pass_type = "texture",
                style_id  = "background_selected",
                value     = "content/ui/materials/buttons/background_selected",
                style     = { color = Color.ui_terminal(0, true), offset = { 0, 0, 0 } },
                change_function = function(content, style)
                    local base = 255 * content.hotspot.anim_select_progress
                    style.color[1] = content.is_selected and 255 or base
                end,
                visibility_function = ButtonPassTemplates.list_button_focused_visibility_function,
            },
            {
                pass_type = "texture",
                style_id  = "highlight",
                value     = "content/ui/materials/frames/hover",
                style     = {
                    hdr = true, scale_to_material = true,
                    color = Color.ui_terminal(255, true), offset = { 0, 0, 3 }, size_addition = { 0, 0 },
                },
                change_function     = ButtonPassTemplates.list_button_highlight_change_function,
                visibility_function = ButtonPassTemplates.list_button_focused_visibility_function,
            },
            {
                pass_type = "text", style_id = "text", value_id = "text",
                style = table.clone(text_style),
                change_function = ButtonPassTemplates.list_button_label_change_function,
            },
            {
                pass_type = "text", style_id = "text2", value_id = "text2",
                style = table.clone(text_style2),
                change_function = ButtonPassTemplates.list_button_label_change_function,
            },
        },

        init = function(parent, widget, entry, callback_name)
            local content = widget.content
            content.hotspot.pressed_callback = function()
                callback(parent, callback_name, widget, entry)()
            end
            content.text  = entry.title
            content.text2 = entry.subtitle
            content.entry = entry
        end,
    },
}

return settings("PresetEditorViewBlueprints", {
    blueprints           = blueprints,
    fields               = FIELDS,
    value_stepper_passes = value_stepper_passes,
})
