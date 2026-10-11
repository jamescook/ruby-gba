/*
 * The runtime with no window: what the tests run a game against.
 *
 *   ./game --headless FRAMES < buttons     (the program a player runs)
 *   ./game FRAMES < buttons                (a test build, which has no window to choose)
 *
 * plays FRAMES frames and stops at the start of the next one, the way the interpreter's
 * run(program, frames: FRAMES) does. Each line of standard input is the buttons held during one
 * frame, as a number with a bit per button (bit 0 is a, in the order rg_runtime.h lists them);
 * a missing line holds nothing.
 *
 * It prints, at every frame boundary, "frame N" followed by every variable as "name value" and
 * the picture as shown, and at the end "end" followed by the same — the moments the
 * interpreter's each_vblank and the end of its run show a test, so the two can be compared line
 * by line.
 */
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include "rg_driver.h"
#include "rg_runtime.h"
#include "rg_screen.h"

static long frames_to_play;
static long frame;            /* frames started so far */
static uint32_t held;         /* buttons down now, a bit each */
static uint32_t seen;         /* ...and at the last frame boundary, to tell a press from a hold */
static uint32_t pressed;      /* buttons that went down at the last frame boundary */

#define ALL_BUTTONS 0x3FFu

/* The picture as it is shown, as one line: "picture" and then every pixel, row by row, as four
 * hex digits. */
static void print_picture(void) {
  const uint16_t *shown = rg_screen_shown();
  fputs("picture ", stdout);
  for (int32_t i = 0; i < RG_SCREEN_WIDTH * RG_SCREEN_HEIGHT; i++) printf("%04x", (unsigned)shown[i]);
  fputc('\n', stdout);
}

static void print_moment(const char *heading) {
  printf("%s\n", heading);
  rg_game_dump_variables();
  print_picture();
}

static _Noreturn void finish(void) {
  print_moment("end");
  fflush(stdout);
  exit(0);
}

/* The buttons for the frame that is starting: read, then compared with the last frame's so a
 * button that has just gone down counts as pressed for this frame only. */
static void read_buttons(void) {
  unsigned long mask = 0;
  if (scanf("%lu", &mask) != 1) mask = 0;
  held = (uint32_t)mask & ALL_BUTTONS;
  pressed = held & ~seen;
  seen = held;
}

static void headless_wait_vblank(void) {
  if (frame >= frames_to_play) finish();
  rg_screen_frame_started();
  frame++;
  read_buttons();
  char heading[32];
  snprintf(heading, sizeof heading, "frame %ld", frame);
  print_moment(heading);
}

static void headless_halt(void) { finish(); }

/* Said on the error stream, and the run ends badly, which is how a test sees it. */
static void headless_fault(const char *format, va_list args) {
  vfprintf(stderr, format, args);
  fputc('\n', stderr);
  exit(1);
}

static uint32_t headless_held(void) { return held; }
static uint32_t headless_pressed(void) { return pressed; }

static void headless_dump_variable(const char *name, int32_t value) { printf("%s %d\n", name, (int)value); }

static const rg_driver headless = {headless_wait_vblank, headless_halt, headless_fault, headless_held,
                                   headless_pressed, headless_dump_variable};

int rg_headless_main(int argc, char **argv) {
  if (argc < 2) {
    fprintf(stderr, "usage: %s FRAMES < buttons\n", argv[0]);
    return 2;
  }
  frames_to_play = strtol(argv[1], NULL, 10);
  rg_active_driver = &headless;
  rg_game_main();
  finish();
}
