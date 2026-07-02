local mod = get_mod("EmperorsTouch")

local UISoundEvents       = mod:original_require("scripts/settings/ui/ui_sound_events")
local UIFontSettings      = mod:original_require("scripts/managers/ui/ui_font_settings")
local OptionsViewSettings = mod:original_require("scripts/ui/views/options_view/options_view_settings")
local ButtonPassTemplates = mod:original_require("scripts/ui/pass_templates/button_pass_templates")

local SliderPassTemplates = mod:original_require("scripts/ui/pass_templates/slider_pass_templates")

local grid_width = OptionsViewSettings.grid_size[1]

-- Editable fields. `action` fields live under preset.actions[key];
-- others live directly on the preset.
local FIELDS = {
    { key = "Vibrate",   label = "Vibrate",      min = 0, max = 20,  step = 1, action = true },
    { key = "Rotate",    label = "Rotate",       min = 0, max = 20,  step = 1, action = true },
    { key = "Pump",      label = "Pump",         min = 0, max = 3,   step = 1, action = true },
    { key = "Thrusting", label = "Thrusting",    min = 0, max = 20,  step = 1, action = true },
    { key = "Fingering", label = "Fingering",    min = 0, max = 20,  step = 1, action = true },
    { key = "Suction",   label = "Suction",      min = 0, max = 20,  step = 1, action = true },
    { key = "Depth",     label = "Depth",        min = 0, max = 3,   step = 1, action = true },
    { key = "Stroke",    label = "Stroke",       min = 0, max = 100, step = 1, action = true },
    { key = "Oscillate", label = "Oscillate",    min = 0, max = 20,  step = 1, action = true },
    { key = "duration",  label = "Duration (s)", min = 0, max = 30,  step = 1 },
    { key = "loop_on",   label = "Loop On (s)",  min = 0, max = 30,  step = 1 },
    { key = "loop_off",  label = "Loop Off (s)", min = 0, max = 30,  step = 1 },
}

-- Engine drag-slider passes. The left `value_text` area doubles as our
-- field label ("Vibrate  12"). Geometry must match the definitions file.
local SLIDER_W       = 440
local SLIDER_H       = 44
local SLIDER_LABEL_W = 170

local slider_passes = SliderPassTemplates.value_slider(SLIDER_W, SLIDER_H, SLIDER_LABEL_W, true)

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
    blueprints    = blueprints,
    fields        = FIELDS,
    slider_passes = slider_passes,
    slider_size   = { SLIDER_W, SLIDER_H },
})
