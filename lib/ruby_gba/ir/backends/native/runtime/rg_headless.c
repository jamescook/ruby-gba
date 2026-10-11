/*
 * The runtime with no window: what the tests run a game against.
 *
 *   ./game --headless FRAMES [--every-picture] < buttons   (the program a player runs)
 *   ./game FRAMES [--every-picture] < buttons              (a test build, which has no window)
 *
 * plays FRAMES frames and stops at the start of the next one, the way the interpreter's
 * run(program, frames: FRAMES) does. Each line of standard input is the buttons held during one
 * frame, as a number with a bit per button (bit 0 is a, in the order rg_runtime.h lists them);
 * a missing line holds nothing.
 *
 * At every frame boundary it prints "frame N" and every variable as "var name value", then "buttons?",
 * and only then reads that frame's line. So whoever is feeding it can answer from what the game
 * has done so far — a test that presses a button only once the game has reached somewhere — or
 * write every line up front and ignore the question. That is the order the interpreter asks its
 * own input script in, after the frame before has finished.
 *
 * At the end it prints "end", every variable, and the picture as shown: "picture" and every
 * pixel, row by row, as four hex digits. A frame's moment carries only a check number of its
 * picture ("picture-crc"), or with --every-picture the whole picture, for a test that compares
 * every frame pixel by pixel. Without it a frame is a few lines rather than a hundred and fifty
 * thousand characters, which is what lets a long run be driven a frame at a time.
 *
 * With --sound-out FILE the sound of every frame played is written to FILE as it is made: one
 * speaker's worth, RG_SOUND_RATE numbers a second, each two bytes with the low byte first. And
 * with --sound-voice N only square voice N is in it, which is how a test hears one voice at a
 * time.
 */
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "rg_driver.h"
#include "rg_runtime.h"
#include "rg_screen.h"
#include "rg_sound.h"

static long frames_to_play;
static long frame; /* frames started so far */
static int every_picture; /* print the picture at every frame, not only at the end */
static FILE *sound_out;   /* where each frame's sound is written, if anywhere */

/* The sound of the frame that has just been played, written down. A machine that keeps its
 * numbers the other way round would write them the other way round; every machine this is built
 * for keeps the low byte first. */
static void write_frame_sound(void) {
  int16_t samples[RG_SOUND_FRAME_MOST];
  int32_t count = rg_sound_render_frame(samples);
  if (sound_out) fwrite(samples, sizeof samples[0], (size_t)count, sound_out);
}

/* The picture as it is shown, as one line: "picture" and then every pixel, row by row, as four
 * hex digits. */
static void print_picture(void) {
  const uint16_t *shown = rg_screen_shown();
  fputs("picture ", stdout);
  for (int32_t i = 0; i < RG_SCREEN_WIDTH * RG_SCREEN_HEIGHT; i++) printf("%04x", (unsigned)shown[i]);
  fputc('\n', stdout);
}

/* The picture as it is shown, as one number: the CRC-32 of its pixels, each as two bytes with the
 * low byte first — the CRC zip files use, which Ruby's Zlib.crc32 works out from the same bytes.
 * Two pictures with the same number are, in practice, the same picture, so a test can check
 * every frame for eight hex digits apiece and ask for the whole picture only where they differ. */
static void print_picture_crc(void) {
  const uint16_t *shown = rg_screen_shown();
  uint32_t crc = 0xFFFFFFFFu;
  for (int32_t i = 0; i < RG_SCREEN_WIDTH * RG_SCREEN_HEIGHT; i++) {
    for (int half = 0; half < 2; half++) {
      crc ^= (uint32_t)((shown[i] >> (8 * half)) & 0xFFu);
      for (int bit = 0; bit < 8; bit++) crc = (crc >> 1) ^ (0xEDB88320u & (0u - (crc & 1u)));
    }
  }
  printf("picture-crc %08x\n", (unsigned)~crc);
}

static void print_moment(const char *heading, int with_picture) {
  printf("%s\n", heading);
  rg_game_dump_variables();
  if (with_picture) {
    print_picture();
  } else {
    print_picture_crc();
  }
}

static _Noreturn void finish(void) {
  print_moment("end", 1);
  fflush(stdout);
  if (sound_out) fclose(sound_out);
  exit(0);
}

/* The buttons for the frame that is starting: the next line of standard input. */
static void read_buttons(void) {
  unsigned long mask = 0;
  if (scanf("%lu", &mask) != 1) mask = 0;
  rg_buttons_read((uint32_t)mask);
}

static void headless_wait_vblank(void) {
  write_frame_sound();
  if (frame >= frames_to_play) finish();
  rg_frame_begins();
  frame++;
  char heading[32];
  snprintf(heading, sizeof heading, "frame %ld", frame);
  print_moment(heading, every_picture);
  puts("buttons?");
  fflush(stdout);
  read_buttons();
}

static void headless_halt(void) { finish(); }

/* Said on the error stream, and the run ends badly, which is how a test sees it. */
static void headless_fault(const char *format, va_list args) {
  vfprintf(stderr, format, args);
  fputc('\n', stderr);
  exit(1);
}

/* "var" first, so no name a game gives a variable can be read as one of the other lines: a game
 * may well call one `frame`, or `picture`. */
static void headless_dump_variable(const char *name, int32_t value) { printf("var %s %d\n", name, (int)value); }

/* "sound" first, for the same reason a variable's line starts with "var"; printed as it happens,
 * among the frames, so a test reading the log mid-run sees it up to the frame it is on. */
static void headless_sound_logged(const char *line) { printf("sound %s\n", line); }

static const rg_driver headless = {headless_wait_vblank, headless_halt, headless_fault, headless_dump_variable,
                                   headless_sound_logged};

int rg_headless_main(int argc, char **argv) {
  if (argc < 2) {
    fputs("give the number of frames to play, and the buttons for each frame on standard input\n", stderr);
    return 2;
  }
  frames_to_play = strtol(argv[1], NULL, 10);
  for (int i = 2; i < argc; i++) {
    if (strcmp(argv[i], "--every-picture") == 0) {
      every_picture = 1;
    } else if (strcmp(argv[i], "--sound-out") == 0 && i + 1 < argc) {
      sound_out = fopen(argv[++i], "wb");
      if (!sound_out) {
        fprintf(stderr, "the sound could not be written to %s\n", argv[i]);
        return 2;
      }
    } else if (strcmp(argv[i], "--sound-voice") == 0 && i + 1 < argc) {
      rg_sound_hear_only((int32_t)strtol(argv[++i], NULL, 10));
    }
  }
  rg_active_driver = &headless;
  rg_game_main();
  finish();
}
