# Emperor's Touch

## Description

Emperor's Touch connects Warhammer 40,000: Darktide to Lovense toys. Game
events drive your devices in real time: take health damage, break your
toughness, get grabbed by a disabler, or wipe the mission and your toys
respond. Continuous sources like your health and peril level can ramp
intensity smoothly as they change.

You define **presets** (which actions fire, how strong, for how long) in an
in-game editor, then assign a preset to any combination of **event × toy**.
Different toys can react to different events with different intensities —
all configured from inside the game, no files to edit.

## Installation instructions

1. Install the [Darktide Mod Loader](https://www.nexusmods.com/warhammer40kdarktide/mods/19)
   and the [Darktide Mod Framework](https://www.nexusmods.com/warhammer40kdarktide/mods/8)
   if you don't have them already.
2. Extract the `EmperorsTouch` folder into your `Warhammer 40,000 DARKTIDE/mods/` directory.
3. Add `EmperorsTouch` to your `mods/mod_load_order.txt`.
4. Install **Lovense Remote** for Windows on the same PC, pair your toy(s),
   and enable **Game Mode** in the app.
5. Launch the game. The mod finds your toys automatically on startup.

## Main features

- **17 game hooks** and counting:
  - *Continuous:* Health Level, Peril Level — intensity scales with the
    value, with a per-toy **Invert** option (e.g. stronger as you get hurt)
  - *Combat events:* Health Damage Taken, Toughness Broken (full break),
    Elite/Special Killed, Ability Used, Backstab Warning
  - *Disabler grabs:* Trapper net, Hound pounce, Mutant grab, Chaos Spawn
    grab, Beast of Nurgle swallow
  - *Squad & mission:* Knocked Down, Player Death, Ally Down, Ally Death,
    Mission Start, Boss Spawned, Hacking Complete, Mission Victory,
    Mission Defeat
- **In-game preset editor** (default **F9**): create named presets with
  sliders for every Lovense action — Vibrate, Rotate, Pump, Thrusting,
  Fingering, Suction, Depth, Stroke, Oscillate — plus duration and loop
  timing. Test any preset on any toy directly from the editor.
- **Per-toy assignment menu** (default **F10**): pick a toy, then assign a
  preset to each hook from dropdowns. Multiple toys with independent
  configurations are fully supported; commands to toys sharing a preset are
  batched into a single request.
- **Safety built in**: a panic keybind (default **F11**) stops all toys
  instantly; everything halts automatically at mission end; continuous
  output winds down if its source disappears (death, overload, downed).
- **Set-and-forget**: presets and assignments persist across sessions, keyed
  to each device, and toys are re-detected automatically at launch.

## Requirements

- [Darktide Mod Loader](https://www.nexusmods.com/warhammer40kdarktide/mods/19)
- [Darktide Mod Framework](https://www.nexusmods.com/warhammer40kdarktide/mods/8)
- **Lovense Remote** (Windows app) running **on the same PC as the game**,
  with Game Mode enabled. The mod talks to the app's local API at
  `127-0-0-1.lovense.club:30010`; remote setups (app on your phone) are not
  supported.
- At least one Lovense device paired to the app. No other mods are required.
