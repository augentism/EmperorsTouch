local mod = get_mod("EmperorsTouch")

return {
	name = "EmperorsTouch",
	description = mod:localize("mod_description"),
	is_togglable = true,
	options = {
		widgets = {
			{
				setting_id    = "backend",
				type          = "dropdown",
				default_value = "lovense_remote",
				options       = {
					{ text = "backend_lovense_remote", value = "lovense_remote" },
					{ text = "backend_bridge",         value = "bridge" },
				},
			},
			{
				setting_id      = "open_emperors_touch_view",
				type            = "keybind",
				default_value   = { "f10" },
				keybind_trigger = "pressed",
				keybind_type    = "view_toggle",
				view_name       = "emperors_touch_view",
			},
			{
				setting_id      = "open_preset_editor",
				type            = "keybind",
				default_value   = { "f9" },
				keybind_trigger = "pressed",
				keybind_type    = "view_toggle",
				view_name       = "emperors_touch_preset_editor",
			},
			{
				setting_id    = "debug_logging",
				type          = "checkbox",
				default_value = false,
			},
			{
				setting_id      = "stop_all_toys",
				type            = "keybind",
				default_value   = { "f11" },
				keybind_trigger = "pressed",
				keybind_type    = "function_call",
				function_name   = "emperors_touch_stop_all",
			},
		},
	},
}
