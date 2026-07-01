return {
	run = function()
		fassert(rawget(_G, "new_mod"), "`EmperorsTouch` encountered an error loading the Darktide Mod Framework.")

		new_mod("EmperorsTouch", {
			mod_script       = "EmperorsTouch/scripts/mods/EmperorsTouch/EmperorsTouch",
			mod_data         = "EmperorsTouch/scripts/mods/EmperorsTouch/EmperorsTouch_data",
			mod_localization = "EmperorsTouch/scripts/mods/EmperorsTouch/EmperorsTouch_localization",
		})
	end,
	packages = {},
}
