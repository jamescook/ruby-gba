/*
 * The runtime with no window: what the tests run a game against.
 *
 *   ./game --headless FRAMES [options] < buttons   (the program a player runs)
 *   ./game FRAMES [options] < buttons              (a test build, which has no window)
 *
 * plays FRAMES frames and stops at the start of the next one, the way the interpreter's
 * run(program, frames: FRAMES) does. Each line of standard input is the buttons held during one
 * frame, as a number with a bit per button (bit 0 is a, in the order rg_runtime.h lists them);
 * a missing line holds nothing.
 *
 * At every frame boundary it prints "frame N", every variable as "var name value", every list as
 * "list name" and its items (see headless_dump_list), every sprite
 * the game last drew as "sprite" and four numbers (see print_sprites), what the mixer made and is
 * playing for a game that mixes recordings (see print_mix), and where the window sits over the
 * picture as "camera X Y", then "buttons?",
 * and only then reads that frame's line. So whoever is feeding it can answer from what the game
 * has done so far — a test that presses a button only once the game has reached somewhere — or
 * write every line up front and ignore the question. That is the order the interpreter asks its
 * own input script in, after the frame before has finished.
 *
 * At the end it prints "end", every variable and every sprite the same way, and the picture as
 * shown: "picture" and every pixel, row by row, as four hex digits — and then the same page as
 * it is stored ("stored"), with no window moved over it and no fade mixed in, and how many pages
 * the screen has ("pages", 2 for a tear-free one). A frame's moment carries only a check number
 * of its picture ("picture-crc"), or with --every-picture the whole picture, for a test that
 * compares every frame pixel by pixel. Without it a frame is a few lines rather than a hundred
 * and fifty thousand characters, which is what lets a long run be driven a frame at a time.
 *
 * The options are --every-picture, and the five below.
 *
 * With --save FILE the game starts with the save memory FILE holds (rg_save.h: the bytes of a
 * .sav file, as many as the game has save memory), and when the run ends the save memory is
 * written back to FILE, whole, over what was there. No file there yet is a new cartridge. A game
 * with no save memory reads and writes nothing. And with --save-cut-after N the power goes off
 * N steps into the game's saving, which ends the run there, as it does in the interpreter.
 *
 * With --sound-out FILE the sound of every frame played is written to FILE as it is made: one
 * speaker's worth, RG_SOUND_RATE numbers a second, each two bytes with the low byte first. And
 * with --sound-voice N only voice N is in it, by the console's count of its voices (1 and 2 the
 * square voices, 3 the wave voice, 4 the noise voice), which is how a test hears one voice at a
 * time.
 *
 * With --picture-out FILE the picture of every moment is written to FILE, over the one before:
 * every pixel as shown and then every pixel as stored, row by row, each two bytes with the low
 * byte first. It is there before "buttons?" is asked, so whoever is feeding the buttons can read
 * that frame's picture, and need not when it has no use for it. The end then prints its
 * picture as a check number too, since the picture itself is in the file. A picture is far more
 * than a pipe holds at once, and a reader that takes it a pipeful at a time waits its turn for
 * each; a file is read in one go.
 */
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "rg_driver.h"
#include "rg_list.h"
#include "rg_mix.h"
#include "rg_runtime.h"
#include "rg_save.h"
#include "rg_screen.h"
#include "rg_sound.h"

static long frames_to_play;
static long frame; /* frames started so far */
static int every_picture; /* print the picture at every frame, not only at the end */
static FILE *sound_out;   /* where each frame's sound is written, if anywhere */
static FILE *picture_out; /* where each moment's picture is written, if anywhere */
static const char *save_path; /* the file save memory is read from and written back to, if any */

/* Save memory as the file holds it, and whether that went well. No file is a new cartridge; a
 * file of any other size than the game's save memory is somebody else's save. */
static int read_save_file(void) {
  FILE *file = fopen(save_path, "rb");
  if (!file) return 1;
  size_t size = (size_t)rg_save_size();
  int whole = fread(rg_save_bytes(), 1, size, file) == size && fgetc(file) == EOF;
  fclose(file);
  return whole;
}

/* Puts the file at +from+ where +to+ is, in place of any file there. C's rename does that in one
 * step everywhere but on Windows, where it refuses while the old file is there; so the old file is
 * taken away and the rename tried once more. (The window's own save goes through SDL, whose
 * renaming replaces a file on every system.) */
static int put_file_in_place(const char *from, const char *to) {
  if (rename(from, to) == 0) return 1;
  remove(to);
  return rename(from, to) == 0;
}

/* Save memory written to its file: to a new file beside it, which then takes its place, so a
 * run stopped part way through leaves the old file whole. */
static void write_save_file(void) {
  size_t size = (size_t)rg_save_size();
  size_t room = strlen(save_path) + sizeof ".writing";
  char *writing = malloc(room);
  int written = 0;
  if (writing) {
    snprintf(writing, room, "%s.writing", save_path);
    FILE *file = fopen(writing, "wb");
    written = file && fwrite(rg_save_bytes(), 1, size, file) == size;
    if (file && fclose(file) != 0) written = 0;
    if (written && !put_file_in_place(writing, save_path)) written = 0;
    free(writing);
  }
  if (written) return;
  fprintf(stderr, "the save memory could not be written to %s\n", save_path);
  exit(1);
}

/* The sound of the frame that has just been played, written down. A machine that keeps its
 * numbers the other way round would write them the other way round; every machine this is built
 * for keeps the low byte first. */
static void write_frame_sound(void) {
  int16_t samples[RG_SOUND_FRAME_MOST];
  int32_t count = rg_sound_render_frame(samples);
  if (sound_out) fwrite(samples, sizeof samples[0], (size_t)count, sound_out);
}

/* A whole picture as one line: +word+ and then every pixel, row by row, as four hex digits. */
static void print_pixels(const char *word, const uint16_t *pixels) {
  printf("%s ", word);
  for (int32_t i = 0; i < RG_SCREEN_WIDTH * RG_SCREEN_HEIGHT; i++) printf("%04x", (unsigned)pixels[i]);
  fputc('\n', stdout);
}

/* The picture as it is +shown+, as one number: the CRC-32 of its pixels, each as two bytes with the
 * low byte first — the CRC zip files use, which Ruby's Zlib.crc32 works out from the same bytes.
 * Two pictures with the same number are, in practice, the same picture, so a test can check
 * every frame for eight hex digits apiece and ask for the whole picture only where they differ. */
static void print_picture_crc(const uint16_t *shown) {
  uint32_t crc = 0xFFFFFFFFu;
  for (int32_t i = 0; i < RG_SCREEN_WIDTH * RG_SCREEN_HEIGHT; i++) {
    for (int half = 0; half < 2; half++) {
      crc ^= (uint32_t)((shown[i] >> (8 * half)) & 0xFFu);
      for (int bit = 0; bit < 8; bit++) crc = (crc >> 1) ^ (0xEDB88320u & (0u - (crc & 1u)));
    }
  }
  printf("picture-crc %08x\n", (unsigned)~crc);
}

/* This moment's picture written to the picture file, over the last moment's: as it is +shown+,
 * then as it is stored. Like the sound, it is written the way this machine keeps a number, and
 * every machine this is built for keeps the low byte first. */
static void write_picture(const uint16_t *shown) {
  size_t pixels = (size_t)RG_SCREEN_WIDTH * RG_SCREEN_HEIGHT;
  rewind(picture_out);
  fwrite(shown, sizeof shown[0], pixels, picture_out);
  fwrite(rg_screen_stored(), sizeof shown[0], pixels, picture_out);
  fflush(picture_out);
}

/* Every sprite the game last said is on screen, back to front, a line each: whose it is and which
 * picture it shows, both as the number of a name the game was built with, and where it is. */
static void print_sprites(void) {
  for (int32_t place = 0; place < rg_screen_drawn_count(); place++) {
    rg_drawn_sprite drawn = rg_screen_drawn_sprite(place);
    printf("sprite %d %d %d %d\n", (int)drawn.name, (int)drawn.picture, (int)drawn.x, (int)drawn.y);
  }
}

/* For a game that mixes recordings: the slice made since the last moment ("mix" and its
 * samples), each sounding voice's recording, loudness out of 64, how far its shape has climbed or
 * fallen, and 1 if it is the game's own sound ("mixing"), the most voices
 * that ever sounded at once ("mix_peak"), and how many plays found every voice busy with the
 * most the music held at one of those moments ("mix_drops"). */
static int32_t slices_printed;

static void print_mix(void) {
  if (!rg_game_mix[0]) return;

  if (rg_mix_slices_made() > slices_printed) {
    const int32_t *samples;
    int32_t count = rg_mix_newest_slice(&samples);
    printf("mix");
    for (int32_t i = 0; i < count; i++) printf(" %d", (int)samples[i]);
    fputc('\n', stdout);
    slices_printed = rg_mix_slices_made();
  }
  printf("mixing");
  for (int32_t voice = 0; voice < rg_mix_voice_count(); voice++) {
    int32_t recording, loudness, level, games;
    if (rg_mix_voice_sounding(voice, &recording, &loudness, &level, &games)) {
      printf(" %d %d %d %d", (int)recording, (int)loudness, (int)level, (int)games);
    }
  }
  int32_t music_held;
  int32_t dropped = rg_mix_drops(&music_held);
  printf("\nmix_peak %d\nmix_drops %d %d\n", (int)rg_mix_peak(), (int)dropped, (int)music_held);
}

static void print_moment(const char *heading, int with_picture) {
  printf("%s\n", heading);
  rg_game_dump_state();
  print_sprites();
  print_mix();
  printf("camera %d %d\n", (int)rg_screen_camera_x(), (int)rg_screen_camera_y());
  const uint16_t *shown = rg_screen_shown();
  if (with_picture) {
    print_pixels("picture", shown);
  } else {
    print_picture_crc(shown);
  }
  if (picture_out) write_picture(shown);
}

static _Noreturn void finish(void) {
  print_moment("end", !picture_out);
  if (!picture_out) print_pixels("stored", rg_screen_stored());
  printf("pages %d\n", rg_screen_two_pages() ? 2 : 1);
  fflush(stdout);
  if (sound_out) fclose(sound_out);
  if (picture_out) fclose(picture_out);
  if (save_path) write_save_file();
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

/* "list", the game's name for it, a tab, and its items oldest first — the order the game reads
 * them in, which in a list the game shifts is not the order they sit in memory. A pool's fields
 * come this way too, a slot an item, under the names the build gave them. The tab ends the name,
 * since a pool's field may be called anything, spaces and all. */
static void headless_dump_list(const rg_list *list) {
  printf("list %s\t", list->name);
  for (int32_t i = 0; i < list->length; i++) printf(i ? " %d" : "%d", (int)list->items[rg_list_slot(list, i)]);
  fputc('\n', stdout);
}

static const rg_driver headless = {headless_wait_vblank, headless_halt, headless_fault, headless_dump_variable,
                                   headless_sound_logged, headless_dump_list};

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
    } else if (strcmp(argv[i], "--picture-out") == 0 && i + 1 < argc) {
      picture_out = fopen(argv[++i], "wb");
      if (!picture_out) {
        fprintf(stderr, "the picture could not be written to %s\n", argv[i]);
        return 2;
      }
    } else if (strcmp(argv[i], "--sound-voice") == 0 && i + 1 < argc) {
      rg_sound_hear_only((int32_t)strtol(argv[++i], NULL, 10));
    } else if (strcmp(argv[i], "--save") == 0 && i + 1 < argc) {
      i++;
      if (rg_save_size() == 0) continue; /* a game with no save memory keeps nothing there */
      save_path = argv[i];
      if (!read_save_file()) {
        fprintf(stderr, "the file at %s is not this game's save memory, which is %d bytes\n", save_path, (int)rg_save_size());
        return 2;
      }
    } else if (strcmp(argv[i], "--save-cut-after") == 0 && i + 1 < argc) {
      rg_save_cut_power_after(strtol(argv[++i], NULL, 10));
    }
  }
  rg_active_driver = &headless;
  rg_game_main();
  finish();
}
