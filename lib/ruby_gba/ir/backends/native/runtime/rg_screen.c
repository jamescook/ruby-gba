/*
 * The game's picture, drawn in software. See rg_screen.h; each function names the interpreter's
 * method it was ported from, in backends/reference.rb or reference/framebuffer.rb, because that
 * is what decides what is right here.
 *
 * What is NOT here is refused when the game is built rather than drawn wrongly: a tear-free
 * screen's second page, the camera, an area drawing is held inside, a see-through layer, a fade
 * placed in the stack, a stack of named layers, sprites that turn or are drawn in other colors,
 * and the cheaper way the interpreter has of moving sprites over a picture that never changes.
 */
#include "rg_screen.h"
#include "rg_runtime.h"

enum { MAX_OBJECTS = 512 };

static uint16_t pixels[RG_SCREEN_WIDTH * RG_SCREEN_HEIGHT];
static uint16_t shown[RG_SCREEN_WIDTH * RG_SCREEN_HEIGHT];

static int32_t held;            /* switched off until the first frame (Framebuffer#held=) */
static int32_t kind = -1;       /* the kind of screen up; none before the first `screen` */
static int32_t owed;            /* a rebuild of the whole view is owed (Reference#request_repaint) */
static int32_t current_scene = -1;

/* What a display does to the finished picture: one effect at a time (Framebuffer#fade_to). */
static int32_t fade_white, fade_steps;
static enum { TINT_NONE, TINT_TOWARD, TINT_COLOR } tint_mode;
static int32_t tint_white, tint_color, tint_steps;

/* Scenery up, in the order it went up (Reference @bg_shown). The interpreter's list grows by
 * one every time a background is put up, even one already up; putting the same one up again
 * only paints it again on top, so moving it to the end of this list draws the same picture and
 * keeps the list as short as the game's backgrounds. */
static int32_t shown_backgrounds[RG_MAX_BACKGROUNDS];
static int32_t shown_count;

/* How a background is turned, once it has been turned or resized at all (Reference @bg_affine). */
typedef struct { int32_t turned, angle, size, pivot_x, pivot_y; } background_turn;
static background_turn turns[RG_MAX_BACKGROUNDS];

/* The sprites on screen this frame: being said (drawing), and as the last rebuild draws them. */
typedef struct { int32_t image, x, y, level; } placed_object;
static placed_object drawing[MAX_OBJECTS], layer[MAX_OBJECTS];
static int32_t drawing_count, layer_count;

/* --- small arithmetic --- */

/* Division and remainder rounding DOWN, as Ruby's / and % do with a positive divisor. */
static int64_t floor_div(int64_t a, int64_t b) { return a / b - ((a % b != 0) && (a < 0)); }
static int64_t floor_mod(int64_t a, int64_t b) { return a - floor_div(a, b) * b; }
static int32_t clamp32(int64_t value, int32_t low, int32_t high) {
  return (int32_t)(value < low ? low : (value > high ? high : value));
}

static int32_t background_field(int32_t background, int32_t field) {
  return rg_game_backgrounds[background * RG_BG_FIELDS + field];
}

/* --- the picture itself (Framebuffer) --- */

/* Framebuffer#set_pixel: a cell off the screen is dropped. */
static void set_pixel(int64_t x, int64_t y, int32_t color) {
  if (x < 0 || x >= RG_SCREEN_WIDTH || y < 0 || y >= RG_SCREEN_HEIGHT) return;
  pixels[y * RG_SCREEN_WIDTH + x] = (uint16_t)color;
}

/* Framebuffer#clear */
static void clear_to(int32_t color) {
  for (int32_t i = 0; i < RG_SCREEN_WIDTH * RG_SCREEN_HEIGHT; i++) pixels[i] = (uint16_t)color;
}

void rg_screen_clear(int32_t color) { clear_to(color); }

/* Framebuffer#fill_rect: every cell of the rectangle, each through set_pixel. Walking only the
 * part on the screen paints the same cells. */
void rg_screen_fill_rect(int32_t x, int32_t y, int32_t width, int32_t height, int32_t color) {
  int64_t left = x < 0 ? 0 : x, top = y < 0 ? 0 : y;
  int64_t right = (int64_t)x + width, bottom = (int64_t)y + height;
  if (right > RG_SCREEN_WIDTH) right = RG_SCREEN_WIDTH;
  if (bottom > RG_SCREEN_HEIGHT) bottom = RG_SCREEN_HEIGHT;
  for (int64_t py = top; py < bottom; py++)
    for (int64_t px = left; px < right; px++) set_pixel(px, py, color);
}

void rg_screen_pixel(int32_t x, int32_t y, int32_t color) { set_pixel(x, y, color); }

/* Reference#exec_draw_text: each lit pixel of each letter, from the text's top left. */
void rg_screen_points(int32_t x, int32_t y, int32_t color, const int16_t *points, int32_t count) {
  for (int32_t i = 0; i < count; i++) set_pixel((int64_t)x + points[2 * i], (int64_t)y + points[2 * i + 1], color);
}

/* Reference#exec_draw_digit */
void rg_screen_digit(int32_t value, int32_t x, int32_t y, int32_t color, const int16_t *points,
                     const int32_t *starts) {
  if (value < 0 || value > 9) return;
  rg_screen_points(x, y, color, points + 2 * starts[value], starts[value + 1] - starts[value]);
}

/* --- effects over the finished picture (Framebuffer#faded) --- */

/* Framebuffer#blend: each channel moved a truncated share of the way to black or white. */
static uint16_t blend(uint16_t color, int32_t white, int32_t steps, int32_t out_of) {
  if (steps == 0) return color;
  int32_t out = 0;
  for (int32_t channel = 0; channel < 3; channel++) {
    int32_t c = (color >> (5 * channel)) & 0x1F;
    c = white ? c + ((31 - c) * steps) / out_of : c - (c * steps) / out_of;
    out |= c << (5 * channel);
  }
  return (uint16_t)out;
}

/* Framebuffer#mixed: the two shares added, and only then the fraction dropped. */
static uint16_t mixed(uint16_t color, int32_t toward, int32_t steps) {
  if (steps == 0) return color;
  int32_t keep = 32 - steps, out = 0;
  for (int32_t channel = 0; channel < 3; channel++) {
    int32_t have = (color >> (5 * channel)) & 0x1F, want = (toward >> (5 * channel)) & 0x1F;
    out |= ((have * keep + want * steps) / 32) << (5 * channel);
  }
  return (uint16_t)out;
}

static uint16_t faded(uint16_t color) {
  if (tint_mode == TINT_TOWARD) return blend(color, tint_white, tint_steps, 32);
  if (tint_mode == TINT_COLOR) return mixed(color, tint_color, tint_steps);
  return blend(color, fade_white, fade_steps, 16);
}

/* Reference#exec_fade (the whole-screen kinds), through Framebuffer#fade_steps_to or, for a
 * fade that walks the colors, #tint_steps_to. */
void rg_screen_fade(int32_t toward_white, int32_t steps, int32_t walked) {
  if (walked) {
    tint_mode = TINT_TOWARD;
    tint_white = toward_white;
    tint_steps = steps;
    fade_steps = 0;
  } else {
    fade_white = toward_white;
    fade_steps = steps;
    tint_mode = TINT_NONE;
  }
}

/* Framebuffer#tint_steps_to */
void rg_screen_tint(int32_t color, int32_t steps) {
  tint_mode = TINT_COLOR;
  tint_color = color;
  tint_steps = steps;
  fade_steps = 0;
}

/* Backends::FadeSteps.steps */
int32_t rg_fade_steps(int32_t amount, int32_t fraction_bits, int32_t walked) {
  int32_t levels = walked ? 32 : 16;
  if (fraction_bits < 0) {
    int32_t sixteenths = clamp32(floor_div((int64_t)amount * 16, 100), 0, 16);
    return walked ? sixteenths * 2 : sixteenths;
  }
  return clamp32(floor_div((int64_t)amount * levels, (int64_t)100 << fraction_bits), 0, levels);
}

/* --- scenery --- */

static int32_t map_cell(int32_t background, int64_t row, int64_t col) {
  if (row < 0 || row >= background_field(background, RG_BG_MAP_ROWS)) return -1;
  if (col < 0 || col >= background_field(background, RG_BG_MAP_COLS)) return -1;
  int64_t at = background_field(background, RG_BG_MAP_START) + row * background_field(background, RG_BG_MAP_COLS) + col;
  return rg_game_map_cells[at];
}

/* One pixel of a cell's tile, or RG_SEE_THROUGH (Reference#background_pixel). */
static uint16_t tile_pixel(int32_t background, int32_t cell, int64_t tx, int64_t ty) {
  int32_t tile_w = background_field(background, RG_BG_TILE_W), tile_h = background_field(background, RG_BG_TILE_H);
  int64_t at = background_field(background, RG_BG_TILES_START) + (int64_t)cell * tile_w * tile_h + ty * tile_w + tx;
  return rg_game_tile_pixels[at];
}

/* Reference#stamp_background: the whole map onto the picture, cell by cell. */
void rg_background_stamp(int32_t background) {
  int32_t tile_w = background_field(background, RG_BG_TILE_W), tile_h = background_field(background, RG_BG_TILE_H);
  for (int32_t row = 0; row < background_field(background, RG_BG_MAP_ROWS); row++) {
    for (int32_t col = 0; col < background_field(background, RG_BG_MAP_COLS); col++) {
      int32_t cell = map_cell(background, row, col);
      if (cell < 0) continue;
      for (int32_t ty = 0; ty < tile_h; ty++)
        for (int32_t tx = 0; tx < tile_w; tx++) {
          uint16_t color = tile_pixel(background, cell, tx, ty);
          if (color != RG_SEE_THROUGH) set_pixel((int64_t)col * tile_w + tx, (int64_t)row * tile_h + ty, color);
        }
    }
  }
}

/* Reference#request_repaint (a bending background, which would paint at once, is refused). */
static void request_repaint(void) { owed = 1; }

/* Reference#put_up_background: a turned background is painted through its turn at the next
 * rebuild rather than stamped as drawn. The interpreter also stamps again the backgrounds a
 * named layer puts in front of this one; the build refuses named layers, so there are none. */
void rg_background_put_up(int32_t background) {
  int32_t kept = 0;
  for (int32_t i = 0; i < shown_count; i++)
    if (shown_backgrounds[i] != background) shown_backgrounds[kept++] = shown_backgrounds[i];
  shown_backgrounds[kept] = background;
  shown_count = kept + 1;
  if (turns[background].turned) {
    request_repaint();
    return;
  }
  rg_background_stamp(background);
}

/* Reference#exec_affine_background: the angle wraps into 0..359 as Ruby's % does. */
void rg_background_turn(int32_t background, int32_t angle, int32_t size, int32_t pivot_x, int32_t pivot_y) {
  turns[background] = (background_turn){1, (int32_t)floor_mod(angle, 360), size, pivot_x, pivot_y};
  request_repaint();
}

/* Reference#showing_scenery: scenery every screen shows, and the running scene's own. */
static int32_t showing(int32_t background) {
  int32_t scene = background_field(background, RG_BG_SCENE);
  return scene == RG_EVERY_SCENE || scene == current_scene;
}

/* Reference#paint_background_window, for a background never turned: the map wraps over the
 * console's whole grid, and a row or cell past the map shows what is behind. */
static void paint_window(int32_t background) {
  int32_t tile_w = background_field(background, RG_BG_TILE_W), tile_h = background_field(background, RG_BG_TILE_H);
  int64_t map_w = (int64_t)background_field(background, RG_BG_GRID_COLS) * tile_w;
  int64_t map_h = (int64_t)background_field(background, RG_BG_GRID_ROWS) * tile_h;
  if (map_w == 0 || map_h == 0) return;
  for (int64_t py = 0; py < RG_SCREEN_HEIGHT; py++) {
    int64_t my = py % map_h;
    if (my / tile_h >= background_field(background, RG_BG_MAP_ROWS)) continue;
    for (int64_t px = 0; px < RG_SCREEN_WIDTH; px++) {
      int64_t mx = px % map_w;
      int32_t cell = map_cell(background, my / tile_h, mx / tile_w);
      if (cell < 0) continue;
      uint16_t color = tile_pixel(background, cell, mx % tile_w, my % tile_h);
      if (color != RG_SEE_THROUGH) pixels[py * RG_SCREEN_WIDTH + px] = color;
    }
  }
}

/* IR::Affine.matrix: one over the size, held at the largest number the matrix holds; then the
 * sine table, cos d being sin(d + 90). The numbers come from rg_game_turn_rules, which the build
 * writes from Ruby's own, so the two cannot drift. */
static void affine_matrix(int32_t angle, int32_t size, int64_t *turn_cos, int64_t *turn_sin) {
  int64_t scale_one = rg_game_turn_rules[0], one_th = rg_game_turn_rules[1];
  int64_t most = rg_game_turn_rules[2], least_size = rg_game_turn_rules[3];
  int64_t scale = size < least_size ? least_size : size;
  int64_t recip = scale_one * one_th / scale;
  if (recip > most) recip = most;
  *turn_cos = floor_div(rg_game_sines[angle + 90] * recip, one_th);
  *turn_sin = floor_div(rg_game_sines[angle] * recip, one_th);
}

/* Reference#paint_affine_background_window: for each screen pixel, work back through the turn
 * to the map pixel that lands there. */
static void paint_turned_window(int32_t background) {
  int32_t tile_w = background_field(background, RG_BG_TILE_W), tile_h = background_field(background, RG_BG_TILE_H);
  int64_t map_w = (int64_t)background_field(background, RG_BG_GRID_COLS) * tile_w;
  int64_t map_h = (int64_t)background_field(background, RG_BG_GRID_ROWS) * tile_h;
  if (map_w == 0 || map_h == 0) return;
  const background_turn *turn = &turns[background];
  int64_t pivot_x = turn->pivot_x, pivot_y = turn->pivot_y, one_th = rg_game_turn_rules[1];
  int64_t turn_cos, turn_sin;
  affine_matrix(turn->angle, turn->size, &turn_cos, &turn_sin);
  for (int64_t py = 0; py < RG_SCREEN_HEIGHT; py++) {
    int64_t dy = py - pivot_y;
    for (int64_t px = 0; px < RG_SCREEN_WIDTH; px++) {
      int64_t dx = px - pivot_x;
      int64_t mx = floor_mod(pivot_x + floor_div(turn_cos * dx + turn_sin * dy, one_th), map_w);
      int64_t my = floor_mod(pivot_y + floor_div(-turn_sin * dx + turn_cos * dy, one_th), map_h);
      int32_t cell = map_cell(background, my / tile_h, mx / tile_w);
      if (cell < 0) continue;
      uint16_t color = tile_pixel(background, cell, mx % tile_w, my % tile_h);
      if (color != RG_SEE_THROUGH) set_pixel(px, py, color);
    }
  }
}

/* --- sprites --- */

/* Reference#blit_image: a see-through pixel is skipped, and each other one goes on as stored. */
static void blit_image(int32_t image, int32_t x, int32_t y) {
  const int32_t *info = rg_game_images + 4 * image;
  int32_t start = info[0], width = info[1], height = info[2], see_through = info[3];
  for (int32_t row = 0; row < height; row++)
    for (int32_t col = 0; col < width; col++) {
      uint16_t color = rg_game_image_pixels[start + row * width + col];
      if (see_through >= 0 && color == see_through) continue;
      set_pixel((int64_t)x + col, (int64_t)y + row, color);
    }
}

void rg_objects_begin(void) { drawing_count = 0; }

void rg_objects_add(int32_t image, int32_t x, int32_t y, int32_t level) {
  if (drawing_count >= MAX_OBJECTS) rg_fault("more than %d sprites on screen at once", MAX_OBJECTS);
  drawing[drawing_count++] = (placed_object){image, x, y, level};
}

/* Reference#exec_present_objects on a picture that is rebuilt whole: the sprites on screen now
 * are kept (#snapshot_object_layer) and the rebuild is owed. */
void rg_objects_end(void) {
  for (int32_t i = 0; i < drawing_count; i++) layer[i] = drawing[i];
  layer_count = drawing_count;
  request_repaint();
}

/* --- the whole view, rebuilt (Reference#repaint_view) --- */

static void repaint_view(void) {
  clear_to(0);
  int32_t backgrounds = rg_game_picture_sizes[0], levels = rg_game_picture_sizes[1];
  for (int32_t level = 0; level < levels; level++) {
    for (int32_t bg = 0; bg < backgrounds; bg++) {
      if (!showing(bg) || background_field(bg, RG_BG_LEVEL) != level) continue;
      if (turns[bg].turned) paint_turned_window(bg);
      else paint_window(bg);
    }
    for (int32_t i = 0; i < layer_count; i++)
      if (layer[i].level == level) blit_image(layer[i].image, layer[i].x, layer[i].y);
  }
}

/* Reference#paint_owed_repaint */
void rg_screen_paint_owed_rebuild(void) {
  if (!owed) return;
  owed = 0;
  repaint_view();
}

/* --- screens and scenes --- */

void rg_screen_hold(int32_t value) { held = value; }
void rg_screen_frame_started(void) { held = 0; }

/* Reference#exec_screen. Every kind of screen is a display of its own, so any change of kind
 * wipes the picture and takes the scenery down; arriving on a screen drawn from tiles puts up
 * again what every such screen shows (#put_up_always_up). */
void rg_screen_set(int32_t new_kind) {
  int32_t crossing = kind >= 0 && kind != new_kind;
  if (crossing) {
    clear_to(0);
    shown_count = 0;
  }
  kind = new_kind;
  if (crossing && new_kind != RG_BITMAP)
    for (int32_t i = 0; i < rg_game_picture_sizes[2]; i++) rg_background_put_up(rg_game_always_up[i]);
}

/* Reference#cross_to_scene_screen */
void rg_screen_cross_to(int32_t new_kind) {
  if (kind >= 0 && kind != new_kind) rg_screen_set(new_kind);
}

void rg_scene_enter(int32_t scene) { current_scene = scene; }

/* The middle of Reference#take_over, and #take_down_scenery: the last scene's own scenery comes
 * down, and the picture goes back to the scenery every screen shows. */
void rg_scene_take_down(int32_t brings_scenery) {
  int32_t any_scene_owned = 0;
  for (int32_t i = 0; i < shown_count; i++)
    if (background_field(shown_backgrounds[i], RG_BG_SCENE) != RG_EVERY_SCENE) any_scene_owned = 1;
  if (!any_scene_owned && !brings_scenery) return;

  rg_screen_paint_owed_rebuild();
  int32_t kept = 0;
  for (int32_t i = 0; i < shown_count; i++)
    if (!background_field(shown_backgrounds[i], RG_BG_ON_ARRIVAL)) shown_backgrounds[kept++] = shown_backgrounds[i];
  if (kept == shown_count) return;

  shown_count = kept;
  clear_to(0);
  for (int32_t i = 0; i < kept; i++) rg_background_stamp(shown_backgrounds[i]);
}

/* --- reading it back --- */

/* Framebuffer#shown, with what a switched-off display shows (plain white) while held. */
const uint16_t *rg_screen_shown(void) {
  rg_screen_paint_owed_rebuild();
  for (int32_t i = 0; i < RG_SCREEN_WIDTH * RG_SCREEN_HEIGHT; i++) shown[i] = held ? (uint16_t)0x7FFF : faded(pixels[i]);
  return shown;
}
