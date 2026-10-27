/*
 * WHAT A PLAYER DOES TO THE WINDOW, as plain functions: pause, step a frame, fast forward,
 * fullscreen, window size, volume and mute, which key and gamepad button is each console button,
 * the hotkeys, and the settings file that remembers it all.
 *
 * There is no SDL in this file and no Dear ImGui, and no window to open: it keeps the window's
 * settings and answers questions about them. The menu (rg_menu.cpp) is a thin layer that draws
 * these and calls these; a hotkey calls the very function its menu item calls; rg_sdl.c reads the
 * answers and does what they say to the real window, the speaker and the clock. Nothing the
 * window can do lives only in the menu. That is what lets all of it be tested with no window
 * (test_native_window.rb), as rg_pacing.h and rg_save.c are.
 *
 * The game never sees any of this. A hotkey is a key no console button is mapped to, so it is
 * the window's and never reaches the game (rg_window_bind_key and rg_window_bind_hotkey keep it
 * so), and everything here changes how the window shows and plays the game and never what the
 * game does.
 */
#ifndef RG_WINDOW_H
#define RG_WINDOW_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* The console's buttons, in the order rg_runtime.h numbers them: a, b, select, start, right,
 * left, up, down, r, l. */
#define RG_WINDOW_BUTTONS 10
/* Keys a button may have: Right Shift and Backspace are both Select by default. */
#define RG_WINDOW_KEYS_A_BUTTON 2

/* --- the keys that are not a console's: hotkeys --- */

typedef enum {
  RG_HOTKEY_PAUSE,        /* pause and resume */
  RG_HOTKEY_STEP,         /* while paused, run one frame */
  RG_HOTKEY_FRAME_RATE,   /* show or hide the frame rate */
  RG_HOTKEY_FULLSCREEN,   /* fullscreen on and off */
  RG_HOTKEY_MUTE,         /* mute and unmute */
  RG_HOTKEY_MENU,         /* open and close the menu (rg_window_menu.h) */
  RG_HOTKEY_FAST_FORWARD, /* held: several frames for every picture */
  RG_HOTKEY_COUNT
} rg_hotkey;

/* Keys and gamepad buttons are numbers: a key is an SDL scancode (the place on the keyboard, not
 * what is printed on it), nought for none; a gamepad button is an SDL_GamepadButton. rg_sdl.c
 * asserts that every number this file holds is SDL's, so this file need not include SDL. */
#define RG_NO_KEY 0
#define RG_KEY_ESCAPE 41 /* cancels choosing a key, and so cannot be one */

/* How a key is named in the settings file and the menu: the window hands over SDL's names
 * (SDL_GetScancodeName and SDL_GetScancodeFromName). Left alone, a key is "key 4". */
void rg_window_use_key_names(const char *(*name_of)(int key), int (*key_named)(const char *name));
const char *rg_window_key_name(int key);

/* What a button, a hotkey or a gamepad button is called to a player ("Select", "Fast forward",
 * "left shoulder"), and what each is called in the settings file ("select", "fast_forward",
 * "left_shoulder"). */
const char *rg_window_button_name(int button);
const char *rg_window_hotkey_name(int hotkey);
const char *rg_window_pad_button_name(int pad_button);
const char *rg_window_button_setting(int button);
const char *rg_window_hotkey_setting(int hotkey);
#define RG_WINDOW_PAD_BUTTONS 15 /* the ones a standard gamepad has: face, back, start, sticks, shoulders, d-pad */

/* --- pause, step and fast forward --- */

/* Paused, the game, its sound and its clock all stop and the picture stays. */
void rg_window_pause(void);
void rg_window_resume(void);
void rg_window_toggle_pause(void);
int rg_window_paused(void);

/* While paused, lets one frame run; a frame asked for when not paused is not kept for later. */
void rg_window_step(void);
/* The window asks, when paused, whether to let a frame run: 1 once for each step, which uses the
 * step up, and then 0. */
int rg_window_consume_step(void);

/* Fast forward is held: several frames of the game for every picture shown, at the speed
 * rg_window_fast_speed says (2 to 8, 4 to begin with). Only the window does this; a paused game
 * does not fast forward, and one that is let go of is back at the console's speed. */
#define RG_FAST_SPEED_LEAST 2
#define RG_FAST_SPEED_MOST 8
void rg_window_fast_forward(int held);
int rg_window_fast_forwarding(void);
void rg_window_set_fast_speed(int times);
int rg_window_fast_speed(void);

/* --- the window --- */

#define RG_WINDOW_SCALE_LEAST 1
#define RG_WINDOW_SCALE_MOST 10
#define RG_WINDOW_SCALE_START 3

/* The picture is a whole number of times the console's size, square pixels. The size is in the
 * window's own units, as the window was always opened at 3x. */
void rg_window_set_scale(int scale);
int rg_window_scale(void);
/* The window was dragged to this size (w by h, with the picture w_picture by h_picture): the
 * scale is the whole number of times the picture fits. Nothing is asked of the window for it,
 * since the player has just done it. A fullscreen window's size is the screen's, not a choice. */
void rg_window_size_changed(int width, int height, int picture_width, int picture_height);

void rg_window_set_fullscreen(int on);
void rg_window_toggle_fullscreen(void);
int rg_window_fullscreen(void);
/* The operating system took the window fullscreen or back (a Mac's green button): remembered as
 * it is, with nothing asked of the window. */
void rg_window_fullscreen_happened(int on);

/* What rg_sdl.c has still to do to the real window. Reading it clears it. */
#define RG_CHANGE_FULLSCREEN 1
#define RG_CHANGE_SCALE 2
int rg_window_consume_changes(void);

/* --- sound --- */

/* The player's volume, 0 to 100, on top of whatever the game does with its own, and mute. It is
 * applied as the sound goes to the speaker: the game's sound is never changed. */
void rg_window_set_volume(int percent);
int rg_window_volume(void);
void rg_window_set_mute(int on);
void rg_window_toggle_mute(void);
int rg_window_muted(void);
/* How much of the game's sound is let through, in 65536ths: nothing when muted, otherwise the
 * square of the volume (a volume of half is a quarter of the amplitude, which sounds about half
 * as loud), and all of it, untouched, at 100. */
uint32_t rg_window_gain(void);
/* The samples a frame of the game made, as they go to the speaker. */
void rg_window_apply_volume(int16_t *samples, size_t count);

/* --- what is shown over the picture --- */

void rg_window_set_show_frame_rate(int on);
void rg_window_toggle_frame_rate(void);
int rg_window_shows_frame_rate(void);
/* The frame time (the developer's view): how long the game's own work for a frame took, without
 * the wait for the next frame, so a game that keeps up shows how much of its frame it uses. It is
 * shown whether or not the frame rate is. */
void rg_window_set_show_frame_time(int on);
void rg_window_toggle_frame_time(void);
int rg_window_shows_frame_time(void);

/* The frame rate is how many frames of the GAME were played a second, so fast forward shows its
 * speed and a pause shows none. Every frame played is noted with the time it ended and how long the
 * game worked in it (both in nanoseconds), whether or not either is shown. What is asked for is
 * the last half second's: frames a second (0 for a game that has stopped), and the game's work in
 * a frame, in milliseconds. */
void rg_window_frame_played(uint64_t now_ns, uint64_t work_ns);
double rg_window_frames_a_second(uint64_t now_ns);
double rg_window_frame_work_ms(uint64_t now_ns);

/* Windows over the picture that can be open at once: the controls (keys, gamepad buttons and hotkeys) and the game's variables. */
typedef enum { RG_PANEL_CONTROLS, RG_PANEL_VARIABLES, RG_PANEL_COUNT } rg_panel;
void rg_window_show_panel(int panel, int shown);
int rg_window_panel_shown(int panel);
/* What a panel is called in a script (--scripted-keys) and in the menu; -1 for no such panel. */
const char *rg_window_panel_name(int panel);
int rg_window_panel_named(const char *name);

/* --- keys and gamepad buttons --- */

/* Which console button a key is, or -1; which hotkey, or -1. A key is never both. */
int rg_window_key_button(int key);
int rg_window_key_hotkey(int key);
/* The keys of a button (0 for the first, 1 for the second), RG_NO_KEY for none. */
int rg_window_button_key(int button, int slot);
int rg_window_hotkey_key(int hotkey);
/* The gamepad button that is a console button. */
int rg_window_pad_button(int button);

/* Choosing a key. Each says NULL when it is done, and otherwise why not, in a sentence a player
 * can read: a key that is another button's, or a hotkey's, is refused and nothing is changed
 * (the key is not taken from the one that has it behind the player's back). RG_NO_KEY clears. A
 * key a button already has in its other place is moved. The same sentence is the notice. */
const char *rg_window_bind_key(int button, int slot, int key);
const char *rg_window_bind_hotkey(int hotkey, int key);
/* A gamepad button taken by another console button swaps with it, so A and B can be swapped by
 * choosing one. Always done; the result is the same NULL as the others'. */
const char *rg_window_bind_pad(int button, int pad_button);
void rg_window_reset_keys(void);
void rg_window_reset_pad(void);
void rg_window_reset_hotkeys(void);

/* "Press the key you want for it": the menu says what is being chosen and the window gives the
 * next key, or gamepad button, pressed to these instead of to the game. Escape gives up. A wait for
 * a button, slot or hotkey that is not there is no wait. A key
 * or button is handed over only while a choice of that kind is waiting; the answer is 1 when it
 * was taken (and the window then does nothing else with it), and the notice says how it went. */
void rg_window_capture_key_for_button(int button, int slot);
void rg_window_capture_key_for_hotkey(int hotkey);
void rg_window_capture_pad_for_button(int button);
void rg_window_capture_cancel(void);
int rg_window_capturing(void);
int rg_window_capture_key(int key);
int rg_window_capture_pad(int pad_button);
/* What it was waiting for, to say so: the sentence "Press a key for Select..." and the like. */
const char *rg_window_capture_prompt(void);
/* The last thing the window has to say about a choice that did not go through, or "". */
const char *rg_window_notice(void);
void rg_window_clear_notice(void);

/* --- hotkeys --- */

/* A hotkey went down or came up. Most act on going down; fast forward is held. */
void rg_window_hotkey_changed(int hotkey, int down);

/* --- the variables of the running game, for the developer's view --- */

/* rg_sdl.c asks the game for its variables (rg_game_dump_state) while the window is open on them
 * and hands each to rg_window_watch_note. The menu reads them. */
void rg_window_watch_begin(void);
void rg_window_watch_note(const char *name, int32_t value);
int rg_window_watch_count(void);
const char *rg_window_watch_name(int i);
int32_t rg_window_watch_value(int i);
/* How many variables there were that there was no room to keep. */
int rg_window_watch_dropped(void);

/* --- the settings file --- */

/* What is remembered: the scale, fullscreen, volume and mute, whether the frame rate shows,
 * fast forward's speed, every key and gamepad button, and the hotkeys. One small text file,
 * `name = value` a line, `#` for a note. For example:
 *
 *   scale = 4
 *   volume = 60
 *   key.select = Backspace
 *   key.select = Right Shift
 *   pad.a = east
 *   hotkey.pause = P
 *
 * A key is named as SDL names it (the name in rg_window_key_name), "none" for no key; a button
 * says its key once for each key it has, and the first line for it replaces the default ones. A
 * line that cannot be used is left out and said in plain words, and the rest are used: a file
 * never stops the window starting. */
void rg_window_use_defaults(void);

/* Writes the settings as text of at most +room+ bytes, with the closing NUL; gives the length it
 * wanted (as snprintf does), so a result of +room+ or more was cut short. RG_SETTINGS_ALL writes
 * every setting, for the file every game shares; RG_SETTINGS_OWN only those the file being
 * written to holds for itself, for a game's own file. */
typedef enum { RG_SETTINGS_ALL, RG_SETTINGS_OWN } rg_settings_part;
size_t rg_window_settings_text(char *out, size_t room, rg_settings_part part);

/* Reads settings text over what is there now: each line it names a setting in replaces that one
 * and leaves the others, and that setting is now the file's own. Writes what it could not use
 * into +problems+ (NUL-ended, a sentence to a line, empty for none) and gives how many lines that
 * was. */
int rg_window_settings_read(const char *text, char *problems, size_t room);

/* Every setting so far came from somewhere else (the file every game shares) and is not the
 * own of the file that is read next, a game's: that file keeps only what it says and what is
 * changed while the game plays. */
void rg_window_mark_settings_inherited(void);

/* Whether the settings are due to be written, asked with the time (in nanoseconds). They are due
 * once half a second has gone by with nothing changed since something did, so dragging a slider
 * is one write; the half second starts the first time the window asks after a change. A write
 * that failed is owed still and tried again after the same wait. */
int rg_window_settings_due(uint64_t now_ns);
int rg_window_settings_unwritten(void);
void rg_window_mark_settings_written(void);
void rg_window_mark_settings_write_failed(void);
#define RG_SETTINGS_QUIET_NS 500000000ull

/* The sentences about the settings file as it was read. The controls panel shows them, and the
 * menu shows them over the picture as the window opens until the player has seen them, since a
 * player who opened the game by double-clicking it has no terminal to read. */
void rg_window_set_problems(const char *text);
const char *rg_window_problems(void);
int rg_window_problems_unseen(void);
void rg_window_mark_problems_seen(void);

#ifdef __cplusplus
}
#endif

#endif
