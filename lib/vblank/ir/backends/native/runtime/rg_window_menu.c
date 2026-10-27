/*
 * The window menu (rg_window_menu.h), written again from Live::Menu, line for line: change one and
 * change the other, or test_native_window_menu.rb says where they part.
 */
#include "rg_window_menu.h"

#include <stdio.h>
#include <string.h>
#include "rg_menu_font.h"
#include "rg_window.h"

/* Where the menu is: open or not, the heading whose lines show, the line chosen under it (-1
 * while the bar is), and whether Quit was chosen. */
static int menu_open, quit_chosen, heading, row = -1;
static int picture_width, picture_height;
static int most_scale = RG_WINDOW_SCALE_MOST;

static int clamped(int value, int least, int most) { return value < least ? least : value > most ? most : value; }

void rg_window_menu_reset(int width, int height) {
  menu_open = quit_chosen = heading = 0;
  row = -1;
  picture_width = width;
  picture_height = height;
  most_scale = rg_menu_scale_most;
}

void rg_window_menu_set_most_scale(int most) {
  most_scale = clamped(most, rg_menu_scale_least, rg_menu_scale_most);
}

int rg_window_menu_is_open(void) { return menu_open; }
int rg_window_menu_quit_chosen(void) { return quit_chosen; }

void rg_window_menu_toggle(void) {
  menu_open = !menu_open;
  heading = 0;
  row = -1;
}

static const rg_menu_heading *open_lines(void) { return &rg_menu_headings[heading]; }

/* How far a slider goes: the window's size no further than the screen has room for. */
static void limits(const rg_menu_line *line, int *least, int *most) {
  *least = line->least;
  *most = line->most;
  if (line->setting != RG_MENU_SCALE) return;
  if (*least < rg_menu_scale_least) *least = rg_menu_scale_least;
  if (*most > most_scale) *most = most_scale;
}

/* A setting as the menu shows it: rg_window.c's, with the window's size no bigger than fits. */
static int setting_value(rg_menu_setting setting) {
  switch (setting) {
  case RG_MENU_FAST_FORWARD_SPEED:
    return rg_window_fast_speed();
  case RG_MENU_SCALE:
    return clamped(rg_window_scale(), rg_menu_scale_least, most_scale);
  case RG_MENU_FULLSCREEN:
    return rg_window_fullscreen();
  case RG_MENU_VOLUME:
    return rg_window_volume();
  case RG_MENU_MUTED:
    return rg_window_muted();
  case RG_MENU_FRAME_RATE:
    return rg_window_shows_frame_rate();
  case RG_MENU_NO_SETTING:
    break;
  }
  return 0;
}

static void set_setting(rg_menu_setting setting, int value) {
  switch (setting) {
  case RG_MENU_FAST_FORWARD_SPEED:
    rg_window_set_fast_speed(value);
    break;
  case RG_MENU_SCALE:
    rg_window_set_scale(value);
    break;
  case RG_MENU_FULLSCREEN:
    rg_window_set_fullscreen(value);
    break;
  case RG_MENU_VOLUME:
    rg_window_set_volume(value);
    break;
  case RG_MENU_MUTED:
    rg_window_set_mute(value);
    break;
  case RG_MENU_FRAME_RATE:
    rg_window_set_show_frame_rate(value);
    break;
  case RG_MENU_NO_SETTING:
    break;
  }
}

static void press_on_bar(rg_menu_key key);

static void move_heading(rg_menu_key key) {
  heading = (heading + (key == RG_MENU_RIGHT ? 1 : -1) + rg_menu_heading_count) % rg_menu_heading_count;
  row = -1;
}

static void slide(const rg_menu_line *line, int direction) {
  int least, most;
  limits(line, &least, &most);
  int value = setting_value(line->setting) + direction * line->step;
  set_setting(line->setting, clamped(value, least, most));
}

static void enter(const rg_menu_line *line) {
  switch (line->kind) {
  case RG_MENU_CHECK:
    set_setting(line->setting, !setting_value(line->setting));
    break;
  case RG_MENU_ACTION:
    if (line->does == RG_MENU_RESUME) menu_open = 0;
    if (line->does == RG_MENU_QUIT) quit_chosen = 1;
    break;
  case RG_MENU_SLIDER:
    break;
  }
}

void rg_window_menu_press(rg_menu_key key) {
  if (key == RG_MENU_CLOSE) {
    rg_window_menu_toggle();
    return;
  }
  if (row < 0) {
    press_on_bar(key);
    return;
  }
  const rg_menu_heading *lines = open_lines();
  const rg_menu_line *line = &lines->lines[row];
  switch (key) {
  case RG_MENU_UP:
    row -= 1;
    break;
  case RG_MENU_DOWN:
    row = (row + 1) % lines->line_count;
    break;
  case RG_MENU_LEFT:
  case RG_MENU_RIGHT:
    if (line->kind == RG_MENU_SLIDER) slide(line, key == RG_MENU_RIGHT ? 1 : -1);
    else move_heading(key);
    break;
  case RG_MENU_ENTER:
    enter(line);
    break;
  case RG_MENU_CLOSE:
    break;
  }
}

static void press_on_bar(rg_menu_key key) {
  switch (key) {
  case RG_MENU_LEFT:
  case RG_MENU_RIGHT:
    move_heading(key);
    break;
  case RG_MENU_DOWN:
  case RG_MENU_ENTER:
    row = 0;
    break;
  case RG_MENU_UP:
  case RG_MENU_CLOSE:
    break;
  }
}

/* --- drawing --- */

static rg_menu_drawing *out;
static double density;
static int heading_left;

static int pixels(int points) { return rg_menu_rounded((double)points * density); }

/* Ruby's division of whole numbers, which rounds down rather than towards nought. */
static int halved(int value) { return value >= 0 ? value / 2 : -((-value + 1) / 2); }

/* A box to draw, added to what rg_window_menu_draw gives. */
static void add_box(int x, int y, int width, int height, int radius, const uint8_t color[4]) {
  if (out->part_count == RG_MENU_PARTS_MOST) return;
  rg_menu_part *part = &out->parts[out->part_count++];
  memset(part, 0, sizeof *part);
  part->is_box = 1;
  part->x = x;
  part->y = y;
  part->width = width;
  part->height = height;
  part->radius = radius;
  memcpy(part->color, color, 4);
}

/* Words to draw, the top left of their line at +x+, +y+, added to what rg_window_menu_draw gives. */
static void add_words(const char *text, int x, int y, const uint8_t color[4]) {
  if (out->part_count == RG_MENU_PARTS_MOST) return;
  rg_menu_part *part = &out->parts[out->part_count++];
  memset(part, 0, sizeof *part);
  snprintf(part->text, sizeof part->text, "%s", text);
  memcpy(part->color, color, 4);
  part->first_letter = out->letter_count;
  part->letter_count =
    rg_menu_font_layout(text, x, y, density, &out->letters[out->letter_count], RG_MENU_LETTERS_MOST - out->letter_count);
  out->letter_count += part->letter_count;
}

static int width_of(const char *text) { return rg_menu_font_width(text, density); }

/* +text+ with its line in the middle of a row +height+ pixels high from +top+. */
static void add_words_in_row(const char *text, int x, int top, int height, const uint8_t color[4]) {
  add_words(text, x, top + halved(height - rg_menu_font_line_height(density)), color);
}

/* The bar along the top, its headings, and the open one marked. Gives how tall it is. */
static int draw_bar(int width) {
  int bar = pixels(rg_menu_size.bar);
  add_box(0, 0, width, bar, 0, rg_menu_color.bar);
  int x = pixels(rg_menu_size.pad);
  for (int index = 0; index < rg_menu_heading_count; index++) {
    const char *name = rg_menu_headings[index].name;
    int wide = width_of(name);
    if (index == heading) {
      heading_left = x - pixels(rg_menu_size.heading_pad);
      add_box(heading_left, 0, wide + 2 * pixels(rg_menu_size.heading_pad), bar, 0, row < 0 ? rg_menu_color.chosen : rg_menu_color.open);
    }
    add_words_in_row(name, x, 0, bar, rg_menu_color.text);
    x += wide + pixels(rg_menu_size.heading_gap);
  }
  return bar;
}

/* How much room the right of a line takes: a slider, a shortcut, or a check mark. */
static int right_width(const rg_menu_line *line) {
  switch (line->kind) {
  case RG_MENU_SLIDER:
    return pixels(rg_menu_size.slider);
  case RG_MENU_CHECK:
    return pixels(rg_menu_size.check);
  case RG_MENU_ACTION:
    break;
  }
  return line->shortcut ? width_of(line->shortcut) : 0;
}

static void slider_text(const rg_menu_line *line, int value, char *text, size_t room) {
  switch (line->written) {
  case RG_MENU_TIMES:
    snprintf(text, room, "%dx", value);
    break;
  case RG_MENU_PERCENT:
    snprintf(text, room, "%d%%", value);
    break;
  case RG_MENU_WINDOW:
    snprintf(text, room, "%dx  (%d \xC3\x97 %d)", value, picture_width * value, picture_height * value);
    break;
  case RG_MENU_NOT_WRITTEN:
    text[0] = '\0';
    break;
  }
}

/* A slider as Dear ImGui draws one: a frame, a grab as far along it as the number is, and the
 * number written in the middle. */
static void draw_slider(const rg_menu_line *line, int x, int y, int wide, int high) {
  add_box(x, y, wide, high, pixels(rg_menu_size.frame_corner), rg_menu_color.frame);
  int inset = pixels(2);
  int least, most;
  limits(line, &least, &most);
  int value = setting_value(line->setting);
  int travel = wide - pixels(rg_menu_size.grab) - 2 * inset;
  int along = most > least ? travel * (value - least) / (most - least) : 0;
  add_box(x + inset + along, y + inset, pixels(rg_menu_size.grab), high - 2 * inset, pixels(2), rg_menu_color.grab);
  char text[64];
  slider_text(line, value, text, sizeof text);
  add_words_in_row(text, x + halved(wide - width_of(text)), y, high, rg_menu_color.text);
}

static void draw_line(const rg_menu_line *line, int x, int y, int inner, int row_height) {
  add_words_in_row(line->label, x, y, row_height, rg_menu_color.text);
  int right = x + inner;
  switch (line->kind) {
  case RG_MENU_ACTION:
    if (line->shortcut) add_words_in_row(line->shortcut, right - width_of(line->shortcut), y, row_height, rg_menu_color.dim);
    break;
  case RG_MENU_CHECK:
    if (setting_value(line->setting)) add_words_in_row("\xE2\x9C\x93", right - width_of("\xE2\x9C\x93"), y, row_height, rg_menu_color.text);
    break;
  case RG_MENU_SLIDER:
    draw_slider(line, right - pixels(rg_menu_size.slider), y + pixels(2), pixels(rg_menu_size.slider), row_height - pixels(4));
    break;
  }
}

/* The open heading's lines, in a box under it with a border a point wide. */
static void draw_lines(int top) {
  const rg_menu_heading *lines = open_lines();
  int pad = pixels(rg_menu_size.pad);
  int row_height = pixels(rg_menu_size.row);
  int inner = pixels(rg_menu_size.least_width);
  int separated = 0;
  int widest = 0;
  for (int i = 0; i < lines->line_count; i++) {
    const rg_menu_line *line = &lines->lines[i];
    int wide = width_of(line->label) + pixels(rg_menu_size.label_gap) + right_width(line);
    if (i == 0 || wide > widest) widest = wide;
    if (line->line_before) separated++;
  }
  if (widest > inner) inner = widest;
  int wide = inner + 2 * pad;
  int high = lines->line_count * row_height + 2 * pad + separated * pixels(rg_menu_size.line_before);
  int border = pixels(1);
  add_box(heading_left, top, wide, high, pixels(rg_menu_size.corner), rg_menu_color.border);
  add_box(heading_left + border, top + border, wide - 2 * border, high - 2 * border, pixels(rg_menu_size.corner) - border,
          rg_menu_color.box);
  int y = top + pad;
  for (int index = 0; index < lines->line_count; index++) {
    const rg_menu_line *line = &lines->lines[index];
    if (line->line_before) {
      add_box(heading_left + pad, y + halved(pixels(rg_menu_size.line_before)), inner, border, 0, rg_menu_color.border);
      y += pixels(rg_menu_size.line_before);
    }
    if (index == row) add_box(heading_left + halved(pad), y, wide - pad, row_height, pixels(rg_menu_size.frame_corner), rg_menu_color.chosen);
    draw_line(line, heading_left + pad, y, inner, row_height);
    y += row_height;
  }
}

/* What the window is doing, in a see-through box in the top right corner, under the bar when the
 * menu is open. */
static void draw_status(int width, int top, int held, int fast_forward, const char *frame_rate, const char *frame_work) {
  char said[3][64];
  const uint8_t *colors[3];
  int count = 0;
  if (frame_rate) {
    snprintf(said[count], sizeof said[count], "%s fps", frame_rate);
    colors[count++] = rg_menu_color.text;
  }
  if (frame_work) {
    snprintf(said[count], sizeof said[count], "%s ms of work a frame", frame_work);
    colors[count++] = rg_menu_color.text;
  }
  if (held) {
    snprintf(said[count], sizeof said[count], "PAUSED");
    colors[count++] = rg_menu_color.paused;
  } else if (fast_forward) {
    snprintf(said[count], sizeof said[count], "FAST FORWARD %dx", fast_forward);
    colors[count++] = rg_menu_color.fast;
  }
  if (count == 0) return;

  int pad = pixels(rg_menu_size.status_pad);
  int line = pixels(rg_menu_size.status_line);
  int widest = 0;
  for (int i = 0; i < count; i++) {
    int wide = width_of(said[i]);
    if (i == 0 || wide > widest) widest = wide;
  }
  int wide = widest + 2 * pad;
  int x = width - wide - pixels(rg_menu_size.status_gap);
  int y = top + pixels(rg_menu_size.status_gap);
  add_box(x, y, wide, count * line + 2 * pad, pixels(rg_menu_size.corner), rg_menu_color.status);
  for (int i = 0; i < count; i++) add_words(said[i], x + pad, y + pad + i * line, colors[i]);
}

void rg_window_menu_draw(rg_menu_drawing *drawing, int width, double pixels_a_point, int held, int fast_forward, const char *frame_rate,
                         const char *frame_work) {
  out = drawing;
  out->part_count = 0;
  out->letter_count = 0;
  density = pixels_a_point;
  int top = 0;
  if (menu_open) {
    top = draw_bar(width);
    draw_lines(top);
  }
  draw_status(width, top, held, fast_forward, frame_rate, frame_work);
}
