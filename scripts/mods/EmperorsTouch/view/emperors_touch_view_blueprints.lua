local mod = get_mod("EmperorsTouch")

local UISoundEvents       = mod:original_require("scripts/settings/ui/ui_sound_events")
local UIFontSettings      = mod:original_require("scripts/managers/ui/ui_font_settings")
local OptionsViewSettings = mod:original_require("scripts/ui/views/options_view/options_view_settings")
local ButtonPassTemplates = mod:original_require("scripts/ui/pass_templates/button_pass_templates")

local grid_width = OptionsViewSettings.grid_size[1]

local hotspot_style = {
    anim_hover_speed  = 8,
    anim_input_speed  = 8,
    anim_select_speed = 8,
    anim_focus_speed  = 8,
    on_hover_sound    = UISoundEvents.default_mouse_hover,
    on_pressed_sound  = UISoundEvents.default_click,
}

local text_style  = table.clone(UIFontSettings.list_button)
text_style.offset[1] = 10
text_style.offset[2] = -10
text_style.font_size = 20

local text_style2 = table.clone(UIFontSettings.list_button_second_row)
text_style2.offset[1] = 10
text_style2.offset[2] = 22

local blueprints = {
    toy_button = {
        size = { grid_width, 75 },

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
                    style.color[1] = 255 * content.hotspot.anim_select_progress
                end,
                visibility_function = ButtonPassTemplates.list_button_focused_visibility_function,
            },
            {
                pass_type = "texture",
                style_id  = "highlight",
                value     = "content/ui/materials/frames/hover",
                style     = {
                    hdr               = true,
                    scale_to_material = true,
                    color             = Color.ui_terminal(255, true),
                    offset            = { 0, 0, 3 },
                    size_addition     = { 0, 0 },
                },
                change_function     = ButtonPassTemplates.list_button_highlight_change_function,
                visibility_function = ButtonPassTemplates.list_button_focused_visibility_function,
            },
            {
                pass_type = "text",
                style_id  = "text",
                value_id  = "text",
                style     = table.clone(text_style),
                change_function = ButtonPassTemplates.list_button_label_change_function,
            },
            {
                pass_type = "text",
                style_id  = "text2",
                value_id  = "text2",
                style     = table.clone(text_style2),
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

return settings("EmperorsTouchViewBlueprints", blueprints)
