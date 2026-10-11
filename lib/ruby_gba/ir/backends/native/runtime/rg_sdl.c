/*
 * The runtime with a window, through SDL3: what a player runs.
 *
 *   ./pong                               play it
 *   ./pong --headless FRAMES             the same program with no window (see rg_headless.c)
 *   ./pong --trace 2> buttons.log        play it, and write down what the window made of the buttons
 *   ./pong --scripted-keys FRAMES < keys play FRAMES frames with keys pressed from a script (tests)
 *
 * THE GAME OWNS THE LOOP. A game waits for the next frame wherever it likes — at the top of its
 * game loop, or deep inside a routine that runs before the loop starts — so it cannot hand
 * control back to SDL once a frame and be called again. Instead SDL is driven from inside
 * rg_wait_vblank: show the frame, read the window's events and the buttons, and wait for the
 * next frame's moment to come round. That is SDL3's ordinary main() rather than its callback
 * style, and the game runs on the program's first thread, which is where macOS wants a window
 * looked after.
 *
 * THE CONSOLE'S CLOCK, NOT THE MONITOR'S. The console draws a frame every 280,896 ticks of a
 * clock running at 2^24 ticks a second — a little under sixty frames a second — and a game is
 * written to that pace. So the frames are timed here from that number, whatever rate the monitor
 * refreshes at. A game a frame or two late runs its next frames without waiting until it is back
 * on time, so a moment's hitch does not slow the game for good; one more than four frames late
 * (the computer was asleep, the window was being dragged) starts afresh from now instead, rather
 * than racing through the frames it missed.
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
 * a little of it waiting so a frame that arrives a moment late is not heard as a gap. A computer
 * with nothing to play sound through still plays the game.
 */
#include <SDL3/SDL.h>
#include <SDL3/SDL_main.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "rg_driver.h"
#include "rg_runtime.h"
#include "rg_screen.h"
#include "rg_sound.h"

/* One frame of the console, in nanoseconds: 280,896 ticks of a 2^24-a-second clock. */
#define FRAME_NS ((Uint64)280896 * 1000000000ull / 16777216ull)

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
static Uint64 next_frame_ns;

static SDL_AudioStream *speaker; /* where the sound goes; none on a computer with no sound */

/* How much sound may be waiting to be played, in frames' worth. Two are put in ahead whenever
 * there is less than a frame waiting — at the start, or after the game was held up — so a frame
 * a moment late does not leave the speaker with nothing. More than six waiting means the
 * speaker is behind the game, and a frame's sound is dropped to let it catch up. */
#define SOUND_AHEAD_FRAMES 2
#define SOUND_BEHIND_FRAMES 6

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

static _Noreturn void quit(int status) {
  SDL_Quit();
  exit(status);
}

static _Noreturn void refuse_to_start(const char *what) {
  fprintf(stderr, "%s could not start: %s (%s)\n", rg_game_title, what, SDL_GetError());
  quit(1);
}

/* Shows the picture as it stands. */
static void present(void) {
  SDL_UpdateTexture(texture, NULL, rg_screen_shown(), RG_SCREEN_WIDTH * (int)sizeof(uint16_t));
  SDL_SetRenderDrawColor(renderer, 0, 0, 0, 255);
  SDL_RenderClear(renderer);
  SDL_RenderTexture(renderer, texture, NULL, NULL);
  SDL_RenderPresent(renderer);
}

/* The sound of the frame that has just been played goes to the speaker. It is made whether or
 * not there is a speaker, since making it is what moves the voices on. */
static void play_frame_sound(void) {
  int16_t samples[RG_SOUND_FRAME_MOST];
  int count = (int)rg_sound_render_frame(samples);
  if (!speaker) return;

  int bytes = count * (int)sizeof samples[0];
  int waiting = SDL_GetAudioStreamQueued(speaker);
  if (waiting > SOUND_BEHIND_FRAMES * bytes) return;
  if (waiting < bytes) {
    static const int16_t quiet[RG_SOUND_FRAME_MOST];
    for (int i = 0; i < SOUND_AHEAD_FRAMES; i++) SDL_PutAudioStreamData(speaker, quiet, bytes);
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
 * gamepad, and a gamepad plugged in or pulled out is taken up or let go. */
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
    default:
      break;
    }
  }
}

/* Waits for the next frame's moment on the console's clock. */
static void wait_for_next_frame(void) {
  Uint64 now = SDL_GetTicksNS();
  if (next_frame_ns == 0 || now > next_frame_ns + 4 * FRAME_NS) next_frame_ns = now; /* fell behind: start afresh */
  next_frame_ns += FRAME_NS;
  now = SDL_GetTicksNS();
  if (next_frame_ns > now) SDL_DelayPrecise(next_frame_ns - now);
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

/* A player's window has nobody to print the variables to: only a trace and a script's end do. */
static void sdl_dump_variable(const char *name, int32_t value) {
  if (scripted) {
    printf("var %s %d\n", name, (int)value);
  } else if (tracing) {
    fprintf(stderr, " %s=%d", name, (int)value);
  }
}

/* ...nor the sound log. A window will play the sound itself, from the same player, one day. */
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
    if (strcmp(argv[i], "--scripted-keys") == 0 && i + 1 < argc) {
      scripted = 1;
      frames_to_play = strtol(argv[i + 1], NULL, 10);
    }
  }

  if (!SDL_Init(SDL_INIT_VIDEO | SDL_INIT_GAMEPAD)) refuse_to_start("the display could not be reached");
  /* High pixel density asks for the screen's real pixels on a Retina display. Without it the
   * whole number the picture is scaled by is worked out in the display's larger "points", and the
   * system then stretches the result to the real pixels itself, smoothing it as it goes. */
  window = SDL_CreateWindow(rg_game_title, RG_SCREEN_WIDTH * START_SCALE, RG_SCREEN_HEIGHT * START_SCALE,
                            SDL_WINDOW_RESIZABLE | SDL_WINDOW_HIGH_PIXEL_DENSITY);
  if (!window) refuse_to_start("no window could be opened");
  renderer = SDL_CreateRenderer(window, NULL);
  if (!renderer) refuse_to_start("nothing could draw into the window");
  SDL_SetRenderVSync(renderer, 0); /* the console's clock paces the frames, not the monitor's */
  SDL_SetRenderLogicalPresentation(renderer, RG_SCREEN_WIDTH, RG_SCREEN_HEIGHT, SDL_LOGICAL_PRESENTATION_INTEGER_SCALE);
  texture = SDL_CreateTexture(renderer, SDL_PIXELFORMAT_XBGR1555, SDL_TEXTUREACCESS_STREAMING, RG_SCREEN_WIDTH,
                              RG_SCREEN_HEIGHT);
  if (!texture) refuse_to_start("the picture could not be made");
  SDL_SetTextureScaleMode(texture, SDL_SCALEMODE_NEAREST);
  attach_keyboard_pad();
  open_speaker();

  rg_active_driver = &sdl;
  rg_game_main();
  /* A game with no game loop ends; its last picture stays up like a halt's. */
  sdl_halt();
  return 0;
}
