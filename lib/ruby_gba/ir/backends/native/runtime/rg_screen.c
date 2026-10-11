/*
 * The game's picture, drawn in software. See rg_screen.h; each function names the interpreter's
 * method it was ported from, in backends/reference.rb or reference/framebuffer.rb, because that
 * is what decides what is right here.
 *
 * What is NOT here is refused when the game is built rather than drawn wrongly: scenery that
 * scrolls, bends or has its cells or its map changed, a see-through layer, a fade placed in the
 * stack, and sprites that turn or change layer.
 *
 * A sprite's pictures arrive ready to draw: which of its pixels show, and the colors of each
 * list it can be drawn with, are worked out when the game is built (see native/picture.rb).
 */
#include "rg_screen.h"
#include "rg_runtime.h"

#include <stdlib.h>

enum { CELLS = RG_SCREEN_WIDTH * RG_SCREEN_HEIGHT };

/* TWO PAGES, OR ONE (Framebuffer#paged=). A tear-free screen is two pictures: the display shows
 * one while the game draws into the other, and they trade places between frames, so nobody ever
 * sees a half-drawn picture. Drawing always lands on +pixels+ and the viewer always reads
 * +viewed+; with one page those are the same picture. */
static uint16_t first_page[CELLS], second_page[CELLS];
static uint16_t *pixels = first_page;
static uint16_t *viewed = first_page;
static uint16_t shown[CELLS];

/* Where drawing goes: the picture, or for a moment the copy of the scenery kept to put back
 * under a sprite (Reference#drawing_into). */
static uint16_t *target = first_page;

/* The part of the screen drawing is held inside (Framebuffer#draw_inside), when it is held, and
 * the areas in force around it, given back as each `inside` ends: a routine with an area of its
 * own can be called from inside another's. */
typedef struct { int32_t held_in; int64_t left, top, right, bottom; } drawing_area;
enum { AREAS_DEEP = 64 };
static drawing_area area, outer_areas[AREAS_DEEP];
static int32_t areas_deep;

/* Where the window onto the picture sits (Framebuffer#camera_to): screen (0, 0) shows what was
 * drawn at (camera_x, camera_y). Nothing drawn moves. */
static int32_t camera_x, camera_y;

/* The patches of picture saved under bitmap sprites, by buffer number (Reference @backing): each
 * cell a color, or NO_CELL where the patch hung off what could be read. Nothing until the first
 * save. */
enum { NO_CELL = -1 };
static int32_t **saved_patches;
static int32_t patches_room;

/* THE SCENERY WITH NOTHING ON IT (Reference @scene_fb): the backdrop and every background up,
 * painted once and kept. A sprite on a picture that is not rebuilt every frame is drawn straight
 * onto it, so before it is drawn somewhere new the patch it covered is put back from here. Made
 * again whenever the scenery changes. */
static uint16_t scenery[RG_SCREEN_WIDTH * RG_SCREEN_HEIGHT];
static int32_t scenery_kept;

static int32_t held;            /* switched off until the first frame (Framebuffer#held=) */
static int32_t kind = -1;       /* the kind of screen up; none before the first `screen` */
static int32_t owed;            /* a rebuild of the whole view is owed (Reference#request_repaint) */
static int32_t current_scene = -1;

/* What a display does to the finished picture: one effect at a time (Framebuffer#fade_to). */
static int32_t fade_white, fade_steps;
static enum { TINT_NONE, TINT_TOWARD, TINT_COLOR } tint_mode;
static int32_t tint_white, tint_color, tint_steps;

/* Scenery up, in the order it went up (Reference @bg_shown): one entry for every time a
 * background is put up, even one already up, exactly as the interpreter keeps it. The repeats
 * matter once layers are named. The order the stack asks for is worked out among the places the
 * entries hold in this list, so a background put up twice holds two of them, and leaving the
 * first out moves every background between the two. */
static int32_t *shown_backgrounds;
static int32_t shown_count, shown_room;

/* How a background is turned, once it has been turned or resized at all (Reference @bg_affine). */
typedef struct { int32_t turned, angle, size, pivot_x, pivot_y; } background_turn;
static background_turn turns[RG_MAX_BACKGROUNDS];

/* The sprites on screen this frame: being said (drawing), and as the last rebuild draws them. */
typedef struct { int32_t sprite, image, x, y, level; } placed_object;
static placed_object drawing[RG_MAX_SPRITES], layer[RG_MAX_SPRITES];
static int32_t drawing_count, layer_count;

/* Where each sprite was last drawn straight onto the picture, by its number, so that patch can
 * be put back before it is drawn again (Reference @obj_prev). */
typedef struct { int32_t drawn, x, y; } drawn_place;
static drawn_place last_drawn[RG_MAX_SPRITES];

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

static int32_t on_screen(int64_t x, int64_t y) {
  return x >= 0 && x < RG_SCREEN_WIDTH && y >= 0 && y < RG_SCREEN_HEIGHT;
}

/* Framebuffer#in_bounds?: on the screen, and inside the area drawing is held to when it is. */
static int32_t in_bounds(int64_t x, int64_t y) {
  if (!on_screen(x, y)) return 0;
  return !area.held_in || (x >= area.left && x < area.right && y >= area.top && y < area.bottom);
}

/* Framebuffer#set_pixel: a cell drawing may not land on is dropped. */
static void set_pixel(int64_t x, int64_t y, int32_t color) {
  if (in_bounds(x, y)) target[y * RG_SCREEN_WIDTH + x] = (uint16_t)color;
}

/* Framebuffer#fill_rect: every cell of the rectangle, each through set_pixel. Walking only the
 * part on the screen paints the same cells. */
static void fill_cells(int64_t x, int64_t y, int64_t width, int64_t height, int32_t color) {
  int64_t left = x < 0 ? 0 : x, top = y < 0 ? 0 : y;
  int64_t right = x + width, bottom = y + height;
  if (right > RG_SCREEN_WIDTH) right = RG_SCREEN_WIDTH;
  if (bottom > RG_SCREEN_HEIGHT) bottom = RG_SCREEN_HEIGHT;
  for (int64_t py = top; py < bottom; py++)
    for (int64_t px = left; px < right; px++) set_pixel(px, py, color);
}

/* Framebuffer#clear: the whole picture, or the area drawing is held to and no more. */
static void clear_to(int32_t color) {
  if (area.held_in) {
    fill_cells(area.left, area.top, area.right - area.left, area.bottom - area.top, color);
    return;
  }
  for (int32_t i = 0; i < CELLS; i++) target[i] = (uint16_t)color;
}

void rg_screen_clear(int32_t color) { clear_to(color); }

void rg_screen_fill_rect(int32_t x, int32_t y, int32_t width, int32_t height, int32_t color) {
  fill_cells(x, y, width, height, color);
}

/* Reference#exec_inside: the area before is kept, to be given back by rg_screen_inside_ended. */
void rg_screen_inside(int32_t x, int32_t y, int32_t width, int32_t height) {
  if (areas_deep >= AREAS_DEEP) rg_fault("more than %d `inside` blocks are open at once", AREAS_DEEP);
  outer_areas[areas_deep++] = area;
  area = (drawing_area){1, x, y, (int64_t)x + width, (int64_t)y + height};
}

void rg_screen_inside_ended(void) { area = outer_areas[--areas_deep]; }

/* Reference#exec_camera */
void rg_screen_camera(int32_t x, int32_t y) {
  camera_x = x;
  camera_y = y;
}

/* Framebuffer#paged=. Going to two pages, the one drawn so far goes on being drawn into and a
 * blank one is shown, which is what the console does on the way in. Going back to one, the two
 * are the page holding the drawing. */
static void show_pages(int32_t two) {
  if (two == (pixels != viewed)) return;
  if (!two) {
    viewed = pixels;
    return;
  }
  viewed = pixels == first_page ? second_page : first_page;
  for (int32_t i = 0; i < CELLS; i++) viewed[i] = 0;
}

/* The buffer's saved patch, with room made for it the first time it is asked for. */
static int32_t **saved_patch(int32_t buffer) {
  if (buffer >= patches_room) {
    int32_t room = buffer + 1;
    saved_patches = realloc(saved_patches, (size_t)room * sizeof *saved_patches);
    if (!saved_patches) rg_fault("no memory left for the picture saved under a sprite");
    for (int32_t i = patches_room; i < room; i++) saved_patches[i] = NULL;
    patches_room = room;
  }
  return &saved_patches[buffer];
}

/* Reference#exec_save_region: the patch of the picture at (x, y), as it is stored — what is
 * really in the picture, wherever the window sits. A cell that cannot be read (off the screen,
 * or outside the area drawing is held to) is remembered as nothing. */
void rg_region_save(int32_t buffer, int32_t width, int32_t height, int32_t x, int32_t y) {
  int32_t **patch = saved_patch(buffer);
  if (!*patch) *patch = malloc((size_t)width * (size_t)height * sizeof **patch);
  if (!*patch) rg_fault("no memory left for the picture saved under a sprite");
  for (int32_t row = 0; row < height; row++)
    for (int32_t col = 0; col < width; col++) {
      int64_t px = (int64_t)x + col, py = (int64_t)y + row;
      (*patch)[row * width + col] = in_bounds(px, py) ? pixels[py * RG_SCREEN_WIDTH + px] : NO_CELL;
    }
}

/* Reference#exec_restore_region: a patch never saved puts nothing back, and neither does a cell
 * remembered as nothing. */
void rg_region_restore(int32_t buffer, int32_t width, int32_t height, int32_t x, int32_t y) {
  const int32_t *patch = *saved_patch(buffer);
  if (!patch) return;
  for (int32_t row = 0; row < height; row++)
    for (int32_t col = 0; col < width; col++) {
      int32_t color = patch[row * width + col];
      if (color != NO_CELL) set_pixel((int64_t)x + col, (int64_t)y + row, color);
    }
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

static int32_t stack_place(int32_t background) { return background_field(background, RG_BG_STACK_PLACE); }

/* Reference#behind?: only when both named a layer. */
static int32_t behind(int32_t a, int32_t b) {
  return stack_place(a) != RG_NO_LAYER && stack_place(b) != RG_NO_LAYER && stack_place(a) < stack_place(b);
}

/* One more entry on the list of scenery up. */
static void remember_put_up(int32_t background) {
  if (shown_count == shown_room) {
    if (shown_room >= (1 << 28)) rg_fault("scenery has been put up too many times to remember");
    shown_room = shown_room ? shown_room * 2 : RG_MAX_BACKGROUNDS;
    shown_backgrounds = realloc(shown_backgrounds, (size_t)shown_room * sizeof *shown_backgrounds);
    if (!shown_backgrounds) rg_fault("no memory left to remember the scenery that is up");
  }
  shown_backgrounds[shown_count++] = background;
}

/* Whether an entry of the list is among those being put in order: every one, or (+over+ a
 * background) only the ones a named layer puts in front of it. */
static int32_t in_order_asked(int32_t entry, int32_t over) { return over < 0 || behind(over, entry); }

/* Where the LAST entry for +background+ lands once the entries asked for are put in the order the
 * stack asks for (IR::Stacking.order_by_stack), counting from 0 among them, or -1 when it has no
 * entry. An entry that named no layer stays where it is. The ones that did are sorted by how far
 * forward their layers are — two in one layer keeping the order they came in — and handed, in that
 * order, the places the named entries held. */
static int64_t last_place_in_stack_order(int32_t background, int32_t over) {
  int32_t place = stack_place(background);
  int64_t at = -1, last = -1, further_back = 0, in_its_layer = 0, in_its_layer_by_last = 0;
  for (int32_t i = 0; i < shown_count; i++) {
    int32_t entry = shown_backgrounds[i];
    if (!in_order_asked(entry, over)) continue;
    at++;
    if (stack_place(entry) != RG_NO_LAYER && stack_place(entry) < place) further_back++;
    if (stack_place(entry) != RG_NO_LAYER && stack_place(entry) == place) in_its_layer++;
    if (entry == background) {
      last = at;
      in_its_layer_by_last = in_its_layer;
    }
  }
  if (last < 0 || place == RG_NO_LAYER) return last;

  /* It is the named entry number +nth+ in sorted order, so it takes the place of the named entry
   * number +nth+ in the order they went up. */
  int64_t nth = further_back + in_its_layer_by_last - 1, named = -1;
  at = -1;
  for (int32_t i = 0; i < shown_count; i++) {
    int32_t entry = shown_backgrounds[i];
    if (!in_order_asked(entry, over)) continue;
    at++;
    if (stack_place(entry) != RG_NO_LAYER && ++named == nth) return at;
  }
  return -1;
}

/* Reference#in_stack_order over the scenery that is up — all of it, or the part a named layer
 * puts in front of +over+ — with each one stamped in that order.
 *
 * The list can hold a background many times, and stamping one again paints over every stamp of
 * it before. So only where the last entry for each background lands decides the picture, and
 * each is stamped once, in the order of those places. */
static void stamp_in_stack_order(int32_t over) {
  if (over >= 0 && stack_place(over) == RG_NO_LAYER) return;
  int32_t backgrounds = rg_game_picture_sizes[RG_SIZE_BACKGROUNDS];
  int64_t lands[RG_MAX_BACKGROUNDS];
  for (int32_t bg = 0; bg < backgrounds; bg++) lands[bg] = last_place_in_stack_order(bg, over);
  for (;;) {
    int32_t next = -1;
    for (int32_t bg = 0; bg < backgrounds; bg++)
      if (lands[bg] >= 0 && (next < 0 || lands[bg] < lands[next])) next = bg;
    if (next < 0) return;
    rg_background_stamp(next);
    lands[next] = -1;
  }
}

/* Reference#put_up_background. A stamp only covers where it has solid pixels, so a background a
 * named layer puts BEHIND one already up would land in front of it; the ones it belongs behind
 * are stamped again over it. A turned background is painted through its turn at the next rebuild
 * rather than stamped as drawn. */
void rg_background_put_up(int32_t background) {
  remember_put_up(background);
  scenery_kept = 0;
  if (turns[background].turned) {
    request_repaint();
    return;
  }
  rg_background_stamp(background);
  stamp_in_stack_order(background);
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

/* One picture: where its pixels start, and its size. */
typedef struct { const int32_t *pixels; int32_t width, height; } picture;

static picture picture_of(int32_t image) {
  const int32_t *info = rg_game_images + RG_IMAGE_FIELDS * image;
  return (picture){rg_game_image_pixels + info[0], info[1], info[2]};
}

/* Reference#blit_image: a see-through pixel is skipped, and each other one goes on as stored. */
static void blit_image(int32_t image, int32_t x, int32_t y) {
  picture art = picture_of(image);
  for (int32_t row = 0; row < art.height; row++)
    for (int32_t col = 0; col < art.width; col++) {
      int32_t color = art.pixels[row * art.width + col];
      if (color != RG_NOT_DRAWN) set_pixel((int64_t)x + col, (int64_t)y + row, color);
    }
}

static int32_t rebuilt_whole(void) { return rg_game_picture_sizes[RG_SIZE_REBUILT_WHOLE]; }

/* Reference#scene_framebuffer: the backdrop, and every background showing stamped over it. It is
 * a picture of its own, so an area the game's drawing is held to does not hold this. */
static void keep_scenery(void) {
  if (scenery_kept) return;
  drawing_area games = area;
  area.held_in = 0;
  target = scenery;
  clear_to(0);
  for (int32_t bg = 0; bg < rg_game_picture_sizes[RG_SIZE_BACKGROUNDS]; bg++)
    if (showing(bg)) rg_background_stamp(bg);
  target = pixels;
  area = games;
  scenery_kept = 1;
}

/* Reference#exec_blit */
void rg_screen_blit(int32_t image, int32_t x, int32_t y) { blit_image(image, x, y); }

/* Reference#exec_blit_pose: a number outside the set draws nothing. */
void rg_screen_blit_pose(const int32_t *poses, int32_t count, int32_t pose, int32_t x, int32_t y) {
  if (pose >= 0 && pose < count) blit_image(poses[pose], x, y);
}

/* Reference#exec_draw_column_at: one column of a picture, stretched to +height+ rows. The walk
 * goes DOWN THE SCREEN and asks which row of the picture belongs at each screen row, the step
 * held in 65536ths of a picture row and cut off at each step — the console's own rule, so every
 * pixel lands where the other backends put it. Only the rows on the screen are walked. */
void rg_screen_column(int32_t image, int32_t slice, int32_t x, int32_t top, int32_t height, int32_t width) {
  if (height <= 0) return;
  picture art = picture_of(image);
  int64_t column = clamp32(slice, 0, art.width - 1);
  int64_t step = ((int64_t)art.height << 16) / height;
  int64_t first = top < 0 ? -(int64_t)top : 0;
  int64_t past = (int64_t)RG_SCREEN_HEIGHT - top < height ? (int64_t)RG_SCREEN_HEIGHT - top : height;
  for (int64_t row = first; row < past; row++) {
    int64_t source = clamp32((row * step) >> 16, 0, art.height - 1);
    int32_t color = art.pixels[source * art.width + column];
    if (color == RG_NOT_DRAWN) continue;
    for (int32_t across = 0; across < width; across++) set_pixel((int64_t)x + across, top + row, color);
  }
}

/* The start of Reference#exec_present_objects. A game that draws its sprites straight onto the
 * picture has the scenery under them kept from here, as the interpreter does. */
void rg_objects_begin(void) {
  drawing_count = 0;
  if (!rebuilt_whole()) keep_scenery();
}

static void fault_unless_sprite(int32_t sprite) {
  if (sprite < 0 || sprite >= RG_MAX_SPRITES) rg_fault("sprite number %d is not one of the %d there is room for", sprite, RG_MAX_SPRITES);
}

/* Reference#restore_scene_rect and #restore_patch: the scenery put back where this sprite was
 * last drawn. All of a sprite's pictures are one size, so any of them says how big the patch is. */
void rg_object_take_off(int32_t sprite, int32_t image) {
  fault_unless_sprite(sprite);
  drawn_place *place = &last_drawn[sprite];
  if (!place->drawn) return;
  place->drawn = 0;
  picture art = picture_of(image);
  for (int32_t row = 0; row < art.height; row++)
    for (int32_t col = 0; col < art.width; col++) {
      int64_t x = (int64_t)place->x + col, y = (int64_t)place->y + row;
      if (on_screen(x, y)) set_pixel(x, y, scenery[y * RG_SCREEN_WIDTH + x]);
    }
}

void rg_objects_add(int32_t sprite, int32_t image, int32_t x, int32_t y, int32_t level) {
  fault_unless_sprite(sprite);
  if (drawing_count >= RG_MAX_SPRITES) rg_fault("more than %d sprites on screen at once", RG_MAX_SPRITES);
  drawing[drawing_count++] = (placed_object){sprite, image, x, y, level};
}

/* The rest of Reference#exec_present_objects. On a picture that is rebuilt whole, the sprites on
 * screen now are kept (#snapshot_object_layer) and the rebuild is owed. On one that is not, each
 * is drawn where it is now, and where that was is remembered for taking it off again. */
void rg_objects_end(void) {
  if (rebuilt_whole()) {
    for (int32_t i = 0; i < drawing_count; i++) layer[i] = drawing[i];
    layer_count = drawing_count;
    request_repaint();
    return;
  }
  for (int32_t i = 0; i < drawing_count; i++) {
    blit_image(drawing[i].image, drawing[i].x, drawing[i].y);
    last_drawn[drawing[i].sprite] = (drawn_place){1, drawing[i].x, drawing[i].y};
  }
}

/* Reference#collision_sprite: the picture a sprite is showing, read the way the interpreter
 * reads its list — a number below nought counts back from the last, as Ruby's does — and a
 * number that still names none is a fault, where the interpreter stops with an error. */
int32_t rg_pose_image(const int32_t *poses, int32_t count, int32_t pose) {
  int64_t at = pose < 0 ? (int64_t)pose + count : pose;
  if (at < 0 || at >= count) rg_fault("a sprite is showing picture %d of its %d", pose, count);
  return poses[at];
}

/* Reference#solid_pixel? */
static int32_t solid_pixel(picture art, int64_t col, int64_t row) {
  return art.pixels[row * art.width + col] != RG_NOT_DRAWN;
}

/* Reference#pixels_overlap?: only the rectangle where the two boxes overlap is walked. */
int32_t rg_pixels_overlap(int32_t a_image, int32_t a_x, int32_t a_y, int32_t b_image, int32_t b_x, int32_t b_y) {
  picture a = picture_of(a_image), b = picture_of(b_image);
  int64_t left = a_x > b_x ? a_x : b_x, top = a_y > b_y ? a_y : b_y;
  int64_t a_right = (int64_t)a_x + a.width, b_right = (int64_t)b_x + b.width;
  int64_t a_bottom = (int64_t)a_y + a.height, b_bottom = (int64_t)b_y + b.height;
  int64_t right = a_right < b_right ? a_right : b_right, bottom = a_bottom < b_bottom ? a_bottom : b_bottom;
  for (int64_t y = top; y < bottom; y++)
    for (int64_t x = left; x < right; x++)
      if (solid_pixel(a, x - a_x, y - a_y) && solid_pixel(b, x - b_x, y - b_y)) return 1;
  return 0;
}

/* --- the whole view, rebuilt (Reference#repaint_view) --- */

static void repaint_view(void) {
  clear_to(0);
  int32_t backgrounds = rg_game_picture_sizes[RG_SIZE_BACKGROUNDS], levels = rg_game_picture_sizes[RG_SIZE_DEPTHS];
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

/* The top of Reference#advance_frame: a frame boundary is the one safe moment to trade the two
 * pages of a tear-free screen, so the page just drawn is shown and the game is handed the other
 * — before anything can stop the run there, so a run that stops on a boundary stops with the
 * frame it finished on screen. */
void rg_screen_frame_ended(void) {
  if (pixels == viewed) return;
  rg_screen_paint_owed_rebuild();
  uint16_t *finished = pixels;
  pixels = viewed;
  viewed = finished;
  target = pixels;
}

/* Reference#exec_screen. Every kind of screen is a display of its own, so any change of kind
 * wipes the picture and takes the scenery down; arriving on a screen drawn from tiles puts up
 * again what every such screen shows (#put_up_always_up). A change between one page and two
 * keeps the same picture and wipes nothing. */
void rg_screen_set(int32_t new_kind, int32_t two_pages) {
  int32_t crossing = kind >= 0 && kind != new_kind;
  if (crossing) {
    clear_to(0);
    shown_count = 0;
    scenery_kept = 0;
  }
  kind = new_kind;
  show_pages(two_pages);
  if (crossing && new_kind != RG_BITMAP)
    for (int32_t i = 0; i < rg_game_picture_sizes[RG_SIZE_ALWAYS_UP]; i++) rg_background_put_up(rg_game_always_up[i]);
}

/* Reference#cross_to_scene_screen */
void rg_screen_cross_to(int32_t new_kind, int32_t two_pages) {
  if (kind >= 0 && kind != new_kind) rg_screen_set(new_kind, two_pages);
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
  scenery_kept = 0;
  clear_to(0);
  stamp_in_stack_order(-1);
}

/* --- reading it back --- */

int32_t rg_screen_two_pages(void) { return pixels != viewed; }

/* Framebuffer#to_a: the page a viewer is looking at as it is STORED, with no window moved over
 * it and no fade or tint mixed in. */
const uint16_t *rg_screen_stored(void) {
  rg_screen_paint_owed_rebuild();
  return viewed;
}

/* Framebuffer#shown and #pixel: the page a viewer is looking at, read through the window — off
 * the edge of the picture the backdrop shows — with the fade or tint in force mixed in. A
 * switched-off display shows plain white. */
const uint16_t *rg_screen_shown(void) {
  rg_screen_paint_owed_rebuild();
  for (int32_t y = 0; y < RG_SCREEN_HEIGHT; y++)
    for (int32_t x = 0; x < RG_SCREEN_WIDTH; x++) {
      int64_t from_x = (int64_t)x + camera_x, from_y = (int64_t)y + camera_y;
      uint16_t stored = on_screen(from_x, from_y) ? viewed[from_y * RG_SCREEN_WIDTH + from_x] : 0;
      shown[y * RG_SCREEN_WIDTH + x] = held ? (uint16_t)0x7FFF : faded(stored);
    }
  return shown;
}
