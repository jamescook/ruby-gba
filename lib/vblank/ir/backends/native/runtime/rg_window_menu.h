/*
 * THE MENU OVER THE WINDOW (Live::WindowMenu in the library says what it holds and how it looks;
 * Live::Menu is the same menu written in Ruby, for vblank run): how it behaves, and where each of
 * its boxes and words goes. This file is that Ruby written again in C, line for line, and a test
 * (test_native_window_menu.rb) plays the same keys through both and fails at the first thing they
 * draw differently.
 *
 * There is no SDL here, and no window: rg_sdl.c hands it the keys meant for it and draws what it
 * says. Every setting it shows and changes is rg_window.c's, through the same functions a hotkey
 * and the settings file use, so the menu keeps nothing of its own but where it is.
 *
 * It opens on the bar along the top, on the first heading, with that heading's lines showing and
 * none of them chosen. Left and right on the bar go from heading to heading; down, or Enter, goes
 * into the lines, and up from the first line comes back to the bar. In the lines, left and right
 * change a slider's number; on any other line they go on to the next heading, back on the bar, so
 * moving along never changes a line by the way. Enter does what a line says, or switches it on or
 * off. The game is held while the menu is open (rg_sdl.c sees to that).
 *
 * What it holds, its sizes and its colours are written once, in the library, and handed to this
 * file as C data (rg_window_menu_data.c, which the build writes from Live::WindowMenu): a line
 * added there becomes a line here.
 */
#ifndef RG_WINDOW_MENU_H
#define RG_WINDOW_MENU_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* --- what the menu holds, from the library (rg_window_menu_data.c) --- */

typedef enum { RG_MENU_ACTION, RG_MENU_SLIDER, RG_MENU_CHECK } rg_menu_kind;
typedef enum { RG_MENU_NOTHING, RG_MENU_RESUME, RG_MENU_QUIT } rg_menu_does;
/* The settings a line shows, each one of rg_window.c's. */
typedef enum {
  RG_MENU_NO_SETTING,
  RG_MENU_FAST_FORWARD_SPEED,
  RG_MENU_SCALE,
  RG_MENU_FULLSCREEN,
  RG_MENU_VOLUME,
  RG_MENU_MUTED,
  RG_MENU_FRAME_RATE
} rg_menu_setting;
/* How a slider writes its number: "4x", "90%", or "3x  (720 × 480)", the window's size then. */
typedef enum { RG_MENU_NOT_WRITTEN, RG_MENU_TIMES, RG_MENU_PERCENT, RG_MENU_WINDOW } rg_menu_written;

/* A line under a heading. +shortcut+ is the key that does the same outside the menu, written dim
 * at its right, or NULL; +line_before+ draws a line across the box above it. */
typedef struct {
  const char *label;
  rg_menu_kind kind;
  rg_menu_does does;
  rg_menu_setting setting;
  int least, most, step;
  rg_menu_written written;
  const char *shortcut;
  int line_before;
} rg_menu_line;

typedef struct {
  const char *name;
  const rg_menu_line *lines;
  int line_count;
} rg_menu_heading;

/* Sizes in points, which are made pixels by the screen's density. */
typedef struct {
  int bar, row, pad, heading_gap, heading_pad, least_width, label_gap, slider, grab, check, corner, frame_corner, line_before,
    status_gap, status_pad, status_line;
} rg_menu_sizes;

/* Colours as red, green, blue and opacity, 0 to 255 each. */
typedef struct {
  uint8_t text[4], dim[4], bar[4], box[4], border[4], chosen[4], open[4], frame[4], grab[4], status[4], paused[4], fast[4];
} rg_menu_colors;

extern const rg_menu_heading rg_menu_headings[];
extern const int rg_menu_heading_count;
extern const rg_menu_sizes rg_menu_size;
extern const rg_menu_colors rg_menu_color;
/* The most times the picture's size a window can be made (Live::WindowMenu::SCALES). */
extern const int rg_menu_scale_least, rg_menu_scale_most;
/* Whether the game has a menu at all: a game that says menu: false has none. */
extern const int rg_game_has_menu;

/* --- working it --- */

/* The keys the menu is worked with, by what they do: rg_sdl.c knows which of its keys and gamepad
 * buttons is which. */
typedef enum { RG_MENU_UP, RG_MENU_DOWN, RG_MENU_LEFT, RG_MENU_RIGHT, RG_MENU_ENTER, RG_MENU_CLOSE } rg_menu_key;

/* Closed, on the bar on the first heading, with a window +picture_width+ by +picture_height+ at
 * each size; for a window opening, and for each test. */
void rg_window_menu_reset(int picture_width, int picture_height);
/* The biggest the window can be made, in times the picture, on the screen it is on: the Size
 * slider goes no further. */
void rg_window_menu_set_most_scale(int most);

/* Opens the menu, on the bar on the first heading, or closes it. */
void rg_window_menu_toggle(void);
int rg_window_menu_is_open(void);
/* Quit was chosen. */
int rg_window_menu_quit_chosen(void);
/* A key pressed while the menu is open. */
void rg_window_menu_press(rg_menu_key key);

/* --- drawing it --- */

/* Where a letter of a word goes: the rectangle of the font's picture it is in (+from+, as x, y,
 * width, height) and the rectangle of the window it is copied to (+to+), both in pixels. */
typedef struct {
  int from[4], to[4];
} rg_menu_letter;

/* A box with round corners of +radius+, or words: their text, and their letters, which are
 * +letter_count+ of the drawing's +letters+ from +first_letter+. */
typedef struct {
  int is_box;
  int x, y, width, height, radius;
  uint8_t color[4];
  char text[64];
  int first_letter, letter_count;
} rg_menu_part;

#define RG_MENU_PARTS_MOST 64
#define RG_MENU_LETTERS_MOST 512
typedef struct {
  rg_menu_part parts[RG_MENU_PARTS_MOST];
  int part_count;
  rg_menu_letter letters[RG_MENU_LETTERS_MOST];
  int letter_count;
} rg_menu_drawing;

/* WHAT A WINDOW DRAWS over the game, in its own pixels: the menu when it is open, and in the top
 * right corner what the window is doing — the frame rate when it is asked for (+frame_rate+, its
 * number as words, or NULL), how long the game's own work took a frame (+frame_work+, in
 * milliseconds, or NULL), and PAUSED while the game is +held+ or the speed while it is played
 * +fast_forward+ times as fast (0 for not). +width+ is the window's in pixels, and +density+ how
 * many pixels a point is (two on a Retina screen). Parts go into +out+ back to front. */
void rg_window_menu_draw(rg_menu_drawing *out, int width, double density, int held, int fast_forward, const char *frame_rate,
                         const char *frame_work);

#ifdef __cplusplus
}
#endif

#endif
