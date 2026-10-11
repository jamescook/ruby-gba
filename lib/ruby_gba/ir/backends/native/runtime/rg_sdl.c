/*
 * The runtime with a window, through SDL3: what a player runs.
 *
 *   ./pong                          play it
 *   ./pong --headless FRAMES        the same program with no window (see rg_headless.c)
 *
 * THE GAME OWNS THE LOOP. A game waits for the next frame wherever it likes — at the top of its
 * game loop, or deep inside a routine that runs before the loop starts — so it cannot hand
 * control back to SDL once a frame and be called again. Instead SDL is driven from inside
 * rg_wait_vblank: show the frame, read the window's events and the keyboard, and wait for the
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
 * THE KEYS are mGBA's defaults, so a player who has used it already knows them: the arrows for
 * the pad, X for A, Z for B, A and S for the shoulders, Return for Start and Backspace for
 * Select. They are read by where they sit on the keyboard, not by what is printed on them.
 *
 * Sound is not played yet.
 */
#include <SDL3/SDL.h>
#include <SDL3/SDL_main.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "rg_driver.h"
#include "rg_runtime.h"
#include "rg_screen.h"

/* One frame of the console, in nanoseconds: 280,896 ticks of a 2^24-a-second clock. */
#define FRAME_NS ((Uint64)280896 * 1000000000ull / 16777216ull)

/* How many times the picture is scaled up when the window first opens. */
#define START_SCALE 3

/* The console's ten buttons, in the order rg_runtime.h numbers them, and mGBA's key for each. */
static const SDL_Scancode keys[10] = {
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

static SDL_Window *window;
static SDL_Renderer *renderer;
static SDL_Texture *texture;
static Uint64 next_frame_ns;

static _Noreturn void quit(int status) {
  SDL_Quit();
  exit(status);
}

/* Shows the picture as it stands. */
static void present(void) {
  SDL_UpdateTexture(texture, NULL, rg_screen_shown(), RG_SCREEN_WIDTH * (int)sizeof(uint16_t));
  SDL_SetRenderDrawColor(renderer, 0, 0, 0, 255);
  SDL_RenderClear(renderer);
  SDL_RenderTexture(renderer, texture, NULL, NULL);
  SDL_RenderPresent(renderer);
}

/* Everything the window has to say: closing it ends the game. */
static void read_events(void) {
  SDL_Event event;
  while (SDL_PollEvent(&event))
    if (event.type == SDL_EVENT_QUIT) quit(0);
}

/* Waits for the next frame's moment on the console's clock. */
static void wait_for_next_frame(void) {
  Uint64 now = SDL_GetTicksNS();
  if (next_frame_ns == 0 || now > next_frame_ns + 4 * FRAME_NS) next_frame_ns = now; /* fell behind: start afresh */
  next_frame_ns += FRAME_NS;
  now = SDL_GetTicksNS();
  if (next_frame_ns > now) SDL_DelayPrecise(next_frame_ns - now);
}

static void read_buttons(void) {
  const bool *down = SDL_GetKeyboardState(NULL);
  uint32_t held = 0;
  for (uint32_t i = 0; i < 10; i++)
    if (down[keys[i]]) held |= 1u << i;
  rg_buttons_read(held);
}

/* The frame boundary: the picture the frame drew is shown, the clock comes round, and the
 * buttons for the next frame are read. */
static void sdl_wait_vblank(void) {
  rg_frame_begins();
  present();
  read_events();
  wait_for_next_frame();
  read_events();
  read_buttons();
}

/* The game stopped on purpose: its last picture stays up until the window is closed. */
static void sdl_halt(void) {
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

/* A player's window has nobody to print the variables to. */
static void sdl_dump_variable(const char *name, int32_t value) {
  (void)name;
  (void)value;
}

/* ...nor the sound log. A window will play the sound itself, from the same player, one day. */
static void sdl_sound_logged(const char *line) { (void)line; }

static const rg_driver sdl = {sdl_wait_vblank, sdl_halt, sdl_fault, sdl_dump_variable, sdl_sound_logged};

static _Noreturn void refuse_to_start(const char *what) {
  fprintf(stderr, "%s could not start: %s (%s)\n", rg_game_title, what, SDL_GetError());
  quit(1);
}

int main(int argc, char **argv) {
  if (argc > 1 && strcmp(argv[1], "--headless") == 0) return rg_headless_main(argc - 1, argv + 1);

  if (!SDL_Init(SDL_INIT_VIDEO)) refuse_to_start("the display could not be reached");
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

  rg_active_driver = &sdl;
  rg_game_main();
  /* A game with no game loop ends; its last picture stays up like a halt's. */
  sdl_halt();
  return 0;
}
