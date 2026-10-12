/*
 * The runtime with a window, through SDL3: what a player runs.
 *
 *   ./pong                               play it
 *   ./pong --headless FRAMES             the same program with no window (see rg_headless.c)
 *   ./pong --trace 2> buttons.log        play it, and write down what the window made of the buttons
 *   ./pong --scripted-keys FRAMES < keys play FRAMES frames with keys pressed from a script (tests)
 *   ./pong --frame-times                 play it, and say at the end how evenly its pictures were shown
 *   ./pong --refresh-rate 144            pace it as for a monitor of that rate, whatever this one's is
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
 * The keys are mGBA's defaults, so a player who has used it already knows them: the arrows for
 * the pad, X for A, Z for B, A and S for the shoulders, Return for Start and Backspace for
 * Select — and Right Shift for Select as well, for a keyboard with no Backspace. They are read by
 * where they sit on the keyboard, not by what is printed on them. On a gamepad the buttons are
 * where the console has them: A on the right, B below it.
 *
 * THE SOUND is made a frame at a time by rg_sound.c and handed to SDL as it is made, which keeps
 * a little of it waiting so a frame that arrives a moment late is not heard as a gap. Where the
 * monitor paces the game a shade fast or slow, the sound is played that much faster or slower,
 * so as much is played as is made. A computer with nothing to play sound through still plays the
 * game.
 */
#include <SDL3/SDL.h>
#include <SDL3/SDL_main.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "rg_driver.h"
#include "rg_pacing.h"
#include "rg_runtime.h"
#include "rg_screen.h"
#include "rg_sound.h"

/* One frame of the console, in nanoseconds. */
#define FRAME_NS ((Uint64)RG_CONSOLE_TICKS_A_FRAME * 1000000000ull / RG_CONSOLE_TICKS_A_SECOND)

/* How many times the picture is scaled up when the window first opens. */
#define START_SCALE 3

#define BUTTONS 10
/* As many gamepads as are read at once, the keyboard's among them. */
#define MOST_PADS 8

/* The console's ten buttons, in the order rg_runtime.h numbers them: mGBA's key for each, and
 * the gamepad button it is. */
static const SDL_Scancode keys[BUTTONS] = {
  SDL_SCANCODE_X,         /* a */
  SDL_SCANCODE_Z,         /* b */
  SDL_SCANCODE_BACKSPACE, /* select */
  SDL_SCANCODE_RETURN,    /* start */
  SDL_SCANCODE_RIGHT,     /* right */
  SDL_SCANCODE_LEFT,      /* left */
  SDL_SCANCODE_UP,        /* up */
  SDL_SCANCODE_DOWN,      /* down */
  SDL_SCANCODE_S,         /* r */
  SDL_SCANCODE_A,         /* l */
};
/* A second key for a button whose first not every keyboard has: Right Shift is Select too. */
static const SDL_Scancode other_keys[BUTTONS] = {[2] = SDL_SCANCODE_RSHIFT};
static const SDL_GamepadButton pad_buttons[BUTTONS] = {
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
#define SOUND_NUDGE_MOST 0.01

static SDL_Gamepad *pads[MOST_PADS]; /* every gamepad open, the keyboard's among them */
static SDL_Joystick *keyboard_pad;   /* the gamepad SDL makes up for the keyboard to press */
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

static double in_ms(Uint64 ns) { return (double)ns / 1000000.0; }

static int by_length(const void *a, const void *b) {
  Uint64 one = *(const Uint64 *)a, other = *(const Uint64 *)b;
  return (one > other) - (one < other);
}

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
  /* The first of those is the start: there is none waiting before any is made. */
  if (speaker) {
    fprintf(stderr, "sound: %ld frames thrown away with too much waiting, %ld times quiet was put in with too little\n",
            sound_frames_dropped, sound_ran_dry);
  }
  if (shown_count < 2) return;

  size_t gaps = shown_count - 1;
  Uint64 *sorted = malloc(gaps * sizeof *sorted);
  if (!sorted) return;
  for (size_t i = 0; i < gaps; i++) sorted[i] = shown_at_ns[i + 1] - shown_at_ns[i];
  qsort(sorted, gaps, sizeof *sorted, by_length);
  Uint64 middle = sorted[gaps / 2];
  fprintf(stderr, "pictures: %zu, %.2f to %.2f ms apart, %.2f in the middle\n", shown_count, in_ms(sorted[0]),
          in_ms(sorted[gaps - 1]), in_ms(middle));
  free(sorted);

  const Uint64 even_ns = 2000000;
  size_t uneven = 0;
  for (size_t i = 0; i < gaps; i++) {
    Uint64 gap = shown_at_ns[i + 1] - shown_at_ns[i];
    if ((gap > middle ? gap - middle : middle - gap) > even_ns) uneven++;
  }
  fprintf(stderr, "uneven (more than 2 ms from the middle): %zu", uneven);
  if (uneven) fprintf(stderr, ", after pictures");
  for (size_t i = 0; i < gaps; i++) {
    Uint64 gap = shown_at_ns[i + 1] - shown_at_ns[i];
    if ((gap > middle ? gap - middle : middle - gap) > even_ns) fprintf(stderr, " %zu", i + 1);
  }
  fputc('\n', stderr);
}

static _Noreturn void quit(int status) {
  if (timing_frames) report_frame_times();
  SDL_Quit();
  exit(status);
}

static _Noreturn void refuse_to_start(const char *what) {
  fprintf(stderr, "%s could not start: %s (%s)\n", rg_game_title, what, SDL_GetError());
  quit(1);
}

/* Works out what paces the frames from the monitor the window is on now, and tells the display
 * and the speaker.
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

/* Shows the picture as it stands: once, or where the monitor paces the frames, once for each
 * refresh a picture is shown for, each waiting for its refresh. */
static void present(void) {
  SDL_UpdateTexture(texture, NULL, rg_screen_shown(), RG_SCREEN_WIDTH * (int)sizeof(uint16_t));
  int times = pacing.refreshes ? pacing.refreshes : 1;
  for (int i = 0; i < times; i++) {
    SDL_SetRenderDrawColor(renderer, 0, 0, 0, 255);
    SDL_RenderClear(renderer);
    SDL_RenderTexture(renderer, texture, NULL, NULL);
    SDL_RenderPresent(renderer);
  }
  if (timing_frames) remember_picture_shown();
}

/* THE SOUND IS KEPT IN STEP WITH THE GAME by playing it a shade faster or slower. A frame of the
 * game makes a frame of sound, and how many frames there are in a second is the monitor's doing
 * where it paces the game (rg_pacing.h), so the sound is played at the game's pace to begin with.
 * That alone is not enough: neither a monitor nor a sound card runs at exactly the rate it says,
 * so a little more sound is made than played, or a little less, all the time. Left alone that
 * piles up until some has to be thrown away, or runs dry, and either is a click.
 *
 * So the pace is nudged by how much is waiting: faster the more there is past what should be
 * waiting, slower the less, and never by more than SOUND_NUDGE_MOST of itself, which is too
 * little to hear as a change of pitch. */
static void keep_sound_in_step(int waiting, int frame_bytes) {
  double wanted = (double)(SOUND_WAITING_FRAMES * frame_bytes);
  double over = ((double)waiting - wanted) / wanted;
  if (over > 1.0) over = 1.0;
  if (over < -1.0) over = -1.0;
  SDL_SetAudioStreamFrequencyRatio(speaker, (float)(pacing.speed * (1.0 + SOUND_NUDGE_MOST * over)));
}

/* The sound of the frame that has just been played goes to the speaker. It is made whether or
 * not there is a speaker, since making it is what moves the voices on. */
static void play_frame_sound(void) {
  int16_t samples[RG_SOUND_FRAME_MOST];
  int count = (int)rg_sound_render_frame(samples);
  if (!speaker || count <= 0) return;

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
    sound_ran_dry++;
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
 * not a second press, so those are passed over. */
static void key_changed(const SDL_KeyboardEvent *key) {
  if (key->repeat) return;
  for (uint32_t i = 0; i < BUTTONS; i++) {
    if (keys[i] != key->scancode && (other_keys[i] == SDL_SCANCODE_UNKNOWN || other_keys[i] != key->scancode)) continue;
    if (key->down) {
      keys_down |= 1u << i;
      keys_tapped |= 1u << i;
    } else {
      keys_down &= ~(1u << i);
    }
  }
}

/* Everything the window has to say: closing it ends the game, a key presses the keyboard's
 * gamepad, a gamepad plugged in or pulled out is taken up or let go, and a window moved to
 * another monitor, or a monitor set to another rate, is paced afresh. */
static void read_events(void) {
  SDL_Event event;
  while (SDL_PollEvent(&event)) {
    switch (event.type) {
    case SDL_EVENT_QUIT:
      quit(0);
    case SDL_EVENT_KEY_DOWN:
    case SDL_EVENT_KEY_UP:
      key_changed(&event.key);
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
  rg_game_dump_variables();
  fputc('\n', stderr);
}

/* The keyboard presses its gamepad's buttons, and then every gamepad is read: a button down on
 * any of them is down. A key that went down and came up again between two frames still counts
 * for the frame that follows, so a quick tap is never lost. */
static void read_buttons(void) {
  uint32_t keyboard = keys_down | keys_tapped;
  keys_tapped = 0;
  for (uint32_t i = 0; i < BUTTONS; i++) SDL_SetJoystickVirtualButton(keyboard_pad, pad_buttons[i], (keyboard >> i) & 1u);
  SDL_UpdateGamepads();

  uint32_t held = 0;
  for (int pad = 0; pad < MOST_PADS; pad++) {
    if (!pads[pad]) continue;
    for (uint32_t i = 0; i < BUTTONS; i++)
      if (SDL_GetGamepadButton(pads[pad], pad_buttons[i])) held |= 1u << i;
  }
  rg_buttons_read(held);
  if (tracing) trace_frame(held);
}

/* The script's keys for the frame that is starting: each one that changed is sent as the key
 * event a keyboard would send. */
static void press_scripted_keys(void) {
  unsigned long mask = 0;
  if (scanf("%lu", &mask) != 1) mask = 0;
  for (uint32_t i = 0; i < BUTTONS; i++) {
    bool down = (mask >> i) & 1u;
    if (down == (bool)((scripted_keys >> i) & 1u)) continue;
    SDL_Event event;
    SDL_zero(event);
    event.type = down ? SDL_EVENT_KEY_DOWN : SDL_EVENT_KEY_UP;
    event.key.scancode = keys[i];
    event.key.down = down;
    SDL_PushEvent(&event);
  }
  scripted_keys = (uint32_t)mask;
}

/* A scripted run's last word: every variable, as --headless prints them at its end. */
static _Noreturn void finish_script(void) {
  puts("end");
  printing_script_end = 1;
  rg_game_dump_variables();
  fflush(stdout);
  quit(0);
}

/* The frame boundary: the picture the frame drew is shown, the clock comes round, and the
 * buttons for the next frame are read. */
static void sdl_wait_vblank(void) {
  if (scripted && frames_played >= frames_to_play) finish_script();
  play_frame_sound();
  rg_frame_begins();
  frames_played++;
  present();
  read_events();
  wait_for_next_frame();
  if (scripted) press_scripted_keys();
  read_events();
  read_buttons();
}

/* The game stopped on purpose: its last picture stays up until the window is closed. */
static void sdl_halt(void) {
  if (scripted) finish_script();
  for (;;) {
    present();
    read_events();
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
 * it goes, and a script's end, on the output, do. */
static void sdl_dump_variable(const char *name, int32_t value) {
  if (printing_script_end) {
    printf("var %s %d\n", name, (int)value);
  } else if (tracing) {
    fprintf(stderr, " %s=%d", name, (int)value);
  }
}

/* ...nor the log of what was played: the window plays the sound itself. */
static void sdl_sound_logged(const char *line) { (void)line; }

static const rg_driver sdl = {sdl_wait_vblank, sdl_halt, sdl_fault, sdl_dump_variable, sdl_sound_logged};

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
  if (!id) refuse_to_start("the keyboard could not be set up as a gamepad");
  keyboard_pad = SDL_OpenJoystick(id);
  if (!keyboard_pad) refuse_to_start("the keyboard's gamepad could not be opened");
  read_events(); /* takes it up as a gamepad, with any real ones already plugged in */
}

int main(int argc, char **argv) {
  if (argc > 1 && strcmp(argv[1], "--headless") == 0) return rg_headless_main(argc - 1, argv + 1);
  for (int i = 1; i < argc; i++) {
    if (strcmp(argv[i], "--trace") == 0) tracing = 1;
    if (strcmp(argv[i], "--frame-times") == 0) timing_frames = 1;
    if (strcmp(argv[i], "--refresh-rate") == 0 && i + 1 < argc) pretended_refreshes_a_second = strtod(argv[i + 1], NULL);
    if (strcmp(argv[i], "--scripted-keys") == 0 && i + 1 < argc) {
      scripted = 1;
      frames_to_play = strtol(argv[i + 1], NULL, 10);
    }
  }

  if (!SDL_Init(SDL_INIT_VIDEO)) refuse_to_start("the display could not be reached");
  if (!SDL_InitSubSystem(SDL_INIT_GAMEPAD)) refuse_to_start("the buttons could not be read");
  /* High pixel density asks for the screen's real pixels on a Retina display. Without it the
   * whole number the picture is scaled by is worked out in the display's larger "points", and the
   * system then stretches the result to the real pixels itself, smoothing it as it goes. */
  window = SDL_CreateWindow(rg_game_title, RG_SCREEN_WIDTH * START_SCALE, RG_SCREEN_HEIGHT * START_SCALE,
                            SDL_WINDOW_RESIZABLE | SDL_WINDOW_HIGH_PIXEL_DENSITY);
  if (!window) refuse_to_start("no window could be opened");
  renderer = SDL_CreateRenderer(window, NULL);
  if (!renderer) refuse_to_start("nothing could draw into the window");
  SDL_SetRenderLogicalPresentation(renderer, RG_SCREEN_WIDTH, RG_SCREEN_HEIGHT, SDL_LOGICAL_PRESENTATION_INTEGER_SCALE);
  texture = SDL_CreateTexture(renderer, SDL_PIXELFORMAT_XBGR1555, SDL_TEXTUREACCESS_STREAMING, RG_SCREEN_WIDTH,
                              RG_SCREEN_HEIGHT);
  if (!texture) refuse_to_start("the picture could not be made");
  SDL_SetTextureScaleMode(texture, SDL_SCALEMODE_NEAREST);
  attach_keyboard_pad();
  open_speaker();
  choose_pacing();

  rg_active_driver = &sdl;
  rg_game_main();
  /* A game with no game loop ends; its last picture stays up like a halt's. */
  sdl_halt();
  return 0;
}
