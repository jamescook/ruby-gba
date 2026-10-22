# The desktop window: menu, hotkeys, settings

What a player or a developer does to the window of a native build, as opposed to the game in it.
Code: `lib/ruby_gba/ir/backends/native/runtime/`.

## How it is cut

```
rg_window.h / rg_window.c   Plain C. Every setting and everything the menu can do, as functions: pause,
                            step, fast forward, size, fullscreen, volume, mute, which key is which
                            button, which gamepad button is which, the hotkeys, the settings text.
                            No SDL, no Dear ImGui, no file, no window. Tested on its own.
rg_menu.h / rg_menu.cpp     Dear ImGui over the picture. Only draws, and calls rg_window.h. Keeps nothing
                            of its own but what drawing needs (whether the mouse moved lately, a filter box).
rg_sdl.c                    Reads what rg_window.c says and does it to the real window, the speaker and
                            the clock; reads and writes the settings file; turns SDL's events into calls.
```

A hotkey, a menu item and a line of the settings file are three ways in to the same function. Nothing
the window can do lives only in the menu. The menu is in every build a person plays and is left out of
the tests' builds only because those are built as C with no window (`Zig.compile_without_sdl`), which
never reach `rg_sdl.c` or `build.zig`.

The game never sees any of it. A hotkey is a key no console button is mapped to: `rg_window_bind_key`
and `rg_window_bind_hotkey` refuse a key the other has, in a sentence a player can read, and a settings
file that gives one key to both keeps it on the button and says so. `rg_sdl.c` looks for a hotkey before
a button, so a hotkey is handed on to nothing.

## Decisions

- **A C++ file the C calls, not cimgui.** `rg_menu.cpp` is one file with a C header. cimgui would add a
  second repository to pin, a generator for its bindings and a C wrapper for every ImGui call the menu
  makes; the menu makes few, and the rest of the runtime never touches ImGui at all.
- **ImGui is its own library in the build.** `build.zig` compiles it into a static library with only
  ImGui's own folders on its include path. Given the game's folder (a new temporary one every build) zig
  compiles its six files again for every game; as a library it is compiled once and kept in the cache
  with SDL. Only `rg_menu.cpp`, which includes the runtime's headers, is compiled per game.
- **Pinned by commit and checked by hash**, as SDL is: `build.zig.zon` names ImGui v1.93.0 by its commit,
  `.lazy = true`, and zig refuses a download that differs by a byte. ImGui has no `build.zig`, so the few
  files wanted are named in ours: `imgui.cpp`, `imgui_draw.cpp`, `imgui_tables.cpp`, `imgui_widgets.cpp`
  and the SDL3 and SDL renderer backends. The demo and debug windows are compiled out
  (`IMGUI_DISABLE_DEMO_WINDOWS`, `IMGUI_DISABLE_DEBUG_TOOLS`).
- **The picture keeps SDL's logical size** and the menu puts it aside while it draws, so the picture is
  still a whole number of times 240x160 with square pixels exactly as before and the menu is laid out in
  the window's own units.
- **Pause, step, fast forward live inside `rg_wait_vblank`**, where the game already hands the thread
  to the window; no new thread, no callback style. A pause is a loop in `hold_while_paused` that keeps
  the menu and the hotkeys answering and re-shows the last picture; a step leaves that loop for one frame.
- **A pause is not the game running late.** Leaving a pause starts the console clock and the monitor's
  limit afresh (`restart_clocks`), and the speaker is emptied when it starts and let go when it
  ends, so the sound's catch-up rule (`keep_sound_in_step`, the quiet put in when little is waiting) is
  not told the game fell behind. `test_native_desktop.rb` holds this: without the reset a two-frame pause
  is followed by frames rushed to make it up, 2 ms apart; with it, none are under 10 ms.
- **Fast forward is slots of N frames** (2 to 8, 4 to begin with, a setting). The game runs every frame
  as it always does and only the showing and the waiting happen once a slot, so on a monitor that paces
  the game the monitor still does. **The sound is silence meanwhile** rather than every Nth slice: the
  game makes N times what the speaker can play, and slices of it are a stutter. The speaker is emptied
  when fast forward starts, and what is "owed" is not (the same `speaker_emptied_on_purpose` flag as a
  pause).
- **The frame time is the game's own work**, from when the window hands the game its thread back to
  when the game next waits for a frame, without the wait. A game that keeps up shows how much of its
  frame it uses; one over the frame shows by how much. It is under Developer, and shows with or without
  the frame rate. Both are measured every frame whether shown or not, so what is read is always the last
  half second's.
- **Volume is the square of the slider**, applied to the samples as they go to the speaker
  (`rg_window_apply_volume`): 50 is a quarter of the amplitude, which sounds about half as loud, and 100
  leaves the samples untouched. The game's sound, and every test that compares it, is as it was.
- **The keyboard's own gamepad keeps the console's layout.** The keyboard presses buttons of a gamepad
  SDL makes up and the window reads it like any other; what a player chooses is which button of a REAL
  gamepad is which. A gamepad button another console button has swaps with it, so A and B are swapped by
  choosing one.
- **Settings are `name = value` lines.** A button with two keys has a line for each (a comma is a key's
  name in SDL: ","). The first line for a button replaces the defaults, each after it adds one. Where it
  lives: one file for every game and one for each game, both read, the game's over the player's; a change
  is written to the game's file when there is one and otherwise the player's, so the file a player last
  edited is the one the menu keeps. **A game's file keeps only its own settings**: the lines it had and
  what was changed while the game played. Written whole, it would take in everything the player's file
  said and stop following it, so a key the player changed for every game later would never reach that
  one. The player's file is written whole. A file that cannot be read, or has lines that cannot be used,
  is said on the error stream, over the picture as the window opens (a player who double-clicked the
  game has no terminal), and in the controls window, and the rest is used. Written beside the old file
  and renamed over it, half a second by the clock after the last change (a slider dragged is one write,
  and fast forward does not shorten the wait).
- **A scripted run (`--scripted-keys`) reads no settings file** unless given one (`--settings-file`,
  or `--usual-settings` for the usual two), so a test never depends on the keys of whoever runs it.

## What a test can do to the window

`--scripted-keys FRAMES` reads a line a frame: the buttons held as a number and then words that press keys
through the window's own loop: `key:`, `keydown:`, `keyup:` by SDL's name; `hotkey:`, `hotkeydown:`,
`hotkeyup:` by the hotkey's name (the key it is on now); `panel:controls`, `panel:variables`. While paused
a line is read each time round the pause. `--window-picture FILE` saves the window as it ends, menu and all,
as a BMP. SDL's `disk` audio driver (`SDL_AUDIO_DRIVER=disk SDL_AUDIO_DISK_OUTPUT_FILE=...`) saves what the
speaker was given, which is how the volume, mute and fast forward's silence are checked end to end.

## Cost (x86-64 Linux, zig 0.17.0, SDL 3.4.18, Dear ImGui 1.93.0, pong)

| | without the menu | with it |
|---|---|---|
| a build, SDL already compiled | 3.0 s | 3.9 s |
| the first build that needs it | | once: 77 s, which is ImGui and zig's own libc++ compiled; 20 s when only ImGui is (libc++ already in zig's cache) |
| program, as built (ReleaseFast, with debug info) | 14.6 MB | 19.7 MB |
| program, stripped | 3.2 MB | 4.1 MB |

The first build on an empty cache was 182 s for SDL alone. Windows and ARM Linux builds with the menu
build and are checked to be programs for those systems (`test_native_desktop.rb`); like the rest of those
builds they have not been run there. A C library (Nuklear, microui) was not needed as the fallback.

## What Dusklight does, and what was taken

Read in `TwilitRealm/dusklight`, `src/dusk/imgui` (`ImGuiConsole.cpp`, `ImGuiMenuTools.cpp`,
`ImGuiEngine.cpp`):

- It draws `BeginMainMenuBar` with the window background made transparent so only the menu bar's own
  colour shows, and opens windows from its items for the larger tools. **Taken**: the bar, and a window
  for keys and another for the game's variables.
- It hides the whole overlay with a key (Shift+F1) and toggles each view with its own. **Taken**: F1 keeps
  the bar up; otherwise it shows for three seconds after the window opens or the mouse moves, and while a
  menu is open.
- It saves its configuration at the moment something changes (`config::save()`). **Taken**, with a half
  second's quiet first so a slider is not a write a frame.
- It reads F11 for fullscreen through ImGui's own key state, and its turbo is a time scale (4x). **Not
  taken**: here the hotkeys are the window's, read before ImGui and before the game, so one key cannot be
  both a hotkey and a button, and fast forward is frames per picture since the clock is the console's.
- It never pauses the game for its menu. Neither does this one: pause is a thing a player chooses.

## Not done: rewind and save states

The menu was asked to save and load a state, from its Developer menu. That is not built: a save state is
the whole game taken and put back once, and rewind is the same every frame, so both wait on the same
two things.

1. **State is in many places.** Besides the game's variables, lists and pools (generated `static`s in
   `game.c`), `rg_screen.c`, `rg_sound.c`, `rg_mix.c`, `rg_runtime.c` (timers) and `rg_save.c` each keep
   their own. Taking them needs one registry each file adds its state to (a pointer and a size), and a
   way to emit the game's own into it; that is also what a save state needs.
2. **The game is in the middle of a call.** The window is entered from inside `rg_wait_vblank`, called
   wherever the game likes. Putting variables back changes what the game knows, not where in its code it
   is: the C stack and the program counter are not in any registry. A game whose only wait is the top
   of its game loop is restored by its variables alone; one that waits deep inside a routine is not.
   Checking that every frame was taken at one call site and stack depth is not enough on its own: the
   generated C keeps some of the game's working numbers on the stack across a wait (a `repeat` keeps its
   count and its index there), so two frames that match on call site and depth can still differ in
   those. Either a state is taken only where the generated C holds nothing on the stack across the wait,
   or the loop has to be made a state machine, which is a change to the generated C and to every
   lowering.

Both want deciding before any code. What a rewind past a save does is also open: the save memory is the
one part that must not go back behind a player's back.
