/*
 * The runtime with a window, through SDL3: what a player runs.
 *
 *   ./pong                               play it
 *   ./pong --headless FRAMES             the same program with no window (see rg_headless.c)
 *   ./pong --trace 2> buttons.log        play it, and write down what the window made of the buttons
 *   ./pong --scripted-keys FRAMES < keys play FRAMES frames with keys pressed from a script (tests)
 *   ./pong --frame-times                 play it, and say at the end how evenly its pictures were shown
 *   ./pong --refresh-rate 144            choose its pacing as for a monitor of that rate (this one still
 *                                        refreshes at its own, so a rate above it plays the game slow)
 *   ./pong --save-file my.sav            keep the game's save in that file, in place of the usual one
 *   ./pong --settings-file my.txt        read and write the window's settings (see THE SETTINGS) in that
 *                                        file alone, in place of the usual ones
 *   ./pong --usual-settings              with --scripted-keys, use the usual settings files as a player's run does
 *   ./pong --window-picture shot.bmp     with --scripted-keys, save the window as it ends (menu and all)
 *
 * A SCRIPT (--scripted-keys) is a line a frame: the console buttons held, as a number (a=1, b=2, select=4,
 * start=8, right=16, left=32, up=64, down=128, r=256, l=512), and then any of these words, each pressed
 * through the window's own loop as a player's fingers would:
 *
 *   key:NAME keydown:NAME keyup:NAME            a key by SDL's name for it, "_" for a space (Right_Shift)
 *   hotkey:NAME hotkeydown:NAME hotkeyup:NAME   the key a hotkey is on now: pause, step, frame_rate,
 *                                               fullscreen, mute, menu, fast_forward
 *   panel:NAME                                  open or shut a window of the menu: controls, variables
 *
 * While the game is paused a line is read for each time round the pause, and a script that runs out
 * while paused ends there.
 *
 * THE GAME OWNS THE LOOP. A game waits for the next frame wherever it likes — at the top of its
 * game loop, or deep inside a routine that runs before the loop starts — so it cannot hand
 * control back to SDL once a frame and be called again. Instead SDL is driven from inside
 * rg_wait_vblank: show the frame, read the window's events and the buttons, and wait for the
 * next frame's moment to come round. That is SDL3's ordinary main() rather than its callback
 * style, and the game runs on the program's first thread, which is where macOS wants a window
 * looked after.
 *
 * THE MONITOR PACES THE FRAMES WHERE IT CAN, AND THE CONSOLE'S CLOCK WHERE IT CANNOT. A game is
 * written to the console's pace, a little under sixty frames a second. On a monitor that
 * refreshes at very nearly a whole number of times that rate, each picture is shown for that
 * many refreshes and the game simply runs at the monitor's pace, a shade fast or slow; rg_pacing.h
 * says which monitors those are and why timing them from the console's clock stutters. The
 * window asks again whenever it is moved to another monitor or its monitor changes rate.
 *
 * On any other monitor the frames are timed from the console's clock. A game a frame or two late
 * then runs its next frames without waiting until it is back on time, so a moment's hitch does
 * not slow the game for good; one more than four frames late (the computer was asleep, the
 * window was being dragged) starts afresh from now instead, rather than racing through the
 * frames it missed.
 *
 * A clock stands behind the monitor too, for when the window is hidden and showing a picture
 * waits for nothing: the game is held to a pace a shade faster than the monitor's, which a monitor
 * that is doing its job never lets it reach (rg_pacing.h again, and keep_under_fastest).
 *
 * THE PICTURE is the console's 240x160 screen, its 15-bit colors handed to SDL as they are (SDL
 * has a pixel format for exactly that layout), and scaled up by a whole number with each pixel
 * kept square and sharp — never smoothed — and the window's spare room left black.
 *
 * THE BUTTONS ARE A GAMEPAD'S, AND THE KEYBOARD IS A GAMEPAD. The game is asked one question —
 * which of the console's ten buttons are down on any gamepad — and the keyboard answers it by
 * pressing the buttons of a gamepad SDL makes up for it (a "virtual joystick"), which is then
 * read exactly as a real one plugged in beside it is. One way in means a real controller needs
 * nothing of its own, and a test that presses keys goes down the same path a player's fingers do.
 *
 * The keys start as mGBA's, so a player who has used it already knows them: the arrows for
 * the pad, X for A, Z for B, A and S for the shoulders, Return for Start and Backspace for
 * Select — and Right Shift for Select as well, for a keyboard with no Backspace. They are read by
 * where they sit on the keyboard, not by what is printed on them. On a gamepad the buttons are
 * where the console has them: A on the right, B below it. A player can choose others (rg_window.h
 * keeps which key is which button and which gamepad button is which; the menu and the settings
 * file change them). The keyboard's own gamepad always has the console's layout: what a player
 * chooses is which button of a REAL gamepad is which.
 *
 * THE WINDOW'S OWN KEYS, THE HOTKEYS, are keys no console button is mapped to: pause, step a
 * frame, fullscreen, mute, the frame rate, the menu, and fast forward while held. They are looked
 * for before the buttons and never reach the game. A pause holds the game, its sound and its
 * clock where they are and keeps the picture up (hold_while_paused); neither the pacing nor the
 * sound counts the time as the game running late. Fast forward plays several frames for each
 * picture shown and makes no sound meanwhile, rather than a pile of it the speaker plays late.
 *
 * THE MENU is Dear ImGui (rg_menu.cpp) drawn over the picture, and does nothing but call the
 * plain functions of rg_window.h, as the hotkeys and the settings file do.
 *
 * THE SETTINGS are the scale, fullscreen, volume, mute, frame rate, fast forward's speed, the keys,
 * the gamepad buttons and the hotkeys, in one small text file a player can edit (rg_window.h says
 * its format). There is one for everyone who plays any game built this way, among the files the
 * operating system keeps for the person using the computer, and one for each game, in the game's
 * own folder beside its save. Both are read when the window opens, the game's over the player's. A
 * change is written back a moment after it is made (rg_window_settings_due): to the game's file
 * where it has one, which keeps only what it says itself and what was changed while the game
 * played, so the rest goes on following the player's file; otherwise to the player's, whole. A
 * file that cannot be read is said in plain words, over the picture as the window opens too, and
 * its defaults used: it never stops the window opening. A scripted run (--scripted-keys) uses none
 * unless told one with --settings-file, so a test never depends on the keys of whoever runs it.
 *
 * THE SOUND is made a frame at a time by rg_sound.c and handed to SDL as it is made (at the
 * player's volume, rg_window_apply_volume), which keeps
 * a little of it waiting so a frame that arrives a moment late is not heard as a gap. Where the
 * monitor paces the game a shade fast or slow, the sound is played that much faster or slower,
 * so as much is played as is made. A computer with nothing to play sound through still plays the
 * game.
 *
 * THE SAVE is a file, for a game that has save memory (rg_save.h): the bytes a cartridge's chip
 * would hold, which is what an emulator calls a .sav file, so one can be carried between the two.
 * It is kept where the operating system keeps a program's own files for the person using the
 * computer, in a folder named for the game, and read once before the game starts. It is written
 * a frame after the game has finished saving, and as the window closes. Writing never touches the
 * file that is there: a new file is written beside it and then takes its place in one step, so a
 * computer that stops part way through leaves the last save whole — the promise a cartridge makes
 * about its own chip.
 */
#include <SDL3/SDL.h>
#include <SDL3/SDL_main.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "rg_driver.h"
#include "rg_menu.h"
#include "rg_pacing.h"
#include "rg_runtime.h"
#include "rg_save.h"
#include "rg_screen.h"
#include "rg_sound.h"
#include "rg_window.h"

/* One frame of the console, in nanoseconds. */
#define FRAME_NS ((Uint64)RG_CONSOLE_TICKS_A_FRAME * 1000000000ull / RG_CONSOLE_TICKS_A_SECOND)

#define BUTTONS 10
/* As many gamepads as are read at once, the keyboard's among them. */
#define MOST_PADS 8

/* rg_window.c keeps the keys and gamepad buttons as numbers, so it needs no SDL; these are the
 * numbers it holds, and each is SDL's. */
#define SAME_AS_SDL(name, number) _Static_assert((int)(name) == (number), #name " is not the number rg_window.c holds for it")
SAME_AS_SDL(SDL_SCANCODE_UNKNOWN, RG_NO_KEY);
SAME_AS_SDL(SDL_SCANCODE_ESCAPE, RG_KEY_ESCAPE);
SAME_AS_SDL(SDL_SCANCODE_A, 4);
SAME_AS_SDL(SDL_SCANCODE_M, 16);
SAME_AS_SDL(SDL_SCANCODE_N, 17);
SAME_AS_SDL(SDL_SCANCODE_P, 19);
SAME_AS_SDL(SDL_SCANCODE_S, 22);
SAME_AS_SDL(SDL_SCANCODE_X, 27);
SAME_AS_SDL(SDL_SCANCODE_Z, 29);
SAME_AS_SDL(SDL_SCANCODE_RETURN, 40);
SAME_AS_SDL(SDL_SCANCODE_BACKSPACE, 42);
SAME_AS_SDL(SDL_SCANCODE_TAB, 43);
SAME_AS_SDL(SDL_SCANCODE_F1, 58);
SAME_AS_SDL(SDL_SCANCODE_F3, 60);
SAME_AS_SDL(SDL_SCANCODE_F11, 68);
SAME_AS_SDL(SDL_SCANCODE_RIGHT, 79);
SAME_AS_SDL(SDL_SCANCODE_LEFT, 80);
SAME_AS_SDL(SDL_SCANCODE_DOWN, 81);
SAME_AS_SDL(SDL_SCANCODE_UP, 82);
SAME_AS_SDL(SDL_SCANCODE_RSHIFT, 229);
SAME_AS_SDL(SDL_GAMEPAD_BUTTON_SOUTH, 0);
SAME_AS_SDL(SDL_GAMEPAD_BUTTON_EAST, 1);
SAME_AS_SDL(SDL_GAMEPAD_BUTTON_WEST, 2);
SAME_AS_SDL(SDL_GAMEPAD_BUTTON_NORTH, 3);
SAME_AS_SDL(SDL_GAMEPAD_BUTTON_BACK, 4);
SAME_AS_SDL(SDL_GAMEPAD_BUTTON_GUIDE, 5);
SAME_AS_SDL(SDL_GAMEPAD_BUTTON_START, 6);
SAME_AS_SDL(SDL_GAMEPAD_BUTTON_LEFT_STICK, 7);
SAME_AS_SDL(SDL_GAMEPAD_BUTTON_RIGHT_STICK, 8);
SAME_AS_SDL(SDL_GAMEPAD_BUTTON_LEFT_SHOULDER, 9);
SAME_AS_SDL(SDL_GAMEPAD_BUTTON_RIGHT_SHOULDER, 10);
SAME_AS_SDL(SDL_GAMEPAD_BUTTON_DPAD_UP, 11);
SAME_AS_SDL(SDL_GAMEPAD_BUTTON_DPAD_DOWN, 12);
SAME_AS_SDL(SDL_GAMEPAD_BUTTON_DPAD_LEFT, 13);
SAME_AS_SDL(SDL_GAMEPAD_BUTTON_DPAD_RIGHT, 14);
_Static_assert(BUTTONS == RG_WINDOW_BUTTONS, "the window and the runtime count the console's buttons differently");

/* The gamepad the keyboard presses has the console's own layout whatever a player has chosen for
 * a real one: A on the right, B below it. Console buttons in the order rg_runtime.h numbers them. */
static const SDL_GamepadButton keyboard_pad_buttons[BUTTONS] = {
  SDL_GAMEPAD_BUTTON_EAST,           /* a */
  SDL_GAMEPAD_BUTTON_SOUTH,          /* b */
  SDL_GAMEPAD_BUTTON_BACK,           /* select */
  SDL_GAMEPAD_BUTTON_START,          /* start */
  SDL_GAMEPAD_BUTTON_DPAD_RIGHT,     /* right */
  SDL_GAMEPAD_BUTTON_DPAD_LEFT,      /* left */
  SDL_GAMEPAD_BUTTON_DPAD_UP,        /* up */
  SDL_GAMEPAD_BUTTON_DPAD_DOWN,      /* down */
  SDL_GAMEPAD_BUTTON_RIGHT_SHOULDER, /* r */
  SDL_GAMEPAD_BUTTON_LEFT_SHOULDER,  /* l */
};
static const char *const button_names[BUTTONS] = {"a", "b", "select", "start", "right", "left", "up", "down", "r", "l"};

static SDL_Window *window;
static SDL_Renderer *renderer;
static SDL_Texture *texture;

static rg_pacing pacing = {0, 0, 1.0}; /* what paces the frames on the monitor the window is on */
static Uint64 next_frame_ns;           /* when the next frame is due, on the console's clock */
static Uint64 earliest_next_ns;        /* where the monitor paces: the moment before which the next may not begin */

/* --refresh-rate: the rate to pace for, whatever the monitor says its own is. */
static double pretended_refreshes_a_second;

/* --frame-times: when each picture was handed to the display, to say at the end how evenly they
 * were shown. A picture a monitor shows twice, or never, is one handed over late or early, and
 * this is the only way to see that without looking at the screen. */
static int timing_frames;
static Uint64 *shown_at_ns;
static size_t shown_count, shown_room;
static long frames_held_by_clock; /* frames the monitor was pacing and the window's own clock had to hold */
static long sound_frames_dropped; /* frames whose sound was thrown away because too much was waiting */
static long sound_ran_dry;        /* times quiet was put in because almost none was */
static int speaker_emptied_on_purpose;    /* the speaker was just emptied by a pause or fast forward, so quiet put in is not "ran dry" */

static SDL_AudioStream *speaker; /* where the sound goes; none on a computer with no sound */

/* How much sound may be waiting to be played, in frames' worth. Two are put in ahead whenever
 * there is less than a frame waiting — at the start, or after the game was held up — so a frame
 * a moment late does not leave the speaker with nothing. More than six waiting means the
 * speaker is behind the game, and a frame's sound is dropped to let it catch up. */
#define SOUND_AHEAD_FRAMES 2
#define SOUND_BEHIND_FRAMES 6
/* Between those two ends, the sound is played a shade faster or slower to keep this many frames'
 * worth waiting (see keep_sound_in_step): what there is just after two were put in ahead of one. */
#define SOUND_WAITING_FRAMES (SOUND_AHEAD_FRAMES + 1)
/* The most it is played faster or slower for that, in parts of a hundred. It has to be more than
 * the game can run ahead of the sound, which is as far as the limit behind the monitor lets it
 * run ahead of the monitor: a nudge that only just matched would settle with as much sound
 * waiting as is thrown away. */
#define SOUND_NUDGE_MOST_PERCENT 3
_Static_assert(SOUND_NUDGE_MOST_PERCENT > RG_FASTEST_PERCENT_OVER_MONITOR, "the sound cannot keep up with the game");

static SDL_Gamepad *pads[MOST_PADS]; /* every gamepad open, the keyboard's among them */
static SDL_Joystick *keyboard_pad;   /* the gamepad SDL makes up for the keyboard to press */
static SDL_JoystickID keyboard_pad_id;
static uint32_t keys_down;           /* the keys down now, a bit per button */
static uint32_t keys_tapped;         /* ...and those that went down since the buttons were last read */

/* --trace: say on the error stream what the window made of the buttons. A fault that only shows
 * with a real keyboard or controller cannot be seen by a test, so this is how a person shows it:
 * play, and send what it printed. */
static int tracing;
static uint32_t traced_buttons;
static int traced_frames_left;

/* --scripted-keys: keys pressed from standard input, a line a frame as --headless reads them,
 * but as key events through SDL and the window's own loop. It stops after its frames and prints
 * where the game's variables stand, the way --headless ends. */
static int scripted;
static long frames_to_play;
static long frames_played;
static uint32_t scripted_keys;
static int printing_script_end; /* the variables being printed are the script's last word */
static const char *window_picture_file; /* --window-picture: where the window is saved as the script ends */

/* The settings (rg_window.h) are kept in a file; the one that changes are written to, and the new
 * file written beside it that then takes its place, as the save is. None for a scripted run that
 * was not given one. */
static char *settings_path;
static char *settings_being_written;
static rg_settings_part settings_written_part; /* a game's own file keeps only its own settings */
static int settings_failure_said;

/* When the game was last handed back its thread, so the time until it next waits is its work. */
static Uint64 game_resumed_ns;

/* The game's variables are being asked for by the menu's developer window (rg_window_watch_note),
 * not printed. */
static int collecting_variables;

/* Fast forward: the frames played since the last picture was shown, and whether it was in force at
 * the last frame (so a change of speed is seen once). */
static int frames_in_slot;
static int was_fast_forwarding;

/* The file the game's save memory is kept in, and the new one written beside it that then takes
 * its place. Neither, for a game with no save memory. */
static char *save_path;
static char *save_being_written;
static int save_failure_said; /* a file that cannot be written is said once, not once a second */

static double in_ms(Uint64 ns) { return (double)ns / 1000000.0; }

/* Save memory written to its file, when it holds something the file does not: whole, to a new
 * file, which is then put in the old one's place. SDL's own renaming replaces a file that is
 * there on every system; C's does not on Windows. */
static void write_save_file(void) {
  if (!save_path || !rg_save_unwritten()) return;
  if (SDL_SaveFile(save_being_written, rg_save_bytes(), (size_t)rg_save_size()) &&
      SDL_RenamePath(save_being_written, save_path)) {
    rg_save_file_written();
    return;
  }
  if (!save_failure_said) fprintf(stderr, "%s cannot write its save to %s (%s)\n", rg_game_title, save_path, SDL_GetError());
  save_failure_said = 1;
}

static int by_length(const void *a, const void *b) {
  Uint64 one = *(const Uint64 *)a, other = *(const Uint64 *)b;
  return (one > other) - (one < other);
}

/* Whether a gap between two pictures is more than two milliseconds from the middle one. */
static int uneven_gap(Uint64 gap, Uint64 middle) { return (gap > middle ? gap - middle : middle - gap) > 2000000; }

/* --frame-times' last word, on the error stream: what paced the frames, whether the sound kept
 * step, and how far apart the pictures were handed to the display. An even run has them all
 * within a millisecond or two of the middle one; the pictures after which a gap was further out
 * than that are named, since a stutter is a clump of those. */
static void report_frame_times(void) {
  if (pacing.refreshes) {
    fprintf(stderr, "pacing: the monitor, %d refreshes a picture, the game at %.4f of the console's speed\n",
            pacing.refreshes, pacing.speed);
    fprintf(stderr, "frames the window's own clock had to hold back: %ld\n", frames_held_by_clock);
  } else {
    fprintf(stderr, "pacing: the console's clock, each picture %s\n",
            pacing.waits_for_refresh ? "waiting for a refresh" : "handed over as it is finished");
  }
  if (speaker) {
    /* Quiet is put in once at the start of any run: there is no sound waiting before any is made. */
    fprintf(stderr, "sound: %ld frames thrown away with too much waiting, %ld times quiet was put in with too little\n",
            sound_frames_dropped, sound_ran_dry);
  }
  if (shown_count < 2) return;

  /* The gaps between one picture and the next, in the order they came and sorted by length. */
  size_t count = shown_count - 1;
  Uint64 *gaps = malloc(2 * count * sizeof *gaps);
  if (!gaps) return;
  Uint64 *sorted = gaps + count;
  for (size_t i = 0; i < count; i++) sorted[i] = gaps[i] = shown_at_ns[i + 1] - shown_at_ns[i];
  qsort(sorted, count, sizeof *sorted, by_length);
  Uint64 middle = sorted[count / 2];
  fprintf(stderr, "pictures: %zu, %.2f to %.2f ms apart, %.2f in the middle\n", shown_count, in_ms(sorted[0]),
          in_ms(sorted[count - 1]), in_ms(middle));

  size_t uneven = 0;
  for (size_t i = 0; i < count; i++) uneven += (size_t)uneven_gap(gaps[i], middle);
  fprintf(stderr, "uneven (more than 2 ms from the middle): %zu", uneven);
  if (uneven) fprintf(stderr, ", after pictures");
  for (size_t i = 0; i < count; i++)
    if (uneven_gap(gaps[i], middle)) fprintf(stderr, " %zu", i + 1);
  fputc('\n', stderr);
  free(gaps);
}

/* Every way out of the program comes through here, so a save the file does not hold yet is
 * written on all of them. */
static void write_settings_file(void);

static _Noreturn void quit(int status) {
  write_save_file();
  write_settings_file();
  rg_menu_stop();
  if (timing_frames) report_frame_times();
  SDL_Quit();
  exit(status);
}

static _Noreturn void refuse_to_start(const char *what) {
  fprintf(stderr, "%s cannot start: %s (%s)\n", rg_game_title, what, SDL_GetError());
  quit(1);
}

/* The folder a game's save goes in is named for the game, and a folder's name can hold less than
 * a game's title can: a letter, a digit or a space stays, and anything else becomes an
 * underscore. */
static void name_save_folder(char *name, size_t room) {
  size_t length = 0;
  for (const char *c = rg_game_title; *c && length + 1 < room; c++) {
    name[length++] = SDL_isalnum((unsigned char)*c) || *c == ' ' ? *c : '_';
  }
  name[length] = '\0';
  if (length == 0) SDL_strlcpy(name, "game", room);
}

/* Decides where the save is kept, for a game that has save memory: the file +asked+ for
 * (--save-file), or else save.sav in the game's own folder among the files the operating system
 * keeps for each program and each person — which SDL finds, and makes if it is not there. */
static void choose_save_file(const char *asked) {
  if (rg_save_size() == 0) return;
  if (asked) {
    save_path = SDL_strdup(asked);
  } else {
    char game[64];
    name_save_folder(game, sizeof game);
    char *folder = SDL_GetPrefPath("ruby-gba", game);
    if (!folder) refuse_to_start("the folder for its save cannot be made");
    if (SDL_asprintf(&save_path, "%ssave.sav", folder) < 0) save_path = NULL;
    SDL_free(folder);
  }
  if (!save_path || SDL_asprintf(&save_being_written, "%s.writing", save_path) < 0) {
    refuse_to_start("there is no room for the name of its save file");
  }
}

/* Reads the save the last run left, before the game starts. No file there is a new cartridge. A
 * file that is there and cannot be read, or is not as big as the game's save memory, is another
 * game's or a damaged one, and the game does not start: carrying on would write over it. */
static void read_save_file(void) {
  if (!save_path || !SDL_GetPathInfo(save_path, NULL)) return;
  size_t size = 0;
  void *held = SDL_LoadFile(save_path, &size);
  if (held && size == (size_t)rg_save_size()) {
    SDL_memcpy(rg_save_bytes(), held, size);
    SDL_free(held);
    return;
  }

  char message[512];
  snprintf(message, sizeof message,
           "The file at %s is not a save of this game, whose save is %d bytes. Move the file away, and the game "
           "starts a new one.",
           save_path, (int)rg_save_size());
  fprintf(stderr, "%s cannot start: %s\n", rg_game_title, message);
  SDL_ShowSimpleMessageBox(SDL_MESSAGEBOX_ERROR, rg_game_title, message, window);
  quit(1);
}

/* --- the settings file (rg_window.h says what is in it and how it is read) --- */

static const char *scancode_name(int key) { return SDL_GetScancodeName((SDL_Scancode)key); }
static int scancode_named(const char *name) { return (int)SDL_GetScancodeFromName(name); }

/* The settings in the file at +path+, read over those there are, and any lines it could not use
 * added to +said+ (+room+ bytes) with the file's name. A file that is not there is no problem: a
 * player who has never changed anything has none. One that is there and cannot be read is. */
static void read_settings_file(const char *path, char *said, size_t room) {
  if (!SDL_GetPathInfo(path, NULL)) return;
  size_t size = 0;
  void *loaded = SDL_LoadFile(path, &size);
  size_t used = strlen(said);
  if (!loaded) {
    snprintf(said + used, room - used, "The window cannot read %s (%s), so the settings are as they start.\n", path, SDL_GetError());
    return;
  }
  char *text = malloc(size + 1);
  if (text) {
    memcpy(text, loaded, size);
    text[size] = '\0';
    char problems[1024];
    if (rg_window_settings_read(text, problems, sizeof problems) > 0)
      snprintf(said + used, room - used, "%s:\n%s", path, problems);
    free(text);
  }
  SDL_free(loaded);
}

/* The settings file inside the folder the operating system keeps for +folder+ (a game's name, or
 * the one folder every game shares), or NULL when the folder cannot be made. */
static char *settings_file_in(const char *folder) {
  char *base = SDL_GetPrefPath("ruby-gba", folder);
  if (!base) return NULL;
  char *path = NULL;
  if (SDL_asprintf(&path, "%ssettings.txt", base) < 0) path = NULL;
  SDL_free(base);
  return path;
}

/* Starts the settings as the file or files say, before the window opens. +asked+ is the file
 * --settings-file named, which is then the only one there is. */
static void load_settings(const char *asked, int usual_files_asked) {
  rg_window_use_key_names(scancode_name, scancode_named);
  rg_window_use_defaults();
  char said[2048] = "";

  if (asked) {
    settings_path = SDL_strdup(asked);
    read_settings_file(asked, said, sizeof said);
  } else if (!scripted || usual_files_asked) {
    char game[64];
    name_save_folder(game, sizeof game);
    char *everyones = settings_file_in("(all games)");
    char *this_games = settings_file_in(game);
    if (everyones) read_settings_file(everyones, said, sizeof said);
    int game_has_its_own = this_games && SDL_GetPathInfo(this_games, NULL);
    if (game_has_its_own) {
      /* What the player's file said is the player's, and the game's file keeps only its own. */
      rg_window_mark_settings_inherited();
      read_settings_file(this_games, said, sizeof said);
      settings_written_part = RG_SETTINGS_OWN;
    }
    /* Changes go where the player last looked for them: the game's file when it has one. */
    settings_path = game_has_its_own ? this_games : everyones;
    if (settings_path != this_games) SDL_free(this_games);
    if (settings_path != everyones) SDL_free(everyones);
  }
  if (settings_path && SDL_asprintf(&settings_being_written, "%s.writing", settings_path) < 0) settings_being_written = NULL;

  if (said[0]) {
    fprintf(stderr, "%s: the window cannot use some of the settings file:\n%s", rg_game_title, said);
    rg_window_set_problems(said);
  }
}

/* The settings written to their file when something has changed, as the save is: to a new file
 * beside it, which then takes its place. */
static void write_settings_file(void) {
  if (!rg_window_settings_unwritten()) return;
  if (!settings_path || !settings_being_written) {
    rg_window_mark_settings_written(); /* a run with no file keeps nothing */
    return;
  }
  static char text[8192];
  size_t wanted = rg_window_settings_text(text, sizeof text, settings_written_part);
  if (wanted < sizeof text && SDL_SaveFile(settings_being_written, text, wanted) &&
      SDL_RenamePath(settings_being_written, settings_path)) {
    rg_window_mark_settings_written();
    return;
  }
  if (!settings_failure_said) fprintf(stderr, "%s cannot write its settings to %s (%s)\n", rg_game_title, settings_path, SDL_GetError());
  settings_failure_said = 1;
  rg_window_mark_settings_write_failed();
}

/* Each file that is owed is written: the save once the game has finished saving, the settings once
 * nothing has changed for a moment. */
static void write_files_due(void) {
  if (rg_save_file_is_due()) write_save_file();
  if (rg_window_settings_due(SDL_GetTicksNS())) write_settings_file();
}

/* Does to the real window what the settings now say: fullscreen on or off, and the size. */
static void apply_window_changes(void) {
  static int size_owed;
  int changes = rg_window_consume_changes();
  if (!changes) return;
  if (changes & RG_CHANGE_SCALE) size_owed = 1;
  if (changes & RG_CHANGE_FULLSCREEN) {
    if (SDL_SetWindowFullscreen(window, rg_window_fullscreen() != 0)) SDL_SyncWindow(window);
    else rg_window_fullscreen_happened((SDL_GetWindowFlags(window) & SDL_WINDOW_FULLSCREEN) != 0);
  }
  if (size_owed && !rg_window_fullscreen()) {
    SDL_SetWindowSize(window, RG_SCREEN_WIDTH * rg_window_scale(), RG_SCREEN_HEIGHT * rg_window_scale());
    size_owed = 0;
  }
}

/* Works out what paces the frames from the monitor the window is on now, and tells the display
 * whether a picture is to wait for a refresh. The speaker follows the pacing as each frame's
 * sound is handed over (keep_sound_in_step).
 *
 * The display is only ever asked to wait for ONE refresh a picture. A picture meant for several
 * is handed over that many times instead (see present): every way SDL has of drawing can wait for
 * one refresh, and not all of them can be told to hold a picture for two. */
static void choose_pacing(void) {
  double refreshes_a_second = pretended_refreshes_a_second;
  if (!(refreshes_a_second > 0.0)) {
    const SDL_DisplayMode *mode = SDL_GetCurrentDisplayMode(SDL_GetDisplayForWindow(window));
    refreshes_a_second = mode ? (double)mode->refresh_rate : 0.0;
  }
  pacing = rg_pacing_for(refreshes_a_second);
  /* A display that cannot be made to wait is one that does not say its rate, as far as pacing goes. */
  if (pacing.waits_for_refresh && !SDL_SetRenderVSync(renderer, 1)) pacing = rg_pacing_for(0.0);
  if (!pacing.waits_for_refresh) SDL_SetRenderVSync(renderer, 0);
  earliest_next_ns = 0;
}

/* --frame-times: the moment a picture was handed over is kept, for the report at the end. */
static void remember_picture_shown(void) {
  if (shown_count == shown_room) {
    size_t room = shown_room ? shown_room * 2 : 4096;
    Uint64 *grown = realloc(shown_at_ns, room * sizeof *grown);
    if (!grown) return;
    shown_at_ns = grown;
    shown_room = room;
  }
  shown_at_ns[shown_count++] = SDL_GetTicksNS();
}

/* The picture in the texture, the menu over it. Not yet shown: the picture is scaled by a whole
 * number through the renderer's logical size, which the menu puts aside while it draws. */
static void draw_window(void) {
  SDL_SetRenderDrawColor(renderer, 0, 0, 0, 255);
  SDL_RenderClear(renderer);
  SDL_RenderTexture(renderer, texture, NULL, NULL);
  rg_menu_draw(SDL_GetTicksNS());
}

/* Asks the game for its variables while the menu's window of them is open. */
static void watch_variables(void) {
  if (!rg_window_panel_shown(RG_PANEL_VARIABLES)) return;
  rg_window_watch_begin();
  collecting_variables = 1;
  rg_game_dump_state();
  collecting_variables = 0;
}

/* Shows the picture as it stands: once, or where the monitor paces the frames, once for each
 * refresh a picture is shown for, each waiting for its refresh. */
static void present(void) {
  SDL_UpdateTexture(texture, NULL, rg_screen_shown(), RG_SCREEN_WIDTH * (int)sizeof(uint16_t));
  watch_variables();
  int times = pacing.refreshes ? pacing.refreshes : 1;
  for (int i = 0; i < times; i++) {
    draw_window();
    SDL_RenderPresent(renderer);
  }
  if (timing_frames) remember_picture_shown();
}

/* The picture that is already up, shown again for a paused game: the menu still moves under the
 * player's mouse. Not one of the game's pictures, so --frame-times does not count it. */
static void present_still(void) {
  watch_variables();
  draw_window();
  SDL_RenderPresent(renderer);
}

/* The window as the last picture drew it, menu and all, saved as a BMP: a test's way to see it. */
static void save_window_picture(void) {
  draw_window();
  SDL_Surface *seen = SDL_RenderReadPixels(renderer, NULL);
  if (!seen || !SDL_SaveBMP(seen, window_picture_file))
    fprintf(stderr, "%s cannot save the window to %s (%s)\n", rg_game_title, window_picture_file, SDL_GetError());
  SDL_DestroySurface(seen);
}

/* THE SOUND IS KEPT IN STEP WITH THE GAME by playing it a shade faster or slower. A frame of the
 * game makes a frame of sound, and how many frames there are in a second is the monitor's doing
 * where it paces the game (rg_pacing.h), so the sound is played at the game's pace to begin with.
 * That alone is not enough: neither a monitor nor a sound card runs at exactly the rate it says,
 * so a little more sound is made than played, or a little less, all the time. Left alone that
 * piles up until some has to be thrown away, or runs dry, and either is a click.
 *
 * So the pace is nudged by how much is waiting: faster the more there is past what should be
 * waiting, slower the less, and never by more than SOUND_NUDGE_MOST_PERCENT of itself. On a
 * monitor that is pacing the game the nudge is a small part of that, too little to hear as a
 * change of pitch. */
static void keep_sound_in_step(int waiting, int frame_bytes) {
  double wanted = (double)(SOUND_WAITING_FRAMES * frame_bytes);
  double over = ((double)waiting - wanted) / wanted;
  if (over > 1.0) over = 1.0;
  if (over < -1.0) over = -1.0;
  SDL_SetAudioStreamFrequencyRatio(speaker, (float)(pacing.speed * (1.0 + SOUND_NUDGE_MOST_PERCENT / 100.0 * over)));
}

/* The sound of the frame that has just been played goes to the speaker. It is made whether or
 * not there is a speaker, since making it is what moves the voices on. */
static void play_frame_sound(void) {
  int16_t samples[RG_SOUND_FRAME_MOST];
  int count = (int)rg_sound_render_frame(samples);
  if (!speaker || count <= 0) return;
  /* Paused, or fast forwarding, the speaker is given nothing: it was emptied when that began. */
  if (rg_window_paused() || rg_window_fast_forwarding()) return;
  rg_window_apply_volume(samples, (size_t)count);

  int bytes = count * (int)sizeof samples[0];
  int waiting = SDL_GetAudioStreamQueued(speaker);
  keep_sound_in_step(waiting, bytes);
  if (waiting > SOUND_BEHIND_FRAMES * bytes) {
    sound_frames_dropped++;
    return;
  }
  if (waiting < bytes) {
    static const int16_t quiet[RG_SOUND_FRAME_MOST];
    for (int i = 0; i < SOUND_AHEAD_FRAMES; i++) SDL_PutAudioStreamData(speaker, quiet, bytes);
    /* After a pause or fast forward the speaker is empty on purpose: not the game running late. */
    if (!speaker_emptied_on_purpose) sound_ran_dry++;
    speaker_emptied_on_purpose = 0;
  }
  SDL_PutAudioStreamData(speaker, samples, bytes);
}

/* One speaker's worth of whole numbers, as rg_sound.c makes them; SDL turns that into whatever
 * the computer's own sound wants. */
static void open_speaker(void) {
  if (!SDL_InitSubSystem(SDL_INIT_AUDIO)) return;
  SDL_AudioSpec made = {SDL_AUDIO_S16, 1, RG_SOUND_RATE};
  speaker = SDL_OpenAudioDeviceStream(SDL_AUDIO_DEVICE_DEFAULT_PLAYBACK, &made, NULL, NULL);
  if (speaker) SDL_ResumeAudioStreamDevice(speaker);
}

/* A gamepad arrived — a real one plugged in, or the keyboard's own — and is read from now on. */
static void open_pad(SDL_JoystickID id) {
  for (int i = 0; i < MOST_PADS; i++) {
    if (pads[i]) continue;
    pads[i] = SDL_OpenGamepad(id);
    return;
  }
}

static void close_pad(SDL_JoystickID id) {
  for (int i = 0; i < MOST_PADS; i++) {
    if (!pads[i] || SDL_GetGamepadID(pads[i]) != id) continue;
    SDL_CloseGamepad(pads[i]);
    pads[i] = NULL;
  }
}

/* A key went down or came up. A key held makes the keyboard send it again and again, which is
 * not a second press, so those are passed over.
 *
 * A key being chosen for a button or a hotkey is taken for that, and not played. A hotkey is the
 * window's own and is not handed on; a key a console button has is the button. A text box in the
 * menu keeps the keys typed into it from the game, but not their coming up, so a button that
 * went down is never left held. */
static void key_changed(const SDL_KeyboardEvent *key) {
  if (key->repeat) return;
  int code = (int)key->scancode;
  if (key->down && rg_window_capture_key(code)) return;
  if (key->down && rg_menu_wants_keyboard()) return;

  int hotkey = rg_window_key_hotkey(code);
  if (hotkey >= 0) {
    rg_window_hotkey_changed(hotkey, key->down);
    return;
  }
  int button = rg_window_key_button(code);
  if (button < 0) return;
  uint32_t bit = 1u << (uint32_t)button;
  if (key->down) {
    keys_down |= bit;
    keys_tapped |= bit;
  } else {
    keys_down &= ~bit;
  }
}

/* A gamepad button went down: if a button of the console is waiting to be given one, this is it.
 * The keyboard's own gamepad is not a player's choice. */
static void pad_button_down(const SDL_GamepadButtonEvent *button) {
  if (button->which == keyboard_pad_id) return;
  rg_window_capture_pad((int)button->button);
}

/* Everything the window has to say: closing it ends the game, a key presses the keyboard's
 * gamepad, a gamepad plugged in or pulled out is taken up or let go, and a window moved to
 * another monitor, or a monitor set to another rate, is paced afresh. */
static void read_events(void) {
  SDL_Event event;
  while (SDL_PollEvent(&event)) {
    rg_menu_event(&event);
    switch (event.type) {
    case SDL_EVENT_QUIT:
      quit(0);
    case SDL_EVENT_KEY_DOWN:
    case SDL_EVENT_KEY_UP:
      key_changed(&event.key);
      break;
    case SDL_EVENT_GAMEPAD_BUTTON_DOWN:
      pad_button_down(&event.gbutton);
      break;
    case SDL_EVENT_WINDOW_RESIZED:
      rg_window_size_changed(event.window.data1, event.window.data2, RG_SCREEN_WIDTH, RG_SCREEN_HEIGHT);
      break;
    case SDL_EVENT_WINDOW_ENTER_FULLSCREEN:
      rg_window_fullscreen_happened(1);
      break;
    case SDL_EVENT_WINDOW_LEAVE_FULLSCREEN:
      rg_window_fullscreen_happened(0);
      break;
    case SDL_EVENT_GAMEPAD_ADDED:
      open_pad(event.gdevice.which);
      break;
    case SDL_EVENT_GAMEPAD_REMOVED:
      close_pad(event.gdevice.which);
      break;
    case SDL_EVENT_WINDOW_DISPLAY_CHANGED:
    case SDL_EVENT_DISPLAY_CURRENT_MODE_CHANGED:
      choose_pacing();
      break;
    default:
      break;
    }
  }
}

/* The window's events read, and what they asked of the real window done to it. */
static void read_and_apply_events(void) {
  read_events();
  apply_window_changes();
}

/* Waits for the next frame's moment on the console's clock. */
static void wait_on_console_clock(void) {
  Uint64 now = SDL_GetTicksNS();
  if (next_frame_ns == 0 || now > next_frame_ns + 4 * FRAME_NS) next_frame_ns = now; /* fell behind: start afresh */
  next_frame_ns += FRAME_NS;
  now = SDL_GetTicksNS();
  if (next_frame_ns > now) SDL_DelayPrecise(next_frame_ns - now);
}

/* Holds a game the monitor paces to the fastest it may go (rg_pacing.h), by a clock of the
 * window's own. On a monitor that is holding the game it does nothing. With the window hidden or
 * minimised, when showing a picture waits for nothing, it is all that paces the game. */
static void keep_under_fastest(void) {
  Uint64 now = SDL_GetTicksNS();
  earliest_next_ns = rg_earliest_next_frame(earliest_next_ns, now, rg_fastest_frame_ns(pacing));
  if (earliest_next_ns <= now) return;
  frames_held_by_clock++;
  SDL_DelayPrecise(earliest_next_ns - now);
}

/* The end of a frame. Where the monitor paces the frames, showing the picture has already waited
 * for the monitor, and all that is left is to see the game is not running away. */
static void wait_for_next_frame(void) {
  if (pacing.refreshes) keep_under_fastest();
  else wait_on_console_clock();
}

/* Every frame the buttons change, and the two after it (so what the game did about a press is
 * there to read): the buttons held, the ones that count as just pressed, and every variable. */
static void trace_frame(uint32_t held) {
  if (held != traced_buttons) traced_frames_left = 3;
  traced_buttons = held;
  if (traced_frames_left == 0) return;
  traced_frames_left--;

  fprintf(stderr, "frame %ld held", frames_played);
  for (int32_t i = 0; i < BUTTONS; i++)
    if (rg_held(i)) fprintf(stderr, " %s", button_names[i]);
  fprintf(stderr, " | pressed");
  for (int32_t i = 0; i < BUTTONS; i++)
    if (rg_pressed(i)) fprintf(stderr, " %s", button_names[i]);
  fprintf(stderr, " |");
  rg_game_dump_state();
  fputc('\n', stderr);
}

/* The keyboard presses its gamepad's buttons, and then every gamepad is read: a button down on
 * any of them is down. A key that went down and came up again between two frames still counts
 * for the frame that follows, so a quick tap is never lost. A real gamepad is read by the buttons
 * a player has chosen for it; the keyboard's has the console's layout, whatever was chosen. */
static void read_buttons(void) {
  uint32_t keyboard = keys_down | keys_tapped;
  keys_tapped = 0;
  for (uint32_t i = 0; i < BUTTONS; i++) SDL_SetJoystickVirtualButton(keyboard_pad, keyboard_pad_buttons[i], (keyboard >> i) & 1u);
  SDL_UpdateGamepads();

  uint32_t held = 0;
  for (int pad = 0; pad < MOST_PADS; pad++) {
    if (!pads[pad]) continue;
    bool keyboards = SDL_GetGamepadID(pads[pad]) == keyboard_pad_id;
    for (uint32_t i = 0; i < BUTTONS; i++) {
      SDL_GamepadButton button = keyboards ? keyboard_pad_buttons[i] : (SDL_GamepadButton)rg_window_pad_button((int)i);
      if (SDL_GetGamepadButton(pads[pad], button)) held |= 1u << i;
    }
  }
  rg_buttons_read(held);
  if (tracing) trace_frame(held);
}

/* A key as a script names it: SDL's name for it, with an underscore for each space (Right_Shift). */
static SDL_Scancode scripted_key_named(const char *name) {
  char spaced[64];
  size_t i = 0;
  for (; name[i] && i + 1 < sizeof spaced; i++) spaced[i] = name[i] == '_' ? ' ' : name[i];
  spaced[i] = '\0';
  return SDL_GetScancodeFromName(spaced);
}

static void push_key(SDL_Scancode key, bool down) {
  SDL_Event event;
  SDL_zero(event);
  event.type = down ? SDL_EVENT_KEY_DOWN : SDL_EVENT_KEY_UP;
  event.key.scancode = key;
  event.key.down = down;
  SDL_PushEvent(&event);
}

/* A scripted run's last word: every variable, as --headless prints them at its end. */
static _Noreturn void finish_script(void) {
  if (window_picture_file) save_window_picture();
  puts("end");
  printing_script_end = 1;
  rg_game_dump_state();
  fflush(stdout);
  quit(0);
}

static _Noreturn void refuse_script(const char *word) {
  fprintf(stderr, "%s: the script has \"%s\", which is not a button mask or one of key:, keydown:, keyup:, hotkey:, hotkeydown:, "
                  "hotkeyup: or panel: with a name\n", rg_game_title, word);
  quit(2);
}

/* One word of a script line after its buttons: a key pressed by name, or the key a hotkey is on
 * now pressed (so what is tried is the key a player would press, which goes the way a player's
 * does, through the window's loop), or a panel of the menu opened or shut. */
static void apply_script_word(char *word) {
  char *name = strchr(word, ':');
  if (!name) refuse_script(word);
  *name++ = '\0';
  bool is_hotkey = strncmp(word, "hotkey", 6) == 0;
  const char *how = word + (is_hotkey ? 6 : 3);
  if (strcmp(word, "panel") == 0) {
    int panel = rg_window_panel_named(name);
    if (panel < 0) refuse_script(name);
    rg_window_show_panel(panel, !rg_window_panel_shown(panel));
    return;
  }
  if (!is_hotkey && strncmp(word, "key", 3) != 0) refuse_script(word);
  SDL_Scancode key = SDL_SCANCODE_UNKNOWN;
  if (is_hotkey) {
    for (int h = 0; h < RG_HOTKEY_COUNT; h++)
      if (strcmp(rg_window_hotkey_setting(h), name) == 0) key = (SDL_Scancode)rg_window_hotkey_key(h);
  } else {
    key = scripted_key_named(name);
  }
  if (key == SDL_SCANCODE_UNKNOWN) refuse_script(name);
  if (strcmp(how, "") == 0) {
    push_key(key, true);
    push_key(key, false);
  } else if (strcmp(how, "down") == 0) {
    push_key(key, true);
  } else if (strcmp(how, "up") == 0) {
    push_key(key, false);
  } else {
    refuse_script(word);
  }
}

/* The key a script presses for a console button: the first it has, or RG_NO_KEY for none. */
static int first_key_of(int button) {
  for (int slot = 0; slot < RG_WINDOW_KEYS_A_BUTTON; slot++) {
    int key = rg_window_button_key(button, slot);
    if (key != RG_NO_KEY) return key;
  }
  return RG_NO_KEY;
}

/* A button with no key cannot be pressed from the keyboard at all, so a script that holds one
 * stops there and says so, rather than playing on as if it had not. */
static _Noreturn void refuse_script_button_without_key(int button) {
  const char *name = rg_window_button_name(button);
  fprintf(stderr, "%s: the script holds %s, but %s has no key. Give %s a key in the settings file.\n", rg_game_title, name, name,
          name);
  quit(2);
}

/* The script's keys for the frame that is starting, a line of standard input: the buttons held
 * as a number (as --headless reads them), each one that changed sent as the key event a keyboard
 * would send, and then any words naming keys, hotkeys or panels. Says whether there was a line:
 * a script that has run out holds nothing down. */
static bool press_scripted_keys(void) {
  char line[512];
  bool had_a_line = fgets(line, sizeof line, stdin) != NULL;
  if (!had_a_line) line[0] = '\0';
  char *word = strtok(line, " \t\r\n");
  unsigned long mask = 0;
  if (word && word[0] >= '0' && word[0] <= '9') {
    mask = strtoul(word, NULL, 10);
    word = strtok(NULL, " \t\r\n");
  }
  for (uint32_t i = 0; i < BUTTONS; i++) {
    bool down = (mask >> i) & 1u;
    if (down == (bool)((scripted_keys >> i) & 1u)) continue;
    int key = first_key_of((int)i);
    if (key == RG_NO_KEY) refuse_script_button_without_key((int)i);
    push_key((SDL_Scancode)key, down);
  }
  scripted_keys = (uint32_t)mask;
  for (; word; word = strtok(NULL, " \t\r\n")) apply_script_word(word);
  return had_a_line;
}

/* Fresh clocks, for after the game was held and is going again: the time that went by is no
 * lateness, and no frames are owed to make it up. */
static void restart_clocks(void) {
  next_frame_ns = 0;
  earliest_next_ns = 0;
}

/* The speaker is emptied whenever the game stops making sound at the pace it plays (a pause, fast
 * forward), and is let run again once it does. What is queued would otherwise play late, and what
 * the game is held back from making is not owed. */
static void silence_speaker(bool silent) {
  if (!speaker) return;
  if (silent) {
    SDL_PauseAudioStreamDevice(speaker);
    SDL_ClearAudioStream(speaker);
  } else {
    SDL_ResumeAudioStreamDevice(speaker);
  }
  speaker_emptied_on_purpose = 1;
}

/* A PAUSE: the game, its sound and its clock stop where they are and the picture stays up, while
 * the window goes on answering the menu, the hotkeys and the player's mouse. A step lets the game
 * run one frame and comes straight back here at the end of it. */
static void hold_while_paused(void) {
  if (!rg_window_paused()) return;
  silence_speaker(true);
  while (rg_window_paused() && !rg_window_consume_step()) {
    Uint64 began = SDL_GetTicksNS();
    if (scripted && !press_scripted_keys()) finish_script(); /* nothing left in the script could end the pause */
    read_and_apply_events();
    write_files_due();
    present_still();
    /* Showing a picture does not always wait (a window that is hidden, or a display that cannot be
     * waited for), and a pause is not to spin the computer. */
    Uint64 spent = SDL_GetTicksNS() - began;
    if (spent < FRAME_NS) SDL_DelayPrecise(FRAME_NS - spent);
  }
  restart_clocks();
  if (!rg_window_paused()) silence_speaker(false);
}

/* FAST FORWARD plays several frames of the game for each picture shown (a "slot"): everything the
 * game does is done on every frame, and only the showing and the waiting happen once a slot. The
 * speaker is silent, since the game would make several times what it can play. A change of speed
 * starts the clocks afresh. */
static bool end_of_slot(void) {
  bool fast = rg_window_fast_forwarding() != 0;
  if (fast != was_fast_forwarding) {
    was_fast_forwarding = fast;
    silence_speaker(fast);
    restart_clocks();
    frames_in_slot = 0;
  }
  if (!fast) return true;
  if (++frames_in_slot < rg_window_fast_speed()) return false;
  frames_in_slot = 0;
  return true;
}

/* The computer's own clock, in its local time, handed to the cartridge's (rg_clock_reads). A
 * computer whose clock cannot be read leaves the cartridge's as it last was, or with no clock at
 * all, which the game is told. */
static void read_computer_clock(void) {
  SDL_Time now;
  SDL_DateTime local;
  if (!SDL_GetCurrentTime(&now) || !SDL_TimeToDateTime(now, &local, true)) return;
  rg_clock_reads(local.year, local.month, local.day, local.hour, local.minute, local.second);
}

/* The frame boundary: the picture the frame drew is shown, the clock comes round, and the
 * buttons for the next frame are read. */
static void sdl_wait_vblank(void) {
  if (scripted && frames_played >= frames_to_play) finish_script();
  Uint64 frame_ended = SDL_GetTicksNS();
  rg_window_frame_played(frame_ended, game_resumed_ns ? frame_ended - game_resumed_ns : 0);
  play_frame_sound();
  rg_frame_begins();
  frames_played++;
  bool shown = end_of_slot();
  if (shown) present();
  write_files_due();
  read_events();
  if (shown) wait_for_next_frame();
  if (scripted) press_scripted_keys();
  read_and_apply_events();
  /* The one place a pause takes hold, after everything that could ask for it has been read: a step
   * leaves it for the game's next frame and not for a second look at the pause on the way. */
  hold_while_paused();
  read_buttons();
  read_computer_clock(); /* after any pause, so the frame it goes on with has the time now */
  game_resumed_ns = SDL_GetTicksNS();
}

/* The game stopped on purpose: its last picture stays up until the window is closed. */
static void sdl_halt(void) {
  if (scripted) finish_script();
  for (;;) {
    present();
    write_files_due();
    read_and_apply_events();
    wait_for_next_frame();
  }
}

/* Said in a box as well as on the error stream, since a player who started it from the
 * Finder has no terminal to read. */
static void sdl_fault(const char *format, va_list args) {
  char message[512];
  vsnprintf(message, sizeof message, format, args);
  fprintf(stderr, "%s\n", message);
  SDL_ShowSimpleMessageBox(SDL_MESSAGEBOX_ERROR, rg_game_title, message, window);
  quit(1);
}

/* A player's window has nobody to print the variables to: only a trace, on the error stream as
 * it goes, and a script's end, on the output, do; and the menu's window of them, which keeps them. */
static void sdl_dump_variable(const char *name, int32_t value) {
  if (collecting_variables) {
    rg_window_watch_note(name, value);
  } else if (printing_script_end) {
    printf("var %s %d\n", name, (int)value);
  } else if (tracing) {
    fprintf(stderr, " %s=%d", name, (int)value);
  }
}

/* ...nor the log of what was played: the window plays the sound itself. */
static void sdl_sound_logged(const char *line) { (void)line; }

/* ...nor the lists. */
static const rg_driver sdl = {sdl_wait_vblank, sdl_halt, sdl_fault, sdl_dump_variable, sdl_sound_logged, NULL};

/* The gamepad the keyboard presses: one SDL makes up. It turns up among the gamepads like any
 * other, and is opened and read the way they are.
 *
 * It is given every button a standard gamepad has, though the keyboard presses ten of them. SDL
 * numbers a made-up gamepad's buttons by counting only the ones it is said to have, so a pad said
 * to have just these ten would have its directions under different numbers from a real one's. */
static void attach_keyboard_pad(void) {
  SDL_VirtualJoystickDesc pad;
  SDL_INIT_INTERFACE(&pad);
  pad.type = SDL_JOYSTICK_TYPE_GAMEPAD;
  pad.name = "Keyboard";
  pad.nbuttons = SDL_GAMEPAD_BUTTON_COUNT;
  SDL_JoystickID id = SDL_AttachVirtualJoystick(&pad);
  if (!id) refuse_to_start("the keyboard cannot be set up as a gamepad");
  keyboard_pad = SDL_OpenJoystick(id);
  if (!keyboard_pad) refuse_to_start("the keyboard's gamepad cannot be opened");
  keyboard_pad_id = id;
  read_events(); /* takes it up as a gamepad, with any real ones already plugged in */
}

/* What --help prints: the keys as the window starts with them, read from the window's own table so
 * this cannot say a key the window does not use, and the options a player has a use for. The rest
 * (--headless, --scripted-keys, --trace, --window-picture, --usual-settings, and --frame-times and
 * --refresh-rate, which measure the pacing and are told in .claude/testing/desktop.md) are how the
 * tests and the framework's own people drive the program, and are left out. Nothing is opened: no
 * window, no settings file, no folder. */
static void print_usage(const char *program) {
  const char *name = program;
  for (const char *c = program; *c; c++) {
    if (*c == '/' || *c == '\\') name = c + 1; /* the program's own name, not the folders it is in */
  }
  rg_window_use_key_names(scancode_name, scancode_named);
  rg_window_use_defaults();

  printf("Usage: %s [options]\n\n", name);
  printf("Play %s, a game built with ruby-gba.\n\n", rg_game_title);
  printf("Keys:\n");
  for (int button = 0; button < RG_WINDOW_BUTTONS; button++) {
    printf("  %-18s", rg_window_button_name(button));
    const char *between = "";
    for (int slot = 0; slot < RG_WINDOW_KEYS_A_BUTTON; slot++) {
      int key = rg_window_button_key(button, slot);
      if (key == RG_NO_KEY) continue;
      printf("%s%s", between, rg_window_key_name(key));
      between = ", ";
    }
    printf("\n");
  }
  for (int hotkey = 0; hotkey < RG_HOTKEY_COUNT; hotkey++) {
    printf("  %-18s%s%s\n", rg_window_hotkey_name(hotkey), rg_window_key_name(rg_window_hotkey_key(hotkey)),
           hotkey == RG_HOTKEY_FAST_FORWARD ? " (hold it down)" : "");
  }
  printf("\nA gamepad works too. The menu (move the mouse over the window, or press the\n"
         "Show menu key) changes the keys, the gamepad buttons, the window's size and\n"
         "the volume.\n\n");
  printf("Files:\n"
         "  The save and the settings are kept in a folder named for the game, among\n"
         "  the files this computer keeps for each program. The settings are a text\n"
         "  file, settings.txt, which you can edit.\n\n");
  printf("Options:\n"
         "  --save-file PATH       Keep the save in PATH. A .sav file from an emulator\n"
         "                         works.\n"
         "  --settings-file PATH   Read and write the settings in PATH only.\n"
         "  -h, --help             Print this.\n");
}

int main(int argc, char **argv) {
  if (argc > 1 && strcmp(argv[1], "--headless") == 0) return rg_headless_main(argc - 1, argv + 1);
  for (int i = 1; i < argc; i++) {
    if (strcmp(argv[i], "--help") == 0 || strcmp(argv[i], "-h") == 0) {
      print_usage(argv[0]);
      return 0;
    }
  }
  const char *save_file_asked_for = NULL;
  const char *settings_file_asked_for = NULL;
  int usual_settings_asked_for = 0;
  for (int i = 1; i < argc; i++) {
    if (strcmp(argv[i], "--save-file") == 0 && i + 1 < argc) save_file_asked_for = argv[i + 1];
    if (strcmp(argv[i], "--settings-file") == 0 && i + 1 < argc) settings_file_asked_for = argv[i + 1];
    if (strcmp(argv[i], "--usual-settings") == 0) usual_settings_asked_for = 1;
    if (strcmp(argv[i], "--window-picture") == 0 && i + 1 < argc) window_picture_file = argv[i + 1];
    if (strcmp(argv[i], "--trace") == 0) tracing = 1;
    if (strcmp(argv[i], "--frame-times") == 0) timing_frames = 1;
    if (strcmp(argv[i], "--refresh-rate") == 0 && i + 1 < argc) pretended_refreshes_a_second = strtod(argv[i + 1], NULL);
    if (strcmp(argv[i], "--scripted-keys") == 0 && i + 1 < argc) {
      scripted = 1;
      frames_to_play = strtol(argv[i + 1], NULL, 10);
    }
  }

  if (!SDL_Init(SDL_INIT_VIDEO)) refuse_to_start("the display cannot be reached");
  if (!SDL_InitSubSystem(SDL_INIT_GAMEPAD)) refuse_to_start("the buttons cannot be read");
  load_settings(settings_file_asked_for, usual_settings_asked_for);
  /* High pixel density asks for the screen's real pixels on a Retina display. Without it the
   * whole number the picture is scaled by is worked out in the display's larger "points", and the
   * system then stretches the result to the real pixels itself, smoothing it as it goes. The
   * window opens the size it was left at, and fullscreen if that is how it was left. */
  SDL_WindowFlags flags = SDL_WINDOW_RESIZABLE | SDL_WINDOW_HIGH_PIXEL_DENSITY;
  if (rg_window_fullscreen()) flags |= SDL_WINDOW_FULLSCREEN;
  window = SDL_CreateWindow(rg_game_title, RG_SCREEN_WIDTH * rg_window_scale(), RG_SCREEN_HEIGHT * rg_window_scale(), flags);
  if (!window) refuse_to_start("the window cannot be opened");
  SDL_SetWindowMinimumSize(window, RG_SCREEN_WIDTH, RG_SCREEN_HEIGHT);
  rg_window_consume_changes(); /* the window opened as the settings say: nothing is left to do to it */
  renderer = SDL_CreateRenderer(window, NULL);
  if (!renderer) refuse_to_start("nothing can draw into the window");
  SDL_SetRenderLogicalPresentation(renderer, RG_SCREEN_WIDTH, RG_SCREEN_HEIGHT, SDL_LOGICAL_PRESENTATION_INTEGER_SCALE);
  texture = SDL_CreateTexture(renderer, SDL_PIXELFORMAT_XBGR1555, SDL_TEXTUREACCESS_STREAMING, RG_SCREEN_WIDTH,
                              RG_SCREEN_HEIGHT);
  if (!texture) refuse_to_start("the picture cannot be made");
  SDL_SetTextureScaleMode(texture, SDL_SCALEMODE_NEAREST);
  /* The menu is not a thing a game can do without in a build a person plays; if it cannot start
   * the window says so and the hotkeys still work. */
  if (!rg_menu_start(window, renderer)) {
    fprintf(stderr, "%s: the menu cannot start (%s), so the window has no menu. The hotkeys still work.\n", rg_game_title,
            SDL_GetError());
    /* With no menu to say it over the picture, what is wrong with the settings file goes in a box. */
    if (rg_window_problems()[0] && !scripted) {
      char message[1200];
      snprintf(message, sizeof message, "The window cannot use some of the settings file. It uses the rest.\n\n%s", rg_window_problems());
      SDL_ShowSimpleMessageBox(SDL_MESSAGEBOX_WARNING, rg_game_title, message, window);
    }
  }
  attach_keyboard_pad();
  open_speaker();
  choose_pacing();
  choose_save_file(save_file_asked_for);
  read_save_file();

  read_computer_clock();
  rg_active_driver = &sdl;
  rg_game_main();
  /* A game with no game loop ends; its last picture stays up like a halt's. */
  sdl_halt();
  return 0;
}
