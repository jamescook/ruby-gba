/*
 * The game's picture, drawn in software. See rg_screen.h; each function names the interpreter's
 * method it was ported from, in backends/reference.rb or reference/framebuffer.rb, because that
 * is what decides what is right here.
 *
 * What is NOT here is refused when the game is built rather than drawn wrongly (see
 * Picture#refuse_unsupported_picture! and Lowering::NOT_LOWERED_YET, which are the whole list):
 * scenery that is painted from a list; a list of sprite colors that
 * changes as the game runs; and a frame that ends while drawing is held inside an area.
 *
 * A sprite's pictures arrive ready to draw: which of its pixels show, and the colors of each
 * list it can be drawn with, are worked out when the game is built (see native/picture.rb).
 */
#include "rg_screen.h"
#include "rg_runtime.h"

#include <stdlib.h>
#include <string.h>

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
typedef struct { int32_t in_force; int64_t left, top, right, bottom; } drawing_area;
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

/* A FADE PLACED IN THE STACK, while one is in force (Reference @fade_placed): how far forward the
 * layer it sits under is among the layers the game declared, which way it fades, and how far. It
 * cannot be laid over the finished picture as the screen is read, since what is in front of its
 * line has to come through as drawn. So it is painted in as the view is rebuilt. */
typedef struct { int32_t in_force, layer_place, toward_white, steps; } fade_in_the_stack;
static fade_in_the_stack placed_fade;

/* WHAT IS PAINTED FROM HERE ON IS FADED on its way in (Framebuffer @paint_toward), by the placed
 * fade in force. On only while the view is rebuilt, for the things that fade reaches. */
static int32_t fading_what_is_painted;

/* WHAT IS PAINTED FROM HERE ON IS MIXED with what is already in the cell (Framebuffer @through):
 * so many sixteenths of what is painted, so many of what is under it. On only while one thing in
 * a see-through layer is being painted. The picture is painted back to front, so "what is
 * already there" is what the display would find directly behind the layer. */
typedef struct { int32_t painted, under; } shares;
static int32_t mixing;
static shares mixed_by;

/* THE PICTURE WITH NO SPRITES ON IT, kept beside the picture (Framebuffer @scenery) in a game
 * with a sprite in a see-through layer. "Mix with what is already there" is wrong for a sprite
 * over another sprite: a display puts all its sprites into one layer before it mixes anything,
 * so a see-through one is mixed with the scenery or the backdrop under it and never with a
 * sprite behind it. Every paint that is not a sprite's lands here as well as on the picture, and
 * a sprite is mixed with this. One copy, whichever page is being drawn. */
static uint16_t picture_without_sprites[CELLS];
static int32_t painting_sprite; /* what is painted from here on is a sprite's (Framebuffer @painting_sprite) */

/* Scenery up, in the order it went up (Reference @bg_shown): one entry for every time a
 * background is put up, even one already up, exactly as the interpreter keeps it. The repeats
 * matter once layers are named. The order the stack asks for is worked out among the places the
 * entries hold in this list, so a background put up twice holds two of them, and leaving the
 * first out moves every background between the two. */
static int32_t *shown_backgrounds;
static int32_t shown_count, shown_room;

/* WHAT EACH BACKGROUND'S CELLS HOLD NOW (Reference @bg_maps): which of its maps, and the run's
 * own copy of that map's cells, made the first time one of them is changed or another map is
 * handed over. Until then they are the first map's, read where the game declared them. */
typedef struct { int32_t which; int16_t *cells; } background_cells;
static background_cells cells_now[RG_MAX_BACKGROUNDS];

/* Where each background's window sits over its map, in pixels (Reference @bg_scroll): the screen's
 * top left shows the map's (x, y). Nought until the game scrolls it. */
typedef struct { int32_t x, y; } background_scroll;
static background_scroll scrolls[RG_MAX_BACKGROUNDS];

/* Which set of its tiles each background is drawn from now (Reference @bg_colors): 0 for the
 * colors they were drawn in, which is where every background starts and what a number naming no
 * step means, or one more than the step the game last named. */
static int32_t tile_sets_in[RG_MAX_BACKGROUNDS];

/* How a background is turned, once it has been turned or resized at all (Reference @bg_affine). */
typedef struct { int32_t turned, angle, size, pivot_x, pivot_y; } background_turn;
static background_turn turns[RG_MAX_BACKGROUNDS];

/* The sprites on screen this frame: being said (drawing), and as the last rebuild draws them.
 * One that turns or resizes carries its angle and its size for this frame. */
typedef struct { int32_t sprite, image, x, y, level, turned, angle, size; } placed_object;
static placed_object drawing[RG_MAX_SPRITES], sprite_layer[RG_MAX_SPRITES];
static int32_t drawing_count, sprite_layer_count;

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
  return !area.in_force || (x >= area.left && x < area.right && y >= area.top && y < area.bottom);
}

/* Five bits of a color widened to eight by repeating its top bits underneath, so the brightest
 * stays the brightest (Framebuffer#widen_channel). */
static int32_t widened(int32_t channel) { return (channel << 3) | (channel >> 2); }

/* Framebuffer#mix_see_through: a see-through layer's color over what is under it. Each channel
 * is widened to eight bits first, its share of each side added and only then the sixteenth
 * dropped, and the answer taken back to five bits. The two shares need not add to a whole; past
 * one, a channel stops at its brightest. */
static uint16_t mixed_with_under(int32_t color, uint16_t under) {
  int32_t out = 0;
  for (int32_t channel = 0; channel < 3; channel++) {
    int32_t have = widened((color >> (5 * channel)) & 0x1F), below = widened((under >> (5 * channel)) & 0x1F);
    int32_t mix = (have * mixed_by.painted + below * mixed_by.under) / 16;
    out |= ((mix > 255 ? 255 : mix) >> 3) << (5 * channel);
  }
  return (uint16_t)out;
}

static uint16_t blend(uint16_t color, int32_t white, int32_t steps, int32_t out_of);

/* Framebuffer#apply_placed_fade: a color as it is painted while a placed fade reaches it. */
static uint16_t faded_as_painted(int32_t color) {
  if (!fading_what_is_painted) return (uint16_t)color;
  return blend((uint16_t)color, placed_fade.toward_white, placed_fade.steps, 16);
}

/* Framebuffer#blend_into_cell: a color on its way into a cell holding +under+. The fade a placed
 * fade asks for first, then the mix a see-through layer asks for. */
static uint16_t into_cell(int32_t color, uint16_t under) {
  uint16_t painted = faded_as_painted(color);
  return mixing ? mixed_with_under(painted, under) : painted;
}

/* Reference#see_through_sprites?: is any sprite in a see-through layer? Asked for every pixel
 * painted, and the answer is the game's and never changes, so it is worked out once. */
static int32_t sprites_seen_through(void) {
  static int32_t answer = -1;
  if (answer >= 0) return answer;
  answer = 0;
  for (int32_t layer = 0; layer < rg_game_picture_sizes[RG_SIZE_SEE_THROUGH]; layer++)
    if (rg_game_see_through[layer * RG_ST_FIELDS + RG_ST_HOLDS_A_SPRITE]) answer = 1;
  return answer;
}

/* Whether the picture with no sprites on it is kept beside what is being drawn into
 * (Framebuffer#keep_scenery). The copy of the scenery kept to put back under sprites is a picture
 * of its own, which keeps none. */
static int32_t keeps_picture_without_sprites(void) { return target != scenery && sprites_seen_through(); }

/* Framebuffer#set_pixel: a cell drawing may not land on is dropped. A sprite is mixed with the
 * picture as it is with no sprite on it, where that is kept, and anything else with what is
 * already in the cell. */
static void set_pixel(int64_t x, int64_t y, int32_t color) {
  if (!in_bounds(x, y)) return;
  int64_t at = y * RG_SCREEN_WIDTH + x;
  int32_t kept = keeps_picture_without_sprites();
  const uint16_t *under = kept && painting_sprite ? picture_without_sprites : target;
  uint16_t painted = into_cell(color, under[at]);
  target[at] = painted;
  if (kept && !painting_sprite) picture_without_sprites[at] = painted;
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
  if (area.in_force) {
    fill_cells(area.left, area.top, area.right - area.left, area.bottom - area.top, color);
    return;
  }
  uint16_t painted = faded_as_painted(color);
  for (int32_t i = 0; i < CELLS; i++) target[i] = painted;
  if (!keeps_picture_without_sprites()) return;
  for (int32_t i = 0; i < CELLS; i++) picture_without_sprites[i] = painted;
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

/* A frame never ends between the two: the build refuses a game where one could, because the
 * interpreter reads the screen through the area then (Framebuffer#pixel) and gives the area back
 * if the run stops there, and neither is done here. */
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
void rg_patch_save(int32_t buffer, int32_t width, int32_t height, int32_t x, int32_t y) {
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
void rg_patch_restore(int32_t buffer, int32_t width, int32_t height, int32_t x, int32_t y) {
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

/* --- see-through layers --- */

static int32_t showing(int32_t background);
static void request_repaint(void);
static void repaint_view(void);

static int32_t see_through_layers(void) { return rg_game_picture_sizes[RG_SIZE_SEE_THROUGH]; }

static int32_t see_through_field(int32_t layer, int32_t field) {
  return rg_game_see_through[layer * RG_ST_FIELDS + field];
}

/* The layer the game is being asked about, when it is being asked, and the two amounts it
 * answered with. */
enum { NOBODY_ASKED = -1 };
static int32_t asked_layer = NOBODY_ASKED;
static struct { int32_t shows, behind; } answered;

int32_t rg_see_through_asked(int32_t layer) { return layer == asked_layer; }

void rg_see_through_answer(int32_t shows, int32_t behind) {
  answered.shows = shows;
  answered.behind = behind;
}

/* IR::SeeThrough.nearest_steps and .floor_steps: an amount out of 100 as sixteenths. */
static int32_t nearest_sixteenths(int32_t amount) { return clamp32(floor_div((int64_t)amount * 16 + 50, 100), 0, 16); }
static int32_t whole_sixteenths(int32_t amount) { return clamp32(floor_div((int64_t)amount * 16, 100), 0, 16); }

/* Reference#live_see_through_weights, through IR::SeeThrough.weights: a layer's two shares from
 * its amounts as the game works them out now. Given one amount, what is behind takes its share
 * rounded down and the layer whatever is left of a whole; given two, each is taken to the
 * nearest sixteenth. */
static shares shares_now(int32_t layer) {
  asked_layer = layer;
  rg_game_see_through_amounts();
  asked_layer = NOBODY_ASKED;
  if (see_through_field(layer, RG_ST_ONE_AMOUNT)) {
    int32_t under = whole_sixteenths(answered.behind);
    return (shares){16 - under, under};
  }
  return (shares){nearest_sixteenths(answered.shows), nearest_sixteenths(answered.behind)};
}

/* A layer's shares as they were at some moment, for the layers they were kept for: when the
 * rebuild now owed was asked for (Reference @owed_weights), and when the game last said it had
 * worked the amounts out again (@see_through_shown). */
typedef struct { int32_t kept; shares at; } kept_shares;
static kept_shares owed_shares[RG_MAX_SEE_THROUGH], told_shares[RG_MAX_SEE_THROUGH];

/* Reference#layer_has_anything?: a background showing now, or a sprite anywhere, since whether
 * a sprite is shown is a variable too. */
static int32_t layer_holds_anything(int32_t layer) {
  if (see_through_field(layer, RG_ST_HOLDS_A_SPRITE)) return 1;
  for (int32_t bg = 0; bg < rg_game_picture_sizes[RG_SIZE_BACKGROUNDS]; bg++)
    if (showing(bg) && background_field(bg, RG_BG_SEE_THROUGH) == layer) return 1;
  return 0;
}

/* Reference#capture_see_through_weights. A rebuild is painted later than it is asked for, and
 * the game's variables can move in between, so the amounts a game works out are read when the
 * rebuild is asked for and the painting uses those. Only for a layer with something in it that
 * could be on screen: the others are never painted, and nothing is worked out that painting
 * would not have worked out. */
static void keep_shares_for_owed_rebuild(void) {
  for (int32_t layer = 0; layer < see_through_layers(); layer++) {
    owed_shares[layer].kept = !see_through_field(layer, RG_ST_AMOUNTS_WRITTEN) && layer_holds_anything(layer);
    if (owed_shares[layer].kept) owed_shares[layer].at = shares_now(layer);
  }
}

static void forget_kept_shares(void) {
  for (int32_t layer = 0; layer < see_through_layers(); layer++) owed_shares[layer].kept = 0;
}

/* Reference#fading?: is a fade in force that takes the display's blend? The display blends two
 * layers together or moves the whole picture toward a color, one or the other, so while such a
 * fade runs a see-through layer is solid. A fade that walks the colors sets no fade amount and
 * is never found here. The copy of the scenery kept to put back under sprites is a picture of
 * its own, which no fade was ever set on, so painting into it never finds one either.
 *
 * A fade placed in the stack is the game's and not either picture's, and takes the blend
 * whichever is being painted. */
static int32_t fade_takes_the_blend(void) {
  if (placed_fade.in_force) return placed_fade.steps > 0;
  return target != scenery && fade_steps > 0;
}

/* Reference#set_see_through_for, for scenery: mixing on for a thing in a see-through layer, off
 * for anything else. +layer+ is RG_SOLID for a thing in none. */
static void mix_as_layer(int32_t layer) {
  painting_sprite = 0;
  mixing = layer != RG_SOLID && !fade_takes_the_blend();
  if (mixing) mixed_by = owed_shares[layer].kept ? owed_shares[layer].at : shares_now(layer);
}

/* Reference#set_see_through_for, for a sprite: the same, and what is painted is a sprite's, so
 * it is mixed with the picture as it is with no sprite on it and stays off that picture. */
static void mix_as_sprite(int32_t sprite) {
  mix_as_layer(rg_game_sprite_see_through[sprite]);
  painting_sprite = 1;
}

static void mix_nothing(void) {
  mixing = 0;
  painting_sprite = 0;
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

/* Reference#exec_fade, through Framebuffer#fade_steps_to or, for a fade that walks the colors,
 * #tint_steps_to. +placed+ is 1 for a fade placed in the stack under the layer at +layer_place+.
 *
 * Over the whole screen it is laid over the picture as the screen is read, so nothing drawn
 * changes. Placed in the stack it is painted into the picture, so the picture is built again
 * right here, and again by the fade that takes a placed one's place, which has to take it back
 * out.
 *
 * A fade that takes the display's blend takes it from a see-through layer and hands it back as
 * it lifts, so the picture is built again at each of those two moments as well: the layer is
 * solid on one side of them and see-through on the other. */
static void fade_to(int32_t placed, int32_t layer_place, int32_t toward_white, int32_t steps, int32_t walked) {
  int32_t took_the_blend = fade_takes_the_blend(), was_placed = placed_fade.in_force;
  placed_fade = (fade_in_the_stack){.in_force = placed, .layer_place = layer_place, .toward_white = toward_white, .steps = steps};
  if (walked) {
    tint_mode = TINT_TOWARD;
    tint_white = toward_white;
    tint_steps = steps;
    fade_steps = 0;
  } else {
    fade_white = toward_white;
    fade_steps = placed ? 0 : steps;
    tint_mode = TINT_NONE;
  }
  int32_t blend_changed_hands = see_through_layers() > 0 && fade_takes_the_blend() != took_the_blend;
  if (was_placed || placed || blend_changed_hands) request_repaint();
}

void rg_screen_fade(int32_t toward_white, int32_t steps, int32_t walked) {
  fade_to(0, RG_NO_LAYER, toward_white, steps, walked);
}

void rg_screen_fade_under(int32_t layer_place, int32_t toward_white, int32_t steps, int32_t walked) {
  fade_to(1, layer_place, toward_white, steps, walked);
}

/* Reference#exec_tint, through Framebuffer#tint_steps_to. A tint takes the place of whatever
 * fade was in force, one placed in the stack included. A fade that goes may have been holding a
 * see-through layer solid, or have been painted into the picture, so the picture is built again
 * when one does. */
void rg_screen_tint(int32_t color, int32_t steps) {
  int32_t took_the_blend = fade_takes_the_blend(), was_placed = placed_fade.in_force;
  placed_fade.in_force = 0;
  tint_mode = TINT_COLOR;
  tint_color = color;
  tint_steps = steps;
  fade_steps = 0;
  int32_t blend_changed_hands = see_through_layers() > 0 && fade_takes_the_blend() != took_the_blend;
  if (was_placed || blend_changed_hands) request_repaint();
}

/* Backends::FadeSteps.steps */
int32_t rg_fade_steps(int32_t amount, int32_t fraction_bits, int32_t walked) {
  int32_t levels = walked ? 32 : 16;
  if (fraction_bits < 0) {
    int32_t sixteenths = whole_sixteenths(amount);
    return walked ? sixteenths * 2 : sixteenths;
  }
  return clamp32(floor_div((int64_t)amount * levels, (int64_t)100 << fraction_bits), 0, levels);
}

/* --- scenery --- */

/* The map a background's cells hold now, as its entry of rg_game_maps. */
static const int32_t *map_now(int32_t background) {
  return rg_game_maps + RG_MAP_FIELDS * (background_field(background, RG_BG_FIRST_MAP) + cells_now[background].which);
}

static int32_t map_cols(int32_t background) { return map_now(background)[RG_MAP_COLS]; }
static int32_t map_rows(int32_t background) { return map_now(background)[RG_MAP_ROWS]; }

static int32_t in_map(int32_t background, int64_t row, int64_t col) {
  return row >= 0 && row < map_rows(background) && col >= 0 && col < map_cols(background);
}

/* Where a cell of the map is among its cells, which are kept row after row. */
static int64_t cell_place(int32_t background, int64_t row, int64_t col) { return row * map_cols(background) + col; }

/* Reference#map_of: what a cell holds NOW, in the run's own copy where there is one. Below nought
 * where it holds no tile. */
static int32_t map_cell(int32_t background, int64_t row, int64_t col) {
  if (!in_map(background, row, col)) return RG_CELL_EMPTY;
  const int16_t *own = cells_now[background].cells;
  const int16_t *cells = own ? own : rg_game_map_cells + map_now(background)[RG_MAP_CELLS];
  return cells[cell_place(background, row, col)];
}

/* The background's cells become the run's own copy of map number +which+ of its maps, as that
 * map was declared (Reference#mutable_map, and the copy in #exec_show_map). */
static void copy_map(int32_t background, int32_t which) {
  free(cells_now[background].cells);
  cells_now[background] = (background_cells){which, NULL};
  size_t count = (size_t)map_cols(background) * (size_t)map_rows(background);
  int16_t *copy = malloc((count ? count : 1) * sizeof *copy);
  if (!copy) rg_fault("no memory left for a background's own copy of its map");
  memcpy(copy, rg_game_map_cells + map_now(background)[RG_MAP_CELLS], count * sizeof *copy);
  cells_now[background].cells = copy;
}

/* The cells are the first map again, as declared (Reference's @bg_maps.delete). */
static void forget_own_cells(int32_t background) {
  free(cells_now[background].cells);
  cells_now[background] = (background_cells){0, NULL};
}

/* One pixel of a cell's tile, or RG_SEE_THROUGH (Reference#background_pixel), in the colors the
 * background is drawn with now (Reference#tile_colors): its tiles as drawn with each step come
 * one whole set after another. */
static uint16_t tile_pixel(int32_t background, int32_t cell, int64_t tx, int64_t ty) {
  int32_t tile_w = background_field(background, RG_BG_TILE_W), tile_h = background_field(background, RG_BG_TILE_H);
  int64_t tile = (int64_t)tile_sets_in[background] * background_field(background, RG_BG_TILES) + cell;
  int64_t at = background_field(background, RG_BG_TILES_START) + tile * tile_w * tile_h + ty * tile_w + tx;
  return rg_game_tile_pixels[at];
}

/* Reference#stamp_background: the whole map onto the picture, cell by cell. */
void rg_background_stamp(int32_t background) {
  int32_t tile_w = background_field(background, RG_BG_TILE_W), tile_h = background_field(background, RG_BG_TILE_H);
  mix_as_layer(background_field(background, RG_BG_SEE_THROUGH));
  for (int32_t row = 0; row < map_rows(background); row++) {
    for (int32_t col = 0; col < map_cols(background); col++) {
      int32_t cell = map_cell(background, row, col);
      if (cell < 0) continue;
      for (int32_t ty = 0; ty < tile_h; ty++)
        for (int32_t tx = 0; tx < tile_w; tx++) {
          uint16_t color = tile_pixel(background, cell, tx, ty);
          if (color != RG_SEE_THROUGH) set_pixel((int64_t)col * tile_w + tx, (int64_t)row * tile_h + ty, color);
        }
    }
  }
  mix_nothing();
}

static int32_t bent_background_showing(void) {
  for (int32_t bg = 0; bg < rg_game_picture_sizes[RG_SIZE_BACKGROUNDS]; bg++)
    if (showing(bg) && background_field(bg, RG_BG_BENT)) return 1;
  return 0;
}

/* Reference#request_repaint: a rebuild of the whole view is owed, and painted when something
 * needs the picture. With a bent background showing it is painted now instead. Painting one runs
 * the game's own block line by line, which reads the game's variables and may change them, so
 * putting it off would change the game.
 *
 * A painted screen is never built again, in a game that also has screens drawn from tiles. Its
 * picture is whatever the game painted there, and building the view from scenery would wipe it.
 * What asks while one is up is the machinery of the game's other screens, which runs every frame
 * whichever is showing. */
static void request_repaint(void) {
  if (kind == RG_BITMAP && rg_game_picture_sizes[RG_SIZE_SCREEN_KINDS_CHANGE]) return;
  if (bent_background_showing()) {
    repaint_view();
    return;
  }
  owed = 1;
  keep_shares_for_owed_rebuild();
}

/* Reference#exec_scroll_rows and #repaint_bent_backgrounds: both only ask. */
void rg_screen_request_rebuild(void) { request_repaint(); }

/* Reference#exec_see_through: the amounts have been worked out again for the frame about to be
 * drawn. The painting reads them itself; what this owes is the picture, since one that neither
 * moves nor scrolls would otherwise keep the amounts it was painted with.
 *
 * A game that says this is one whose whole view is rebuilt (Picture#see_through_picture_changes?),
 * so its sprites are kept for the rebuild rather than drawn once onto a picture that stays. */
void rg_see_through_told(int32_t layer) {
  shares now = shares_now(layer);
  kept_shares *told = &told_shares[layer];
  if (told->kept && told->at.painted == now.painted && told->at.under == now.under) return;
  *told = (kept_shares){1, now};
  request_repaint();
}

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
  if (background_field(background, RG_BG_ON_ARRIVAL)) forget_own_cells(background);
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

/* Reference#exec_scroll_background */
void rg_background_scroll(int32_t background, int32_t x, int32_t y) {
  scrolls[background] = (background_scroll){x, y};
  request_repaint();
}

/* Reference#exec_set_tile: the copy is made even when the cell turns out not to be there. */
void rg_background_set_tile(int32_t background, int32_t col, int32_t row, int32_t tile) {
  if (!cells_now[background].cells) copy_map(background, 0);
  if (!in_map(background, row, col)) return;
  int16_t *cell = &cells_now[background].cells[cell_place(background, row, col)];
  if (*cell == tile) return;
  *cell = (int16_t)tile;
  request_repaint();
}

/* Reference#exec_show_map */
void rg_background_show_map(int32_t background, int32_t which) {
  if (which < 0 || which >= background_field(background, RG_BG_SHOWABLE_MAPS)) return;
  copy_map(background, which);
  request_repaint();
}

/* Reference#exec_background_colors: nothing about the map or the pictures changes, and the next
 * rebuild reads the tiles in the colors named. The interpreter keeps the number and works out
 * what it names as it paints; which step a number names never changes, so it is worked out here. */
void rg_background_draw_with(int32_t background, int32_t which) {
  tile_sets_in[background] = rg_place_of_choice(which, background_field(background, RG_BG_COLOR_STEPS));
  request_repaint();
}

/* The map's pixel at (mx, my), neither below nought, put on the picture at (px, py). Where the
 * map has no cell or no tile, or the tile is see-through, what is behind stays. */
static void paint_map_pixel(int32_t background, int64_t mx, int64_t my, int64_t px, int64_t py) {
  int32_t tile_w = background_field(background, RG_BG_TILE_W), tile_h = background_field(background, RG_BG_TILE_H);
  int32_t cell = map_cell(background, my / tile_h, mx / tile_w);
  if (cell < 0) return;
  uint16_t color = tile_pixel(background, cell, mx % tile_w, my % tile_h);
  if (color == RG_SEE_THROUGH) return;
  uint16_t *into = &pixels[py * RG_SCREEN_WIDTH + px];
  *into = into_cell(color, *into);
  if (sprites_seen_through()) picture_without_sprites[py * RG_SCREEN_WIDTH + px] = *into;
}

/* The background and the line of the screen the game is being asked about, when it is being
 * asked, and how far across it answered. */
static struct { int32_t background, py, offset; } asked_bend = {NOBODY_ASKED, 0, 0};

int32_t rg_bend_asked(int32_t background) { return background == asked_bend.background; }
int32_t rg_bend_line(void) { return asked_bend.py; }
void rg_bend_answer(int32_t offset) { asked_bend.offset = offset; }

/* Reference#row_bend_offset: how far across line +py+ of the screen a background sits, on top of
 * its scroll. Nought for a background the game does not bend. */
static int64_t bend_at(int32_t background, int64_t py) {
  if (!background_field(background, RG_BG_BENT)) return 0;
  asked_bend.background = background;
  asked_bend.py = (int32_t)py;
  rg_game_bend_offsets();
  asked_bend.background = NOBODY_ASKED;
  return asked_bend.offset;
}

/* Reference#paint_streamed_background_window: a background with a map too big for any grid, or
 * with maps of different sizes, does not come round again. Past any edge of the map it is
 * showing there are no cells: left of it, above it and below it by the tests here, right of it
 * because the map has no such cell to read. A bent one is asked only about the rows its map
 * reaches. */
static void paint_window_without_wrapping(int32_t background) {
  int64_t map_h = (int64_t)map_rows(background) * background_field(background, RG_BG_TILE_H);
  for (int64_t py = 0; py < RG_SCREEN_HEIGHT; py++) {
    int64_t my = (int64_t)scrolls[background].y + py;
    if (my < 0 || my >= map_h) continue;
    int64_t off_x = (int64_t)scrolls[background].x + bend_at(background, py);
    for (int64_t px = 0; px < RG_SCREEN_WIDTH; px++) {
      int64_t mx = off_x + px;
      if (mx >= 0) paint_map_pixel(background, mx, my, px, py);
    }
  }
}

/* Reference#paint_background_window, for a background never turned: the window sits where the
 * background is scrolled to, the map wraps over the console's whole grid, and a row or cell past
 * the map shows what is behind. */
static void paint_window(int32_t background) {
  if (background_field(background, RG_BG_NEVER_WRAPS)) {
    paint_window_without_wrapping(background);
    return;
  }
  int64_t map_w = (int64_t)background_field(background, RG_BG_GRID_COLS) * background_field(background, RG_BG_TILE_W);
  int64_t map_h = (int64_t)background_field(background, RG_BG_GRID_ROWS) * background_field(background, RG_BG_TILE_H);
  if (map_w == 0 || map_h == 0) return;
  int64_t off_y = floor_mod(scrolls[background].y, map_h);
  for (int64_t py = 0; py < RG_SCREEN_HEIGHT; py++) {
    int64_t off_x = floor_mod((int64_t)scrolls[background].x + bend_at(background, py), map_w);
    for (int64_t px = 0; px < RG_SCREEN_WIDTH; px++)
      paint_map_pixel(background, (off_x + px) % map_w, (off_y + py) % map_h, px, py);
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
 * to the map pixel that lands there, from wherever the background is scrolled to. */
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
      int64_t mx = floor_mod(scrolls[background].x + pivot_x + floor_div(turn_cos * dx + turn_sin * dy, one_th), map_w);
      int64_t my = floor_mod(scrolls[background].y + pivot_y + floor_div(-turn_sin * dx + turn_cos * dy, one_th), map_h);
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

/* Reference#blit_image_transformed: a picture turned +angle+ degrees clockwise and drawn at
 * +size+, about its own middle, its top left as drawn at (x, y).
 *
 * The console does not turn the picture and stamp it down. It walks the patch of screen the
 * sprite can cover and, for each pixel of it, works BACK through the turn to the pixel of the
 * picture that lands there; one that falls outside the picture is not drawn. The patch is twice
 * the picture each way, centered on it, so a corner swung out by the turn has room, and a
 * picture grown past twice its size is cut off at that box. A screen pixel is taken at its whole
 * coordinate and the answer rounded down, which is what puts every edge pixel where the other
 * backends put it. */
static void blit_image_turned(int32_t image, int32_t x, int32_t y, int32_t angle, int32_t size) {
  picture art = picture_of(image);
  int64_t width = art.width, height = art.height, one_th = rg_game_turn_rules[1];
  int64_t turn_cos, turn_sin;
  affine_matrix((int32_t)floor_mod(angle, 360), size, &turn_cos, &turn_sin);
  int64_t left = (int64_t)x - width / 2, top = (int64_t)y - height / 2;
  for (int64_t iy = 0; iy < height * 2; iy++) {
    int64_t dy = iy - height;
    for (int64_t ix = 0; ix < width * 2; ix++) {
      int64_t dx = ix - width;
      int64_t from_x = floor_div(turn_cos * dx + turn_sin * dy, one_th) + width / 2;
      int64_t from_y = floor_div(-turn_sin * dx + turn_cos * dy, one_th) + height / 2;
      if (from_x < 0 || from_x >= width || from_y < 0 || from_y >= height) continue;
      int32_t color = art.pixels[from_y * width + from_x];
      if (color != RG_NOT_DRAWN) set_pixel(left + ix, top + iy, color);
    }
  }
}

/* Reference#draw_object and #paint_snapshot_object */
static void draw_placed(const placed_object *placed) {
  if (placed->turned) blit_image_turned(placed->image, placed->x, placed->y, placed->angle, placed->size);
  else blit_image(placed->image, placed->x, placed->y);
}

static int32_t rebuilt_whole(void) { return rg_game_picture_sizes[RG_SIZE_REBUILT_WHOLE]; }

/* Reference#scene_framebuffer: the backdrop, and every background showing stamped over it. It is
 * a picture of its own, so an area the game's drawing is held to does not hold this. */
static void keep_scenery(void) {
  if (scenery_kept) return;
  drawing_area outer = area;
  area.in_force = 0;
  target = scenery;
  clear_to(0);
  for (int32_t bg = 0; bg < rg_game_picture_sizes[RG_SIZE_BACKGROUNDS]; bg++)
    if (showing(bg)) rg_background_stamp(bg);
  target = pixels;
  area = outer;
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

/* Reference#restore_patch: the scenery put back over a patch of the picture. */
static void restore_patch(int64_t left, int64_t top, int64_t width, int64_t height) {
  for (int64_t row = 0; row < height; row++)
    for (int64_t col = 0; col < width; col++) {
      int64_t x = left + col, y = top + row;
      if (on_screen(x, y)) set_pixel(x, y, scenery[y * RG_SCREEN_WIDTH + x]);
    }
}

/* Forgets where a sprite was last drawn straight onto the picture, and hands that place over for
 * the scenery to be put back there; NULL when it is not on the picture. */
static const drawn_place *forget_drawn_place(int32_t sprite) {
  fault_unless_sprite(sprite);
  drawn_place *place = &last_drawn[sprite];
  if (!place->drawn) return NULL;
  place->drawn = 0;
  return place;
}

/* Reference#restore_scene_rect: the scenery put back where this sprite was last drawn. All of a
 * sprite's pictures are one size, so any of them says how big the patch is. */
void rg_object_take_off(int32_t sprite, int32_t image) {
  const drawn_place *place = forget_drawn_place(sprite);
  if (!place) return;
  picture art = picture_of(image);
  restore_patch(place->x, place->y, art.width, art.height);
}

/* The whole number whose square is the largest not over +value+ (Ruby's Integer.sqrt). */
static int64_t whole_root(int64_t value) {
  int64_t root = 0;
  while ((root + 1) * (root + 1) <= value) root++;
  return root;
}

/* Reference#restore_scene_rect and #transformed_footprint, for a sprite that turns or resizes.
 * The patch has to hold the picture at whatever angle and size it was last drawn, since the
 * putting back cannot depend on knowing which. One that only turns reaches no further from its
 * middle than half its own diagonal, so a square that wide does; one that +resizes+ has no bound
 * short of the whole box the display gives it, twice the picture each way. */
void rg_object_take_off_turned(int32_t sprite, int32_t image, int32_t resizes) {
  const drawn_place *place = forget_drawn_place(sprite);
  if (!place) return;
  picture art = picture_of(image);
  int64_t width = art.width, height = art.height;
  int64_t middle_x = (int64_t)place->x + width / 2, middle_y = (int64_t)place->y + height / 2;
  if (resizes) {
    restore_patch(middle_x - width, middle_y - height, width * 2, height * 2);
    return;
  }
  int64_t side = whole_root(width * width + height * height) + 2;
  restore_patch(middle_x - side / 2, middle_y - side / 2, side, side);
}

/* One more sprite on screen this frame. */
static void add_placed(placed_object placed) {
  fault_unless_sprite(placed.sprite);
  if (drawing_count >= RG_MAX_SPRITES) rg_fault("more than %d sprites on screen at once", RG_MAX_SPRITES);
  drawing[drawing_count++] = placed;
}

void rg_objects_add(int32_t sprite, int32_t image, int32_t x, int32_t y, int32_t level) {
  add_placed((placed_object){.sprite = sprite, .image = image, .x = x, .y = y, .level = level});
}

void rg_objects_add_turned(int32_t sprite, int32_t image, int32_t x, int32_t y, int32_t level, int32_t angle,
                           int32_t size) {
  add_placed((placed_object){.sprite = sprite, .image = image, .x = x, .y = y, .level = level,
                             .turned = 1, .angle = angle, .size = size});
}

/* The rest of Reference#exec_present_objects. On a picture that is rebuilt whole, the sprites on
 * screen now are kept (#snapshot_object_layer) and the rebuild is owed. On one that is not, each
 * is drawn where it is now, and where that was is remembered for taking it off again. */
void rg_objects_end(void) {
  if (rebuilt_whole()) {
    for (int32_t i = 0; i < drawing_count; i++) sprite_layer[i] = drawing[i];
    sprite_layer_count = drawing_count;
    request_repaint();
    return;
  }
  for (int32_t i = 0; i < drawing_count; i++) {
    mix_as_sprite(drawing[i].sprite);
    draw_placed(&drawing[i]);
    mix_nothing();
    last_drawn[drawing[i].sprite] = (drawn_place){1, drawing[i].x, drawing[i].y};
  }
}

/* Which of a row of +count+ things the number +said+ names, read the way the interpreter reads
 * a Ruby array: a number below nought counts back from the last. NO_PLACE when it still names
 * none, which is where the interpreter stops with an error. */
enum { NO_PLACE = -1 };
static int64_t place_named(int32_t said, int32_t count) {
  int64_t place = said < 0 ? (int64_t)said + count : said;
  return place >= 0 && place < count ? place : NO_PLACE;
}

/* Reference#names_in_draw_order: the sprite of a run that the order list names next. */
int32_t rg_place_in_ordered_run(int32_t said, int32_t count) {
  int64_t place = place_named(said, count);
  if (place == NO_PLACE) rg_fault("a draw order names sprite %d of the %d it puts in order", said, count);
  return (int32_t)place;
}

/* Reference#collision_sprite: the picture a sprite is showing. */
int32_t rg_pose_image(const int32_t *poses, int32_t count, int32_t pose) {
  int64_t place = place_named(pose, count);
  if (place == NO_PLACE) rg_fault("a sprite is showing picture %d of its %d", pose, count);
  return poses[place];
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

/* The fade half of Reference#set_blend_for, for the thing about to be painted: the placed fade
 * in force reaches it unless that fade's layer is no further forward than +fade_place+, which is
 * the furthest forward such a layer can be and still leave the thing as drawn (RG_BG_FADE_PLACE).
 * That is RG_NO_LAYER for a thing every placed fade reaches, and for the backdrop, which is
 * behind everything. A fade under a layer the game never declared reaches everything. */
static void fade_unless_left_as_drawn(int32_t fade_place) {
  int32_t under = placed_fade.layer_place;
  int32_t left_as_drawn = under != RG_NO_LAYER && fade_place != RG_NO_LAYER && fade_place >= under;
  fading_what_is_painted = placed_fade.in_force && !left_as_drawn;
}

static void fade_nothing(void) { fading_what_is_painted = 0; }

static void repaint_view(void) {
  mix_nothing();
  fade_unless_left_as_drawn(RG_NO_LAYER);
  clear_to(0);
  int32_t backgrounds = rg_game_picture_sizes[RG_SIZE_BACKGROUNDS], levels = rg_game_picture_sizes[RG_SIZE_DEPTHS];
  for (int32_t level = 0; level < levels; level++) {
    for (int32_t bg = 0; bg < backgrounds; bg++) {
      if (!showing(bg) || background_field(bg, RG_BG_LEVEL) != level) continue;
      mix_as_layer(background_field(bg, RG_BG_SEE_THROUGH));
      fade_unless_left_as_drawn(background_field(bg, RG_BG_FADE_PLACE));
      if (turns[bg].turned) paint_turned_window(bg);
      else paint_window(bg);
    }
    for (int32_t i = 0; i < sprite_layer_count; i++) {
      if (sprite_layer[i].level != level) continue;
      mix_as_sprite(sprite_layer[i].sprite);
      fade_unless_left_as_drawn(rg_game_sprite_fade_places[sprite_layer[i].sprite]);
      draw_placed(&sprite_layer[i]);
    }
  }
  mix_nothing();
  fade_nothing();
}

/* Reference#paint_owed_repaint */
void rg_screen_paint_owed_rebuild(void) {
  if (!owed) return;
  owed = 0;
  repaint_view();
  forget_kept_shares();
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
 * again what every such screen shows, as declared (#put_up_always_up), and says so. A change
 * between one page and two keeps the same picture and wipes nothing. */
int32_t rg_screen_set(int32_t new_kind, int32_t two_pages) {
  int32_t crossing = kind >= 0 && kind != new_kind;
  if (crossing) {
    clear_to(0);
    shown_count = 0;
    scenery_kept = 0;
  }
  kind = new_kind;
  show_pages(two_pages);
  if (!crossing || new_kind == RG_BITMAP) return 0;
  for (int32_t i = 0; i < rg_game_picture_sizes[RG_SIZE_ALWAYS_UP]; i++) {
    forget_own_cells(rg_game_always_up[i]);
    rg_background_put_up(rg_game_always_up[i]);
  }
  return 1;
}

/* Reference#cross_to_scene_screen */
int32_t rg_screen_cross_to(int32_t new_kind, int32_t two_pages) {
  return kind >= 0 && kind != new_kind ? rg_screen_set(new_kind, two_pages) : 0;
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
