local mod = get_mod("EmperorsTouch")

local UIWorkspaceSettings    = mod:original_require("scripts/settings/ui/ui_workspace_settings")
local ScrollbarPassTemplates = mod:original_require("scripts/ui/pass_templates/scrollbar_pass_templates")
local UIFontSettings         = mod:original_require("scripts/managers/ui/ui_font_settings")
local UIWidget               = mod:original_require("scripts/managers/ui/ui_widget")
local ButtonPassTemplates    = mod:original_require("scripts/ui/pass_templates/button_pass_templates")

local _s = mod:io_dofile("EmperorsTouch/scripts/mods/EmperorsTouch/view/preset_editor_view_settings")

local scrollbar_width = _s.scrollbar_width
local grid_size       = _s.grid_size
local grid_width      = grid_size[1]
local grid_height     = grid_size[2]
local blur_edge       = _s.grid_blur_edge_size
local mask_size       = { grid_width + blur_edge[1] * 2, grid_height + blur_edge[2] * 2 }

-- Right editing panel geometry
local PANEL_X       = 700
local PANEL_TOP     = 250
local STEPPER_W     = 400
local STEPPER_H     = 56
local STEPPER_GAP   = 8
local NUM_STEPPERS  = 6

local scenegraph_definition = {
    screen = UIWorkspaceSettings.screen,

    background = {
        vertical_alignment   = "top",
        parent               = "screen",
        horizontal_alignment = "left",
        size                 = { grid_width, grid_height },
        position             = { 180, 250, 1 },
    },

    grid_start = {
        vertical_alignment   = "top",
        parent               = "background",
        horizontal_alignment = "left",
        size                 = { 0, 0 },
        position             = { 0, 0, 0 },
    },

    grid_content_pivot = {
        vertical_alignment   = "top",
        parent               = "grid_start",
        horizontal_alignment = "left",
        size                 = { 0, 0 },
        position             = { 0, 0, 1 },
    },

    grid_mask = {
        vertical_alignment   = "center",
        parent               = "background",
        horizontal_alignment = "center",
        size                 = mask_size,
        position             = { 0, 0, 0 },
    },

    grid_interaction = {
        vertical_alignment   = "top",
        parent               = "background",
        horizontal_alignment = "left",
        size                 = { grid_width + scrollbar_width * 2, mask_size[2] },
        position             = { 0, 0, 0 },
    },

    scrollbar = {
        vertical_alignment   = "center",
        parent               = "background",
        horizontal_alignment = "right",
        size                 = { scrollbar_width, grid_height },
        position             = { 50, 0, 1 },
    },

    title_divider = {
        vertical_alignment   = "top",
        parent               = "screen",
        horizontal_alignment = "left",
        size                 = { 335, 18 },
        position             = { 180, 145, 1 },
    },

    title_text = {
        vertical_alignment   = "bottom",
        parent               = "title_divider",
        horizontal_alignment = "left",
        size                 = { 600, 50 },
        position             = { 0, -35, 1 },
    },

    new_button = {
        vertical_alignment   = "top",
        parent               = "screen",
        horizontal_alignment = "left",
        size                 = { 220, 44 },
        position             = { 180, 192, 2 },
    },

    selected_label = {
        vertical_alignment   = "top",
        parent               = "screen",
        horizontal_alignment = "left",
        size                 = { STEPPER_W, 36 },
        position             = { PANEL_X, PANEL_TOP - 44, 2 },
    },

    delete_button = {
        vertical_alignment   = "top",
        parent               = "screen",
        horizontal_alignment = "left",
        size                 = { 220, 44 },
        position             = { PANEL_X, PANEL_TOP + NUM_STEPPERS * (STEPPER_H + STEPPER_GAP) + 12, 2 },
    },
}

-- Stepper node per editable field
for i = 1, NUM_STEPPERS do
    scenegraph_definition["stepper_" .. i] = {
        vertical_alignment   = "top",
        parent               = "screen",
        horizontal_alignment = "left",
        size                 = { STEPPER_W, STEPPER_H },
        position             = { PANEL_X, PANEL_TOP + (i - 1) * (STEPPER_H + STEPPER_GAP), 2 },
    }
end

local widget_definitions = {
    background = UIWidget.create_definition({
        { pass_type = "rect", style = { color = { 255, 0, 0, 0 } } }
    }, "screen"),

    title_divider = UIWidget.create_definition({
        { pass_type = "texture", value = "content/ui/materials/dividers/skull_rendered_left_01" }
    }, "title_divider"),

    title_text = UIWidget.create_definition({
        {
            value_id  = "text",
            style_id  = "text",
            pass_type = "text",
            value     = "Emperor's Touch — Presets",
            style     = table.clone(UIFontSettings.header_1),
        }
    }, "title_text"),

    new_button = UIWidget.create_definition(
        table.clone(ButtonPassTemplates.default_button), "new_button", { original_text = "+ New Preset" }
    ),

    delete_button = UIWidget.create_definition(
        table.clone(ButtonPassTemplates.default_button), "delete_button", { original_text = "Delete Preset" }
    ),

    selected_label = UIWidget.create_definition({
        {
            value_id  = "text",
            pass_type = "text",
            value     = "",
            style     = {
                font_type                 = "proxima_nova_bold",
                font_size                 = 22,
                text_color                = { 255, 220, 200, 160 },
                text_horizontal_alignment = "left",
                text_vertical_alignment   = "center",
                size                      = { STEPPER_W, 36 },
                offset                    = { 0, 0, 2 },
            },
        }
    }, "selected_label"),

    scrollbar = UIWidget.create_definition(ScrollbarPassTemplates.default_scrollbar, "scrollbar"),

    grid_mask = UIWidget.create_definition({
        {
            value     = "content/ui/materials/offscreen_masks/ui_overlay_offscreen_vertical_blur",
            pass_type = "texture",
            style     = { color = { 255, 255, 255, 255 } },
        }
    }, "grid_mask"),

    grid_interaction = UIWidget.create_definition({
        { pass_type = "hotspot", content_id = "hotspot" }
    }, "grid_interaction"),
}

local legend_inputs = {
    {
        input_action        = "back",
        on_pressed_callback = "cb_on_back_pressed",
        display_name        = "loc_settings_menu_close_menu",
        alignment           = "left_alignment",
    },
}

local PresetEditorViewDefinitions = {
    legend_inputs         = legend_inputs,
    widget_definitions    = widget_definitions,
    scenegraph_definition = scenegraph_definition,
    num_steppers          = NUM_STEPPERS,
}

return settings("PresetEditorViewDefinitions", PresetEditorViewDefinitions)
