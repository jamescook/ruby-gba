/*
 * The game's picture, drawn in software: the console's 240x160 screen as an array of colors, and
 * everything the game does to it. A port of the native runtime's rg_screen.c, function for
 * function, which is itself a port of the interpreter's picture (backends/reference.rb and
 * reference/framebuffer.rb) — each function names the interpreter's method it follows, because
 * that is what decides what is right here. See rg_screen.h for the layout of every array the
 * lowering writes (rg_game_backgrounds, rg_game_images, ...); this file reads them the same way.
 *
 * A color is the console's: fifteen bits, five each of red, green and blue, red lowest.
 *
 * Numbers here are positions and colors, never a game's own arithmetic, so they are plain
 * JavaScript numbers: a float holds every whole number this can reach exactly. Where C divides
 * whole numbers it truncates toward nought, and so does Math.trunc here; floor_div and floor_mod
 * round down, as Ruby's / and % do.
 */

const RG_SCREEN_WIDTH = 240;
const RG_SCREEN_HEIGHT = 160;
const RG_CELLS = RG_SCREEN_WIDTH * RG_SCREEN_HEIGHT;

const RG_BITMAP = 0, RG_TILED = 1, RG_ROTOZOOM = 2;

const RG_NOT_DRAWN = -1;
const RG_IMAGE_FIELDS = 3;
const RG_MAX_SPRITES = 512;
const RG_SOLID = -1;
const RG_NO_NAME = -1;
const RG_NOT_IN_BLOCKS = -1;
const RG_ST_AMOUNTS_WRITTEN = 0, RG_ST_ONE_AMOUNT = 1, RG_ST_HOLDS_A_SPRITE = 2, RG_ST_FIELDS = 3;
const RG_MAX_SEE_THROUGH = 16;
const RG_SEE_THROUGH = 0xFFFF;
const RG_EVERY_SCENE = -1;
const RG_NEVER_ARRIVES = -2;
const RG_NO_LAYER = -1;
const RG_MAX_BACKGROUNDS = 64;
const RG_BG_TILE_W = 0, RG_BG_TILE_H = 1, RG_BG_FIRST_MAP = 2, RG_BG_SHOWABLE_MAPS = 3, RG_BG_KEPT_BY = 4,
  RG_BG_NEVER_WRAPS = 5, RG_BG_TILES_START = 6, RG_BG_SCENE = 7, RG_BG_LEVEL = 8, RG_BG_ON_ARRIVAL = 9,
  RG_BG_STACK_PLACE = 10, RG_BG_SEE_THROUGH = 11, RG_BG_BENT = 12, RG_BG_FADE_PLACE = 13, RG_BG_TILES = 14,
  RG_BG_COLOR_STEPS = 15, RG_BG_IN_BLOCKS = 16, RG_BG_CAN_TURN = 17, RG_BG_PAINTED = 18, RG_BG_RUN_COLORS = 19,
  RG_BG_FIELDS = 20;
const RG_NOT_PAINTED = -1;
const RG_RUN_TILES = 0, RG_RUN_WIDTH = 1, RG_RUN_HEIGHT = 2, RG_RUN_PLACES = 3, RG_RUN_FIRST_IMAGE = 4,
  RG_RUN_IMAGES = 5, RG_RUN_FIELDS = 6;
const RG_RUN_IMAGE_FIELDS = 17;
const RG_CELL_EMPTY = -1;
const RG_MAP_CELLS = 0, RG_MAP_COLS = 1, RG_MAP_ROWS = 2, RG_MAP_GRID_COLS = 3, RG_MAP_GRID_ROWS = 4, RG_MAP_FIELDS = 5;
const RG_SIZE_BACKGROUNDS = 0, RG_SIZE_DEPTHS = 1, RG_SIZE_ALWAYS_UP = 2, RG_SIZE_REBUILT_WHOLE = 3,
  RG_SIZE_SEE_THROUGH = 4, RG_SIZE_SCREEN_KINDS_CHANGE = 5, RG_SIZE_LARGEST_BLOCK = 6, RG_SIZE_RUNS = 7,
  RG_SIZE_RUN_PIXELS = 8, RG_SIZE_IMAGES = 9;
const RG_FADE_WHOLE_SCREEN = 0, RG_FADE_INSIDE = 1, RG_FADE_OUTSIDE = 2;

/* Where choice number +which+ is in a row that holds a sprite's own first and then +others+ more. */
function rg_place_of_choice(which, others) { return which >= 0 && which < others ? which + 1 : 0; }

/* Two colors for a line of text, and the test that says which. */
function rg_pick_color(showing, color, picked) { return showing !== 0 ? picked : color; }

/* --- small arithmetic --- */

function floor_div(a, b) { return Math.floor(a / b); }
function floor_mod(a, b) { return a - Math.floor(a / b) * b; }
function clamp_number(value, low, high) { return value < low ? low : (value > high ? high : value); }
function background_field(background, field) { return rg_game_backgrounds[background * RG_BG_FIELDS + field]; }

/* TWO PAGES, OR ONE (Framebuffer#paged=). Drawing always lands on +pixels+ and the viewer always
 * reads +viewed+; with one page those are the same picture. */
const first_page = new Uint16Array(RG_CELLS), second_page = new Uint16Array(RG_CELLS);
let pixels = first_page;
let viewed = first_page;
const shown = new Uint16Array(RG_CELLS);

/* Where drawing goes: the picture, or for a moment the copy of the scenery kept to put back under
 * a sprite (Reference#drawing_into). */
let target = first_page;

/* The part of the screen drawing is held inside, and the areas in force around it. */
let area = { in_force: 0, left: 0, top: 0, right: 0, bottom: 0 };
const outer_areas = [];
const AREAS_DEEP = 64;

let camera_x = 0, camera_y = 0;

/* The patches of picture saved under bitmap sprites, by buffer number. */
const NO_CELL = -1;
const saved_patches = [];

/* THE SCENERY WITH NOTHING ON IT (Reference @scene_fb). */
const scenery = new Uint16Array(RG_CELLS);
let scenery_kept = 0;

let held = 0;
let frames_begun = 0;
let kind = -1;
let owed = 0;
let current_scene = -1;

let fade_white = 0, fade_steps = 0;
const TINT_NONE = 0, TINT_TOWARD = 1, TINT_COLOR = 2;
let tint_mode = TINT_NONE;
let tint_white = 0, tint_color = 0, tint_steps = 0, tint_by_display = 0;

let block = 1, read_block = 1;

const NOTHING_ON_SHEET = -1;
const sheet = new Int32Array(RG_CELLS);
let onto_sheet = 0;
let rows_tall = 1;

/* A FADE PLACED IN THE STACK, while one is in force (Reference @fade_placed). */
let placed_fade = { in_force: 0, layer_place: RG_NO_LAYER, toward_white: 0, steps: 0 };
let fading_what_is_painted = 0;

/* WHAT IS PAINTED FROM HERE ON IS MIXED with what is already in the cell (Framebuffer @through). */
let mixing = 0;
let mixed_by = { painted: 0, under: 0 };

/* THE TWO COLORS EACH MIXED CELL WAS MIXED FROM (Framebuffer @mixed_tops). */
function new_mixed_sides() {
  return { is_mixed: new Uint8Array(RG_CELLS), tops: new Uint16Array(RG_CELLS), unders: new Uint16Array(RG_CELLS) };
}
const picture_mixes = new_mixed_sides(), scenery_mixes = new_mixed_sides();
let mixed_cells_by = { painted: 0, under: 0 };

/* THE PICTURE WITH NO SPRITES ON IT (Framebuffer @scenery). */
const picture_without_sprites = new Uint16Array(RG_CELLS);
let painting_sprite = 0;

/* Scenery up, in the order it went up (Reference @bg_shown), one entry for every time a background
 * is put up. */
let shown_backgrounds = [];

/* What the game does to a background, kept at the entry that keeps it for the name. */
const cells_now = [], scrolls = [], tile_set_now = [], turns = [];
for (let i = 0; i < RG_MAX_BACKGROUNDS; i++) {
  cells_now.push({ which: 0, cells: null });
  scrolls.push({ x: 0, y: 0 });
  tile_set_now.push(0);
  turns.push({ turned: 0, angle: 0, size: 0, pivot_x: 0, pivot_y: 0 });
}

/* The backgrounds put up this pass, shown from their top-left corner whatever their scroll
 * (Reference @bg_from_corner), whether there are any, and whether their pass has ended
 * (Reference @bg_corners_expired). */
const from_corner = new Array(RG_MAX_BACKGROUNDS).fill(0);
let any_from_corner = 0, corners_expired = 0;

/* The sprites on screen this frame: being said (drawing), and as the last rebuild draws them. */
let drawing = [];
let sprite_layer = [];

/* Where each sprite was last drawn straight onto the picture (Reference @obj_prev). */
const last_drawn = [];
for (let i = 0; i < RG_MAX_SPRITES; i++) last_drawn.push({ drawn: 0, x: 0, y: 0 });

/* --- the picture itself (Framebuffer) --- */

function on_screen(x, y) { return x >= 0 && x < RG_SCREEN_WIDTH && y >= 0 && y < RG_SCREEN_HEIGHT; }

function paintable(x, y) {
  if (!on_screen(x, y)) return false;
  return !area.in_force || (x >= area.left && x < area.right && y >= area.top && y < area.bottom);
}

function widened(channel) { return (channel << 3) | (channel >> 2); }

/* Framebuffer#mix_see_through */
function mixed_with_under(color, under, by) {
  let out = 0;
  for (let channel = 0; channel < 3; channel++) {
    const have = widened((color >> (5 * channel)) & 0x1F), below = widened((under >> (5 * channel)) & 0x1F);
    const mix = Math.trunc((have * by.painted + below * by.under) / 16);
    out |= ((mix > 255 ? 255 : mix) >> 3) << (5 * channel);
  }
  return out;
}

/* Framebuffer#darkened_by_display: done in the channel's own byte as the interpreter does it. */
function darkened_by_display(color, steps) {
  if (steps === 0) return color;
  let packed = 0;
  for (let channel = 0; channel < 3; channel++) {
    const shift = channel * 5;
    const placed = widened((color >> shift) & 0x1F) * 2 ** (channel * 8);
    const kept = Math.floor((placed - Math.trunc((placed * steps) / 16)) / 2 ** (channel * 8));
    packed |= (kept >> 3) << shift;
  }
  return packed;
}

/* Framebuffer#brightened_by_display */
function brightened_by_display(color, steps) {
  if (steps === 0) return color;
  let packed = 0;
  for (let channel = 0; channel < 3; channel++) {
    const shift = channel * 5, have = widened((color >> shift) & 0x1F);
    packed |= ((have + Math.trunc(((255 - have) * steps) / 16)) >> 3) << shift;
  }
  return packed;
}

function faded_by_display(color, white, steps) {
  return white ? brightened_by_display(color, steps) : darkened_by_display(color, steps);
}

function faded_as_painted(color) {
  if (!fading_what_is_painted) return color & 0xFFFF;
  return faded_by_display(color & 0xFFFF, placed_fade.toward_white, placed_fade.steps);
}

function mixes_of(page) {
  if (page === pixels) return picture_mixes;
  return page === scenery ? scenery_mixes : null;
}

/* Framebuffer#blend_into_cell */
function into_cell(color, under, page, at) {
  const painted = faded_as_painted(color);
  const kept = mixes_of(page);
  if (kept) {
    kept.is_mixed[at] = mixing;
    if (mixing) {
      kept.tops[at] = painted;
      kept.unders[at] = under;
    }
  }
  return mixing ? mixed_with_under(painted, under, mixed_by) : painted;
}

/* Reference#see_through_sprites?, worked out once. */
let sprites_seen_through_answer = -1;
function sprites_seen_through() {
  if (sprites_seen_through_answer >= 0) return sprites_seen_through_answer;
  sprites_seen_through_answer = 0;
  for (let layer = 0; layer < rg_game_picture_sizes[RG_SIZE_SEE_THROUGH]; layer++) {
    if (rg_game_see_through[layer * RG_ST_FIELDS + RG_ST_HOLDS_A_SPRITE]) sprites_seen_through_answer = 1;
  }
  return sprites_seen_through_answer;
}

function keeps_picture_without_sprites() { return target !== scenery && sprites_seen_through(); }

/* Framebuffer#set_pixel */
function set_pixel(x, y, color) {
  if (!paintable(x, y)) return;
  const at = y * RG_SCREEN_WIDTH + x;
  const kept = keeps_picture_without_sprites();
  const under = kept && painting_sprite ? picture_without_sprites : target;
  const painted = into_cell(color, under[at], target, at);
  target[at] = painted;
  if (kept && !painting_sprite) picture_without_sprites[at] = painted;
}

/* Framebuffer#fill_rect */
function fill_cells(x, y, width, height, color) {
  const left = x < 0 ? 0 : x, top = y < 0 ? 0 : y;
  let right = x + width, bottom = y + height;
  if (right > RG_SCREEN_WIDTH) right = RG_SCREEN_WIDTH;
  if (bottom > RG_SCREEN_HEIGHT) bottom = RG_SCREEN_HEIGHT;
  for (let py = top; py < bottom; py++) {
    for (let px = left; px < right; px++) set_pixel(px, py, color);
  }
}

/* Framebuffer#clear */
function clear_to(color) {
  if (area.in_force) {
    fill_cells(area.left, area.top, area.right - area.left, area.bottom - area.top, color);
    return;
  }
  const painted = faded_as_painted(color);
  target.fill(painted);
  const kept = mixes_of(target);
  if (kept) kept.is_mixed.fill(0);
  if (!keeps_picture_without_sprites()) return;
  picture_without_sprites.fill(painted);
}

function rg_screen_clear(color) { clear_to(color); }
function rg_screen_fill_rect(x, y, width, height, color) { fill_cells(x, y, width, height, color); }

function rg_screen_inside(x, y, width, height) {
  if (outer_areas.length >= AREAS_DEEP) rg_fault(`more than ${AREAS_DEEP} \`inside\` blocks are open at once`);
  outer_areas.push(area);
  area = { in_force: 1, left: x, top: y, right: x + width, bottom: y + height };
}

function rg_screen_inside_ended() { area = outer_areas.pop(); }

function rg_screen_camera(x, y) {
  camera_x = x;
  camera_y = y;
}

function rg_screen_camera_x() { return camera_x; }
function rg_screen_camera_y() { return camera_y; }

/* Framebuffer#paged= */
function show_pages(two) {
  if (two === (pixels !== viewed ? 1 : 0)) return;
  if (!two) {
    viewed = pixels;
    return;
  }
  viewed = pixels === first_page ? second_page : first_page;
  viewed.fill(0);
}

/* Reference#exec_save_region */
function rg_patch_save(buffer, width, height, x, y) {
  if (!saved_patches[buffer]) saved_patches[buffer] = new Int32Array(Math.max(width * height, 1));
  const patch = saved_patches[buffer];
  for (let row = 0; row < height; row++) {
    for (let col = 0; col < width; col++) {
      const px = x + col, py = y + row;
      patch[row * width + col] = on_screen(px, py) ? pixels[py * RG_SCREEN_WIDTH + px] : NO_CELL;
    }
  }
}

/* Reference#exec_restore_region */
function rg_patch_restore(buffer, width, height, x, y) {
  const patch = saved_patches[buffer];
  if (!patch) return;
  for (let row = 0; row < height; row++) {
    for (let col = 0; col < width; col++) {
      const color = patch[row * width + col];
      if (color !== NO_CELL) set_pixel(x + col, y + row, color);
    }
  }
}

function rg_screen_pixel(x, y, color) { set_pixel(x, y, color); }

/* Reference#exec_draw_text: each lit pixel of each letter, from the text's top left. */
function rg_screen_points(x, y, color, points, count, first = 0) {
  for (let i = 0; i < count; i++) set_pixel(x + points[2 * (first + i)], y + points[2 * (first + i) + 1], color);
}

/* Reference#exec_draw_digit */
function rg_screen_digit(value, x, y, color, points, starts) {
  if (value < 0 || value > 9) return;
  rg_screen_points(x, y, color, points, starts[value + 1] - starts[value], starts[value]);
}

/* --- see-through layers --- */

function see_through_layers() { return rg_game_picture_sizes[RG_SIZE_SEE_THROUGH]; }
function see_through_field(layer, field) { return rg_game_see_through[layer * RG_ST_FIELDS + field]; }

const NOBODY_ASKED = -1;
let asked_layer = NOBODY_ASKED;
const answered = { shows: 0, behind: 0 };

function rg_see_through_asked(layer) { return layer === asked_layer ? 1 : 0; }

function rg_see_through_answer(shows, behind) {
  answered.shows = shows;
  answered.behind = behind;
}

/* IR::SeeThrough.nearest_steps and .floor_steps */
function nearest_sixteenths(amount) { return clamp_number(floor_div(amount * 16 + 50, 100), 0, 16); }
function whole_sixteenths(amount) { return clamp_number(floor_div(amount * 16, 100), 0, 16); }

/* Reference#live_see_through_weights */
function shares_now(layer) {
  asked_layer = layer;
  rg_game_see_through_amounts();
  asked_layer = NOBODY_ASKED;
  if (see_through_field(layer, RG_ST_ONE_AMOUNT)) {
    const under = whole_sixteenths(answered.behind);
    return { painted: 16 - under, under };
  }
  return { painted: nearest_sixteenths(answered.shows), under: nearest_sixteenths(answered.behind) };
}

const owed_shares = [], told_shares = [];
for (let i = 0; i < RG_MAX_SEE_THROUGH; i++) {
  owed_shares.push({ kept: 0, at: { painted: 0, under: 0 } });
  told_shares.push({ kept: 0, at: { painted: 0, under: 0 } });
}

/* Reference#layer_has_anything? */
function layer_holds_anything(layer) {
  if (see_through_field(layer, RG_ST_HOLDS_A_SPRITE)) return true;
  for (let bg = 0; bg < rg_game_picture_sizes[RG_SIZE_BACKGROUNDS]; bg++) {
    if (showing(bg) && background_field(bg, RG_BG_SEE_THROUGH) === layer) return true;
  }
  return false;
}

/* Reference#capture_see_through_weights */
function keep_shares_for_owed_rebuild() {
  for (let layer = 0; layer < see_through_layers(); layer++) {
    owed_shares[layer].kept = !see_through_field(layer, RG_ST_AMOUNTS_WRITTEN) && layer_holds_anything(layer) ? 1 : 0;
    if (owed_shares[layer].kept) owed_shares[layer].at = shares_now(layer);
  }
}

function forget_kept_shares() {
  for (let layer = 0; layer < see_through_layers(); layer++) owed_shares[layer].kept = 0;
}

/* Reference#fading? */
function fade_takes_the_blend() {
  if (placed_fade.in_force) return placed_fade.steps > 0;
  return target !== scenery && fade_steps > 0;
}

/* Reference#set_see_through_for, for scenery */
function mix_as_layer(layer) {
  painting_sprite = 0;
  mixing = layer !== RG_SOLID && !fade_takes_the_blend() ? 1 : 0;
  if (mixing) mixed_by = mixed_cells_by = owed_shares[layer].kept ? owed_shares[layer].at : shares_now(layer);
}

/* ...for a sprite */
function mix_as_sprite(sprite) {
  mix_as_layer(rg_game_sprite_see_through[sprite]);
  painting_sprite = 1;
}

function mix_nothing() {
  mixing = 0;
  painting_sprite = 0;
}

/* --- effects over the finished picture (Framebuffer#faded) --- */

/* Framebuffer#walked_toward */
function walked_toward(color, white, steps) {
  if (steps === 0) return color;
  let out = 0;
  for (let channel = 0; channel < 3; channel++) {
    let c = (color >> (5 * channel)) & 0x1F;
    c = white ? c + Math.trunc(((31 - c) * steps) / 32) : c - Math.trunc((c * steps) / 32);
    out |= c << (5 * channel);
  }
  return out & 0xFFFF;
}

/* Framebuffer#mixed and #mixed_by_display */
function mixed(color, toward, steps, by_display) {
  if (steps === 0) return color;
  const keep = 32 - steps;
  let out = 0;
  for (let channel = 0; channel < 3; channel++) {
    const have = (color >> (5 * channel)) & 0x1F, want = (toward >> (5 * channel)) & 0x1F;
    if (by_display) {
      out |= (Math.trunc((widened(have) * keep + widened(want) * steps) / 32) >> 3) << (5 * channel);
    } else {
      out |= Math.trunc((have * keep + want * steps) / 32) << (5 * channel);
    }
  }
  return out & 0xFFFF;
}

/* Framebuffer#faded */
function faded_where(color, fade_here) {
  if (tint_mode === TINT_TOWARD && tint_by_display) return faded_by_display(color, tint_white, tint_steps >> 1);
  if (tint_mode === TINT_TOWARD) return walked_toward(color, tint_white, tint_steps);
  if (tint_mode === TINT_COLOR) return mixed(color, tint_color, tint_by_display ? tint_steps & ~1 : tint_steps, tint_by_display);
  if (!fade_here) return color;
  return faded_by_display(color, fade_white, fade_steps);
}

function faded(color) { return faded_where(color, 1); }

/* Framebuffer#shown_color */
function shown_color(at, stored, fade_here) {
  if (tint_mode === TINT_NONE || pixels !== viewed || !picture_mixes.is_mixed[at]) return faded_where(stored, fade_here);
  return mixed_with_under(faded(picture_mixes.tops[at]), faded(picture_mixes.unders[at]), mixed_cells_by);
}

let fade_side = RG_FADE_WHOLE_SCREEN;
const fade_area = [0, 0, 0, 0];

/* Framebuffer#fade_reaches? */
function fade_reaches(x, y) {
  if (fade_side === RG_FADE_WHOLE_SCREEN) return 1;
  const within = x >= fade_area[0] && x < fade_area[2] && y >= fade_area[1] && y < fade_area[3];
  return (fade_side === RG_FADE_INSIDE ? within : !within) ? 1 : 0;
}

/* Reference#exec_fade, through Framebuffer#fade_steps_to or #tint_steps_to */
function fade_to(placed, layer_place, toward_white, steps, walked) {
  const took_the_blend = fade_takes_the_blend(), was_placed = placed_fade.in_force;
  placed_fade = { in_force: placed, layer_place, toward_white, steps };
  if (walked) {
    tint_mode = TINT_TOWARD;
    tint_white = toward_white;
    tint_steps = steps;
    tint_by_display = tint_mixed_by_display();
    fade_steps = 0;
  } else {
    fade_white = toward_white;
    fade_steps = placed ? 0 : steps;
    tint_mode = TINT_NONE;
  }
  const blend_changed_hands = see_through_layers() > 0 && fade_takes_the_blend() !== took_the_blend;
  if (was_placed || placed || blend_changed_hands) request_repaint();
}

function rg_screen_fade(toward_white, steps, walked) {
  fade_side = RG_FADE_WHOLE_SCREEN;
  fade_to(0, RG_NO_LAYER, toward_white, steps, walked);
}

function rg_screen_fade_in_area(reaches, left, top, right, bottom, toward_white, steps) {
  fade_side = reaches;
  fade_area[0] = left;
  fade_area[1] = top;
  fade_area[2] = right;
  fade_area[3] = bottom;
  fade_to(0, RG_NO_LAYER, toward_white, steps, 0);
}

function rg_screen_fade_under(layer_place, toward_white, steps, walked) {
  fade_side = RG_FADE_WHOLE_SCREEN;
  fade_to(1, layer_place, toward_white, steps, walked);
}

/* Reference#tint_by_display? */
function tint_mixed_by_display() { return painted_screen() && pixels === viewed ? 1 : 0; }

/* Reference#exec_tint */
function rg_screen_tint(color, steps) {
  const took_the_blend = fade_takes_the_blend(), was_placed = placed_fade.in_force;
  placed_fade.in_force = 0;
  tint_mode = TINT_COLOR;
  tint_color = color;
  tint_steps = steps;
  tint_by_display = tint_mixed_by_display();
  fade_steps = 0;
  const blend_changed_hands = see_through_layers() > 0 && fade_takes_the_blend() !== took_the_blend;
  if (was_placed || blend_changed_hands) request_repaint();
}

/* Backends::FadeSteps.steps */
function rg_fade_steps(amount, fraction_bits, walked) {
  const levels = walked ? 32 : 16;
  if (fraction_bits < 0) {
    const sixteenths = whole_sixteenths(amount);
    return walked ? sixteenths * 2 : sixteenths;
  }
  return clamp_number(floor_div(amount * levels, 100 * 2 ** fraction_bits), 0, levels);
}

/* --- scenery --- */

function keeper_of(background) { return background_field(background, RG_BG_KEPT_BY); }

/* Reference#scroll_shown: where a background's window sits on the display now. */
function scroll_shown(background) {
  const keeper = keeper_of(background);
  return from_corner[keeper] ? { x: 0, y: 0 } : scrolls[keeper];
}

/* Reference#forget_expired_corners */
function forget_expired_corners() {
  if (!corners_expired) return;
  corners_expired = 0;
  from_corner.fill(0);
  any_from_corner = 0;
}

/* Reference#mark_from_corner */
function mark_from_corner(background) {
  forget_expired_corners();
  from_corner[keeper_of(background)] = 1;
  any_from_corner = 1;
}

/* Map number +which+ of a background's own maps, as where its entry starts in rg_game_maps. */
function map_entry(background, which) { return RG_MAP_FIELDS * (background_field(background, RG_BG_FIRST_MAP) + which); }

/* Reference#map_of: the map a background's cells hold now. */
function map_now(background) {
  const now = cells_now[keeper_of(background)];
  return now.cells ? map_entry(keeper_of(background), now.which) : map_entry(background, 0);
}

function map_cols(background) { return rg_game_maps[map_now(background) + RG_MAP_COLS]; }
function map_rows(background) { return rg_game_maps[map_now(background) + RG_MAP_ROWS]; }

function in_map(background, row, col) {
  return row >= 0 && row < map_rows(background) && col >= 0 && col < map_cols(background);
}

function cell_place(background, row, col) { return row * map_cols(background) + col; }

/* Reference#map_of: what a cell holds NOW. Below nought where it holds no tile. */
function map_cell(background, row, col) {
  if (!in_map(background, row, col)) return RG_CELL_EMPTY;
  const own = cells_now[keeper_of(background)].cells;
  if (own) return own[cell_place(background, row, col)];
  return rg_game_map_cells[rg_game_maps[map_now(background) + RG_MAP_CELLS] + cell_place(background, row, col)];
}

/* The name's cells become the run's own copy of map number +which+ of the keeping entry's maps. */
function copy_map(background, which) {
  const keeper = keeper_of(background);
  const map = map_entry(keeper, which);
  const start = rg_game_maps[map + RG_MAP_CELLS];
  const count = rg_game_maps[map + RG_MAP_COLS] * rg_game_maps[map + RG_MAP_ROWS];
  cells_now[keeper] = { which, cells: rg_game_map_cells.slice(start, start + count) };
}

function forget_own_cells(background) { cells_now[keeper_of(background)] = { which: 0, cells: null }; }

/* WHAT THE GAME HAS PAINTED (Reference @bitmaps, for the tiles and pictures of a run). */
const RUN_TILE_SIDE = 8, RUN_TILE_PIXELS = RUN_TILE_SIDE * RUN_TILE_SIDE, PLACES_IN_RUN_COLORS = 16;
let painted_places = null;

function run_field(run, field) { return rg_game_tile_runs[RG_RUN_FIELDS * run + field]; }

/* Where a run's places start in painted_places. */
function places_of(run) {
  if (!painted_places) painted_places = new Uint8Array(rg_game_picture_sizes[RG_SIZE_RUN_PIXELS] + 1);
  return run_field(run, RG_RUN_PLACES);
}

/* One pixel of a cell's tile, or RG_SEE_THROUGH (Reference#background_pixel). */
function tile_pixel(background, cell, tx, ty) {
  const painted = background_field(background, RG_BG_PAINTED);
  if (painted !== RG_NOT_PAINTED && rg_game_painted_tiles[painted + 2 * cell] !== RG_NOT_PAINTED) {
    const run = rg_game_painted_tiles[painted + 2 * cell], which = rg_game_painted_tiles[painted + 2 * cell + 1];
    const place = painted_places_at(places_of(run) + which * RUN_TILE_PIXELS + ty * RUN_TILE_SIDE + tx);
    const set = tile_set_now[keeper_of(background)] * rg_game_picture_sizes[RG_SIZE_RUNS] + run;
    return rg_game_run_colors[background_field(background, RG_BG_RUN_COLORS) + set * PLACES_IN_RUN_COLORS + place];
  }
  const tile_w = background_field(background, RG_BG_TILE_W), tile_h = background_field(background, RG_BG_TILE_H);
  const tile = tile_set_now[keeper_of(background)] * background_field(background, RG_BG_TILES) + cell;
  return rg_game_tile_pixels[background_field(background, RG_BG_TILES_START) + tile * tile_w * tile_h + ty * tile_w + tx];
}

function painted_places_at(at) { return painted_places[at]; }

/* Reference#stamp_background */
function rg_background_stamp(background) {
  const tile_w = background_field(background, RG_BG_TILE_W), tile_h = background_field(background, RG_BG_TILE_H);
  mix_as_layer(background_field(background, RG_BG_SEE_THROUGH));
  const rows = map_rows(background), cols = map_cols(background);
  for (let row = 0; row < rows; row++) {
    for (let col = 0; col < cols; col++) {
      const cell = map_cell(background, row, col);
      if (cell < 0) continue;
      for (let ty = 0; ty < tile_h; ty++) {
        for (let tx = 0; tx < tile_w; tx++) {
          const color = tile_pixel(background, cell, tx, ty);
          if (color !== RG_SEE_THROUGH) set_pixel(col * tile_w + tx, row * tile_h + ty, color);
        }
      }
    }
  }
  mix_nothing();
}

/* Reference#request_repaint */
function request_repaint() {
  if (kind === RG_BITMAP && rg_game_picture_sizes[RG_SIZE_SCREEN_KINDS_CHANGE]) return;
  forget_expired_corners();
  owed = 1;
  keep_shares_for_owed_rebuild();
}

function rg_screen_request_rebuild() { request_repaint(); }

/* Reference#painted_screen? */
function painted_screen() { return kind < 0 || kind === RG_BITMAP; }

/* Reference#exec_pixelate */
function rg_screen_pixelate(size) {
  const held_to = clamp_number(size, 1, rg_game_picture_sizes[RG_SIZE_LARGEST_BLOCK]);
  if (held_to === block) return;
  block = held_to;
  if (painted_screen()) read_block = block;
  else request_repaint();
}

/* Reference#exec_see_through */
function rg_see_through_told(layer) {
  const now = shares_now(layer);
  const told = told_shares[layer];
  if (told.kept && told.at.painted === now.painted && told.at.under === now.under) return;
  told_shares[layer] = { kept: 1, at: now };
  request_repaint();
}

function stack_place(background) { return background_field(background, RG_BG_STACK_PLACE); }

/* Reference#behind?: only when both named a layer. */
function behind(a, b) {
  return stack_place(a) !== RG_NO_LAYER && stack_place(b) !== RG_NO_LAYER && stack_place(a) < stack_place(b);
}

function remember_put_up(background) { shown_backgrounds.push(background); }

function in_order_asked(entry, over) { return over < 0 || behind(over, entry); }

/* Where the LAST entry for +background+ lands once the entries asked for are put in the order the
 * stack asks for (IR::Stacking.order_by_stack), or -1 when it has no entry. */
function last_place_in_stack_order(background, over) {
  const place = stack_place(background);
  let at = -1, last = -1, further_back = 0, in_its_layer = 0, in_its_layer_by_last = 0;
  for (const entry of shown_backgrounds) {
    if (!in_order_asked(entry, over)) continue;
    at++;
    if (stack_place(entry) !== RG_NO_LAYER && stack_place(entry) < place) further_back++;
    if (stack_place(entry) !== RG_NO_LAYER && stack_place(entry) === place) in_its_layer++;
    if (entry === background) {
      last = at;
      in_its_layer_by_last = in_its_layer;
    }
  }
  if (last < 0 || place === RG_NO_LAYER) return last;

  const nth = further_back + in_its_layer_by_last - 1;
  let named = -1;
  at = -1;
  for (const entry of shown_backgrounds) {
    if (!in_order_asked(entry, over)) continue;
    at++;
    if (stack_place(entry) !== RG_NO_LAYER && ++named === nth) return at;
  }
  return -1;
}

/* Reference#in_stack_order over the scenery that is up, each stamped once in that order. */
function stamp_in_stack_order(over) {
  if (over >= 0 && stack_place(over) === RG_NO_LAYER) return;
  const backgrounds = rg_game_picture_sizes[RG_SIZE_BACKGROUNDS];
  const lands = [];
  for (let bg = 0; bg < backgrounds; bg++) lands.push(last_place_in_stack_order(bg, over));
  for (;;) {
    let next = -1;
    for (let bg = 0; bg < backgrounds; bg++) {
      if (lands[bg] >= 0 && (next < 0 || lands[bg] < lands[next])) next = bg;
    }
    if (next < 0) return;
    rg_background_stamp(next);
    lands[next] = -1;
  }
}

/* Reference#put_up_background */
function rg_background_put_up(background) {
  if (background_field(background, RG_BG_ON_ARRIVAL)) forget_own_cells(background);
  remember_put_up(background);
  mark_from_corner(background);
  scenery_kept = 0;
  if (turns[keeper_of(background)].turned) {
    request_repaint();
    return;
  }
  rg_background_stamp(background);
  stamp_in_stack_order(background);
}

/* Reference#exec_affine_background */
function rg_background_turn(background, angle, size, pivot_x, pivot_y) {
  turns[keeper_of(background)] = { turned: 1, angle: floor_mod(angle, 360), size, pivot_x, pivot_y };
  request_repaint();
}

/* Reference#showing_scenery */
function showing(background) {
  const scene = background_field(background, RG_BG_SCENE);
  return scene === RG_EVERY_SCENE || scene === current_scene;
}

function rg_background_scroll(background, x, y) {
  scrolls[keeper_of(background)] = { x, y };
  from_corner[keeper_of(background)] = 0;
  request_repaint();
}

/* Reference#exec_set_tile: the copy is made even when the cell turns out not to be there. */
function rg_background_set_tile(background, col, row, tile) {
  if (!cells_now[keeper_of(background)].cells) copy_map(background, 0);
  if (!in_map(background, row, col)) return;
  const cells = cells_now[keeper_of(background)].cells;
  const at = cell_place(background, row, col);
  if (cells[at] === tile) return;
  cells[at] = tile;
  request_repaint();
}

function rg_background_show_map(background, which) {
  if (which < 0 || which >= background_field(background, RG_BG_SHOWABLE_MAPS)) return;
  copy_map(background, which);
  request_repaint();
}

function rg_background_draw_with(background, which) {
  tile_set_now[keeper_of(background)] = rg_place_of_choice(which, background_field(background, RG_BG_COLOR_STEPS));
  request_repaint();
}

/* Framebuffer#paint_row, a cell at a time */
function lay_scenery(px, py, color) {
  const at = py * RG_SCREEN_WIDTH + px;
  pixels[at] = into_cell(color, pixels[at], pixels, at);
  if (sprites_seen_through()) picture_without_sprites[at] = pixels[at];
}

function paint_map_pixel(background, mx, my, px, py) {
  const tile_w = background_field(background, RG_BG_TILE_W), tile_h = background_field(background, RG_BG_TILE_H);
  const cell = map_cell(background, Math.trunc(my / tile_h), Math.trunc(mx / tile_w));
  if (cell < 0) return;
  const color = tile_pixel(background, cell, mx % tile_w, my % tile_h);
  if (color === RG_SEE_THROUGH) return;
  if (onto_sheet) sheet[py * RG_SCREEN_WIDTH + px] = color;
  else lay_scenery(px, py, color);
}

function row_drawn_from(py) { return py - (py % rows_tall); }

const asked_bend = { background: NOBODY_ASKED, py: 0, offset: 0 };

function rg_bend_asked(background) { return background === asked_bend.background ? 1 : 0; }
function rg_bend_line() { return asked_bend.py; }
function rg_bend_answer(offset) { asked_bend.offset = offset; }

const bend_lines = [], bend_lines_kept = [];
for (let i = 0; i < RG_MAX_BACKGROUNDS; i++) {
  bend_lines.push(new Int32Array(RG_SCREEN_HEIGHT));
  bend_lines_kept.push(0);
}

/* Reference#run_bend_for_row */
function run_bend_for_line(keeper, py) {
  asked_bend.background = keeper;
  asked_bend.py = py;
  rg_game_bend_offsets();
  asked_bend.background = NOBODY_ASKED;
  return asked_bend.offset;
}

function rg_bend_work_out(background, first_line, past_line) {
  const keeper = keeper_of(background);
  for (let py = first_line; py < past_line; py++) bend_lines[keeper][py] = run_bend_for_line(keeper, py);
  bend_lines_kept[keeper] = 1;
}

/* Reference#work_out_bends */
function rg_screen_work_out_bends() {
  rg_game_work_out_bends();
  request_repaint();
}

/* Reference#bend_offset_at */
function bend_at(background, py) {
  if (!background_field(background, RG_BG_BENT)) return 0;
  const keeper = keeper_of(background);
  if (bend_lines_kept[keeper]) return bend_lines[keeper][py];
  return frames_begun ? 0 : run_bend_for_line(keeper, py);
}

/* Reference#paint_streamed_background_window */
function paint_window_without_wrapping(background) {
  const map_h = map_rows(background) * background_field(background, RG_BG_TILE_H);
  const scroll = scroll_shown(background);
  for (let py = 0; py < RG_SCREEN_HEIGHT; py++) {
    const my = scroll.y + row_drawn_from(py);
    if (my < 0 || my >= map_h) continue;
    const off_x = scroll.x + bend_at(background, py);
    for (let px = 0; px < RG_SCREEN_WIDTH; px++) {
      const mx = off_x + px;
      if (mx >= 0) paint_map_pixel(background, mx, my, px, py);
    }
  }
}

/* Reference#paint_background_window, for a background never turned */
function paint_window(background) {
  if (background_field(background, RG_BG_NEVER_WRAPS)) {
    paint_window_without_wrapping(background);
    return;
  }
  const map = map_now(background);
  const map_w = rg_game_maps[map + RG_MAP_GRID_COLS] * background_field(background, RG_BG_TILE_W);
  const map_h = rg_game_maps[map + RG_MAP_GRID_ROWS] * background_field(background, RG_BG_TILE_H);
  if (map_w === 0 || map_h === 0) return;
  const scroll = scroll_shown(background);
  const off_y = floor_mod(scroll.y, map_h);
  for (let py = 0; py < RG_SCREEN_HEIGHT; py++) {
    const off_x = floor_mod(scroll.x + bend_at(background, py), map_w);
    const my = (off_y + row_drawn_from(py)) % map_h;
    for (let px = 0; px < RG_SCREEN_WIDTH; px++) paint_map_pixel(background, (off_x + px) % map_w, my, px, py);
  }
}

/* IR::Affine.matrix */
function affine_matrix(angle, size) {
  const scale_one = rg_game_turn_rules[0], one_th = rg_game_turn_rules[1];
  const most = rg_game_turn_rules[2], least_size = rg_game_turn_rules[3];
  const scale = size < least_size ? least_size : size;
  let recip = Math.trunc((scale_one * one_th) / scale);
  if (recip > most) recip = most;
  return [floor_div(rg_game_sines[angle + 90] * recip, one_th), floor_div(rg_game_sines[angle] * recip, one_th)];
}

/* Reference#paint_affine_background_window */
function paint_turned_window(background) {
  const tile_w = background_field(background, RG_BG_TILE_W), tile_h = background_field(background, RG_BG_TILE_H);
  const map = map_now(background);
  const map_w = rg_game_maps[map + RG_MAP_GRID_COLS] * tile_w;
  const map_h = rg_game_maps[map + RG_MAP_GRID_ROWS] * tile_h;
  if (map_w === 0 || map_h === 0) return;
  const turn = turns[keeper_of(background)];
  // A turned layer is placed by its turn, which putting it up leaves as it is.
  const scroll = scrolls[keeper_of(background)];
  const pivot_x = turn.pivot_x, pivot_y = turn.pivot_y, one_th = rg_game_turn_rules[1];
  const [turn_cos, turn_sin] = affine_matrix(turn.angle, turn.size);
  for (let py = 0; py < RG_SCREEN_HEIGHT; py++) {
    const dy = row_drawn_from(py) - pivot_y;
    for (let px = 0; px < RG_SCREEN_WIDTH; px++) {
      const dx = px - pivot_x;
      const mx = floor_mod(scroll.x + pivot_x + floor_div(turn_cos * dx + turn_sin * dy, one_th), map_w);
      const my = floor_mod(scroll.y + pivot_y + floor_div(-turn_sin * dx + turn_cos * dy, one_th), map_h);
      const cell = map_cell(background, Math.trunc(my / tile_h), Math.trunc(mx / tile_w));
      if (cell < 0) continue;
      const color = tile_pixel(background, cell, mx % tile_w, my % tile_h);
      if (color === RG_SEE_THROUGH) continue;
      if (onto_sheet) sheet[py * RG_SCREEN_WIDTH + px] = color;
      else set_pixel(px, py, color);
    }
  }
}

function paint_background(background) {
  if (turns[keeper_of(background)].turned) paint_turned_window(background);
  else paint_window(background);
}

/* Reference#paint_scenery_in_blocks */
function paint_scenery_in_blocks(background) {
  sheet.fill(NOTHING_ON_SHEET);
  onto_sheet = 1;
  rows_tall = block;
  paint_background(background);
  onto_sheet = 0;
  rows_tall = 1;
  const wide = background_field(background, RG_BG_CAN_TURN) && block === 2 ? 1 : block;
  for (let py = 0; py < RG_SCREEN_HEIGHT; py++) {
    for (let px = 0; px < RG_SCREEN_WIDTH; px++) {
      const color = sheet[py * RG_SCREEN_WIDTH + px - (px % wide)];
      if (color !== NOTHING_ON_SHEET) lay_scenery(px, py, color);
    }
  }
}

function paint_scenery(background) {
  if (block > 1 && background_field(background, RG_BG_IN_BLOCKS)) paint_scenery_in_blocks(background);
  else paint_background(background);
}

/* --- sprites --- */

/* The images the game has painted, by image number (Reference#store_run_picture). */
const painted_images = [];

/* One picture: its pixels (an array and where in it they start), and its size. */
function picture_of(image) {
  const info = RG_IMAGE_FIELDS * image;
  const painted = painted_images[image];
  return painted ? { pixels: painted, start: 0, width: rg_game_images[info + 1], height: rg_game_images[info + 2] }
    : { pixels: rg_game_image_pixels, start: rg_game_images[info], width: rg_game_images[info + 1], height: rg_game_images[info + 2] };
}

/* Reference#run_tile_places */
function read_tile_places(list, which, places, into) {
  for (let at = 0; at < RUN_TILE_PIXELS / 2; at++) {
    const index = which * (RUN_TILE_PIXELS / 2) + at;
    const byte = index < rg_list_length(list) ? rg_list_get(list, index) & 0xFF : 0;
    places[into + 2 * at] = byte & 0x0F;
    places[into + 2 * at + 1] = byte >> 4;
  }
}

/* Reference#copy_run_tiles */
function rg_tiles_copy(run, list) {
  const start = places_of(run);
  const width = run_field(run, RG_RUN_WIDTH), height = run_field(run, RG_RUN_HEIGHT);
  if (width === 0) {
    for (let which = 0; which < run_field(run, RG_RUN_TILES); which++) {
      read_tile_places(list, which, painted_places, start + which * RUN_TILE_PIXELS);
    }
    return;
  }
  const across = Math.trunc(width / RUN_TILE_SIDE);
  const tile = new Uint8Array(RUN_TILE_PIXELS);
  for (let which = 0; which < across * Math.trunc(height / RUN_TILE_SIDE); which++) {
    read_tile_places(list, which, tile, 0);
    const left = (which % across) * RUN_TILE_SIDE, top = Math.trunc(which / across) * RUN_TILE_SIDE;
    for (let i = 0; i < RUN_TILE_PIXELS; i++) {
      painted_places[start + (top + Math.trunc(i / RUN_TILE_SIDE)) * width + left + (i % RUN_TILE_SIDE)] = tile[i];
    }
  }
  for (let i = 0; i < run_field(run, RG_RUN_IMAGES); i++) {
    const shown_as = (run_field(run, RG_RUN_FIRST_IMAGE) + i) * RG_RUN_IMAGE_FIELDS;
    const image = rg_game_run_images[shown_as];
    if (!painted_images[image]) painted_images[image] = new Int16Array(width * height);
    const into = painted_images[image];
    for (let at = 0; at < width * height; at++) into[at] = rg_game_run_images[shown_as + 1 + painted_places[start + at]];
  }
}

/* Reference#blit_image */
function blit_image(image, x, y) {
  const art = picture_of(image);
  for (let row = 0; row < art.height; row++) {
    for (let col = 0; col < art.width; col++) {
      const color = art.pixels[art.start + row * art.width + col];
      if (color !== RG_NOT_DRAWN) set_pixel(x + col, y + row, color);
    }
  }
}

/* WHICH ROWS OF THE SCREEN THE BOX OF A TURNED SPRITE IS SHOWN ON (Reference::TurnedBox). */
const TURNED_BOX_LINES = 256;

function turned_box_line(top, row) {
  const line = floor_mod(top + row, TURNED_BOX_LINES);
  return line < RG_SCREEN_HEIGHT ? line : -1;
}

function turned_box_on_screen(top, width, height, resizes) {
  let first = 0, past = height * 2;
  if (!resizes) {
    const reach = whole_root(width * width + height * height) + 2;
    first = height - Math.trunc(reach / 2);
    past = first + reach;
  }
  return top + past > 0 && top + first < RG_SCREEN_HEIGHT;
}

/* Reference#blit_image_transformed */
function blit_image_turned(image, x, y, angle, size, resizes) {
  const art = picture_of(image);
  const width = art.width, height = art.height, one_th = rg_game_turn_rules[1];
  const [turn_cos, turn_sin] = affine_matrix(floor_mod(angle, 360), size);
  const left = x - Math.trunc(width / 2), top = y - Math.trunc(height / 2);
  if (!turned_box_on_screen(top, width, height, resizes)) return;
  for (let iy = 0; iy < height * 2; iy++) {
    const line = turned_box_line(top, iy);
    if (line < 0) continue;
    const dy = iy - height;
    for (let ix = 0; ix < width * 2; ix++) {
      const dx = ix - width;
      const from_x = floor_div(turn_cos * dx + turn_sin * dy, one_th) + Math.trunc(width / 2);
      const from_y = floor_div(-turn_sin * dx + turn_cos * dy, one_th) + Math.trunc(height / 2);
      if (from_x < 0 || from_x >= width || from_y < 0 || from_y >= height) continue;
      const color = art.pixels[art.start + from_y * width + from_x];
      if (color !== RG_NOT_DRAWN) set_pixel(left + ix, line, color);
    }
  }
}

/* Reference#draw_object and #paint_snapshot_object */
function draw_placed(placed) {
  if (placed.turned) blit_image_turned(placed.image, placed.x, placed.y, placed.angle, placed.size, placed.resizes);
  else blit_image(placed.image, placed.x, placed.y);
}

/* --- a sprite in blocks (Reference::SpriteBlocks) --- */

function block_start(at) { return at - floor_mod(at, block); }
function block_end(edge) { return -floor_div(-edge, block) * block; }

function picture_color(art, col, row) {
  if (col < 0 || col >= art.width || row < 0 || row >= art.height) return RG_NOT_DRAWN;
  return art.pixels[art.start + row * art.width + col];
}

/* SpriteBlocks#paint_box */
function paint_box_in_blocks(art, x, y, left, top, width, height) {
  const first_row = top > 0 ? top : 0, past_row = top + height < RG_SCREEN_HEIGHT ? top + height : RG_SCREEN_HEIGHT;
  const first_col = left > 0 ? left : 0;
  let past_col = block_end(left + width);
  if (past_col > RG_SCREEN_WIDTH) past_col = RG_SCREEN_WIDTH;
  for (let py = first_row; py < past_row; py++) {
    const from_y = clamp_number(block_start(py), top, top + height - 1);
    for (let px = first_col; px < past_col; px++) {
      const color = picture_color(art, clamp_number(block_start(px), left, left + width - 1) - x, from_y - y);
      if (color !== RG_NOT_DRAWN) set_pixel(px, py, color);
    }
  }
}

/* SpriteBlocks#paint_upright */
function paint_upright_in_blocks(placed) {
  let listed = rg_game_sprite_blocks[placed.sprite];
  const pictures = rg_game_sprite_boxes[listed++], showing_picture = rg_game_image_pictures[placed.image];
  for (let i = 0; i < pictures; i++) {
    const name = rg_game_sprite_boxes[listed], boxes = rg_game_sprite_boxes[listed + 1];
    const box = listed + 2;
    listed = box + 4 * boxes;
    if (name !== showing_picture) continue;
    const art = picture_of(placed.image);
    for (let b = boxes - 1; b >= 0; b--) {
      paint_box_in_blocks(art, placed.x, placed.y, placed.x + rg_game_sprite_boxes[box + 4 * b],
        placed.y + rg_game_sprite_boxes[box + 4 * b + 1], rg_game_sprite_boxes[box + 4 * b + 2],
        rg_game_sprite_boxes[box + 4 * b + 3]);
    }
    return;
  }
  rg_fault(`sprite ${placed.sprite} is shown in blocks and has no boxes for the picture it shows`);
}

/* SpriteBlocks#turned_row */
function turned_row(py, top, height) {
  const LINES = 256;
  const first = floor_mod(top, LINES), past = first + height;
  let line = block_start(py);
  if (line < first && first < RG_SCREEN_HEIGHT) line = first;
  if (line >= past % LINES) line = past - 1;
  return floor_mod(line - first, LINES);
}

/* SpriteBlocks#paint_turned */
function paint_turned_in_blocks(placed) {
  const art = picture_of(placed.image);
  const width = art.width, height = art.height, one_th = rg_game_turn_rules[1];
  const [turn_cos, turn_sin] = affine_matrix(floor_mod(placed.angle, 360), placed.size);
  const left = placed.x - Math.trunc(width / 2), top = placed.y - Math.trunc(height / 2);
  const first_col = left > 0 ? left : 0;
  let past_col = block_end(left + width * 2);
  if (past_col > RG_SCREEN_WIDTH) past_col = RG_SCREEN_WIDTH;
  if (!turned_box_on_screen(top, width, height, placed.resizes)) return;
  for (let iy = 0; iy < height * 2; iy++) {
    const py = turned_box_line(top, iy);
    if (py < 0) continue;
    const dy = turned_row(py, top, height * 2) - height;
    for (let px = first_col; px < past_col; px++) {
      const start = block_start(px);
      const dx = (start >= left ? start : left - 1) - left - width;
      const color = picture_color(art, floor_div(turn_cos * dx + turn_sin * dy, one_th) + Math.trunc(width / 2),
        floor_div(-turn_sin * dx + turn_cos * dy, one_th) + Math.trunc(height / 2));
      if (color !== RG_NOT_DRAWN) set_pixel(px, py, color);
    }
  }
}

/* Reference#paint_snapshot_object */
function paint_kept_sprite(placed) {
  if (block === 1 || rg_game_sprite_blocks[placed.sprite] === RG_NOT_IN_BLOCKS) draw_placed(placed);
  else if (placed.turned) paint_turned_in_blocks(placed);
  else paint_upright_in_blocks(placed);
}

function rebuilt_whole() { return rg_game_picture_sizes[RG_SIZE_REBUILT_WHOLE]; }

/* Reference#scene_framebuffer */
function keep_scenery() {
  if (scenery_kept) return;
  const outer = area;
  area = { in_force: 0, left: 0, top: 0, right: 0, bottom: 0 };
  target = scenery;
  clear_to(0);
  for (let bg = 0; bg < rg_game_picture_sizes[RG_SIZE_BACKGROUNDS]; bg++) {
    if (showing(bg)) rg_background_stamp(bg);
  }
  target = pixels;
  area = outer;
  scenery_kept = 1;
}

function rg_screen_blit(image, x, y) { blit_image(image, x, y); }

function rg_screen_blit_pose(poses, count, pose, x, y) {
  if (pose >= 0 && pose < count) blit_image(poses[pose], x, y);
}

/* Reference#exec_draw_column_at */
function rg_screen_column(image, slice, x, top, height, width) {
  if (height <= 0) return;
  const art = picture_of(image);
  const column = clamp_number(slice, 0, art.width - 1);
  const step = Math.trunc((art.height * 65536) / height);
  const first = top < 0 ? -top : 0;
  const past = RG_SCREEN_HEIGHT - top < height ? RG_SCREEN_HEIGHT - top : height;
  for (let row = first; row < past; row++) {
    const source = clamp_number(Math.floor((row * step) / 65536), 0, art.height - 1);
    const color = art.pixels[art.start + source * art.width + column];
    if (color === RG_NOT_DRAWN) continue;
    for (let across = 0; across < width; across++) set_pixel(x + across, top + row, color);
  }
}

/* The start of Reference#exec_present_objects */
function rg_objects_begin() {
  drawing = [];
  if (!rebuilt_whole()) keep_scenery();
}

function fault_unless_sprite(sprite) {
  if (sprite < 0 || sprite >= RG_MAX_SPRITES) rg_fault(`sprite number ${sprite} is not one of the ${RG_MAX_SPRITES} there is room for`);
}

/* Framebuffer#put_back_cell */
function put_back_cell(x, y) {
  const at = y * RG_SCREEN_WIDTH + x;
  set_pixel(x, y, scenery[at]);
  const kept = mixes_of(target);
  if (!kept || !paintable(x, y) || !scenery_mixes.is_mixed[at]) return;
  kept.is_mixed[at] = 1;
  kept.tops[at] = scenery_mixes.tops[at];
  kept.unders[at] = scenery_mixes.unders[at];
}

/* Reference#restore_patch */
function restore_patch(left, top, width, height) {
  for (let row = 0; row < height; row++) {
    for (let col = 0; col < width; col++) {
      const x = left + col, y = top + row;
      if (on_screen(x, y)) put_back_cell(x, y);
    }
  }
}

function restore_turned_patch(left, top, width, height) {
  for (let row = 0; row < height; row++) {
    const line = turned_box_line(top, row);
    if (line >= 0) restore_patch(left, line, width, 1);
  }
}

/* Forgets where a sprite was last drawn straight onto the picture, and hands that place over;
 * null when it is not on the picture. */
function forget_drawn_place(sprite) {
  fault_unless_sprite(sprite);
  const place = last_drawn[sprite];
  if (!place.drawn) return null;
  place.drawn = 0;
  return place;
}

/* Reference#restore_scene_rect */
function rg_object_take_off(sprite, image) {
  const place = forget_drawn_place(sprite);
  if (!place) return;
  const art = picture_of(image);
  restore_patch(place.x, place.y, art.width, art.height);
}

/* Ruby's Integer.sqrt */
function whole_root(value) {
  let root = Math.floor(Math.sqrt(value));
  while (root * root > value) root--;
  while ((root + 1) * (root + 1) <= value) root++;
  return root;
}

function rg_object_take_off_turned(sprite, image, resizes) {
  const place = forget_drawn_place(sprite);
  if (!place) return;
  const art = picture_of(image);
  const width = art.width, height = art.height;
  const middle_x = place.x + Math.trunc(width / 2), middle_y = place.y + Math.trunc(height / 2);
  if (resizes) {
    restore_turned_patch(middle_x - width, middle_y - height, width * 2, height * 2);
    return;
  }
  const side = whole_root(width * width + height * height) + 2;
  restore_turned_patch(middle_x - Math.trunc(side / 2), middle_y - Math.trunc(side / 2), side, side);
}

function add_placed(placed) {
  fault_unless_sprite(placed.sprite);
  if (drawing.length >= RG_MAX_SPRITES) rg_fault(`more than ${RG_MAX_SPRITES} sprites on screen at once`);
  drawing.push(placed);
}

function rg_objects_add(sprite, image, x, y, level) {
  add_placed({ sprite, image, x, y, level, turned: 0, angle: 0, size: 0, resizes: 0 });
}

function rg_objects_add_turned(sprite, image, x, y, level, angle, size, resizes) {
  add_placed({ sprite, image, x, y, level, turned: 1, angle, size, resizes });
}

/* The rest of Reference#exec_present_objects */
function rg_objects_end() {
  sprite_layer = drawing.slice();
  if (rebuilt_whole()) {
    request_repaint();
    return;
  }
  for (const placed of drawing) {
    mix_as_sprite(placed.sprite);
    draw_placed(placed);
    mix_nothing();
    const place = last_drawn[placed.sprite];
    place.drawn = 1;
    place.x = placed.x;
    place.y = placed.y;
  }
}

/* Reference#sprites: what the game last said is on screen. */
function rg_screen_drawn_count() { return drawing.length; }

function rg_screen_drawn_sprite(place) {
  const placed = drawing[place];
  return { name: rg_game_sprite_names[placed.sprite], picture: rg_game_image_pictures[placed.image], x: placed.x, y: placed.y };
}

const NO_PLACE = -1;
function place_named(said, count) {
  const place = said < 0 ? said + count : said;
  return place >= 0 && place < count ? place : NO_PLACE;
}

/* Reference#names_in_draw_order */
function rg_place_in_ordered_run(said, count) {
  const place = place_named(said, count);
  if (place === NO_PLACE) rg_fault(`a draw order names sprite ${said} of the ${count} it puts in order`);
  return place;
}

/* Reference#collision_sprite */
function rg_pose_image(poses, count, pose) {
  const place = place_named(pose, count);
  if (place === NO_PLACE) rg_fault(`a sprite is showing picture ${pose} of its ${count}`);
  return poses[place];
}

/* Reference#pixels_overlap? */
function rg_pixels_overlap(a_image, a_x, a_y, b_image, b_x, b_y) {
  const a = picture_of(a_image), b = picture_of(b_image);
  const left = a_x > b_x ? a_x : b_x, top = a_y > b_y ? a_y : b_y;
  const a_right = a_x + a.width, b_right = b_x + b.width;
  const a_bottom = a_y + a.height, b_bottom = b_y + b.height;
  const right = a_right < b_right ? a_right : b_right, bottom = a_bottom < b_bottom ? a_bottom : b_bottom;
  for (let y = top; y < bottom; y++) {
    for (let x = left; x < right; x++) {
      if (a.pixels[a.start + (y - a_y) * a.width + (x - a_x)] !== RG_NOT_DRAWN &&
          b.pixels[b.start + (y - b_y) * b.width + (x - b_x)] !== RG_NOT_DRAWN) return 1;
    }
  }
  return 0;
}

/* --- the whole view, rebuilt (Reference#repaint_view) --- */

function fade_unless_left_as_drawn(fade_place) {
  const under = placed_fade.layer_place;
  const left_as_drawn = under !== RG_NO_LAYER && fade_place !== RG_NO_LAYER && fade_place >= under;
  fading_what_is_painted = placed_fade.in_force && !left_as_drawn ? 1 : 0;
}

function fade_nothing() { fading_what_is_painted = 0; }

function repaint_view() {
  mix_nothing();
  fade_unless_left_as_drawn(RG_NO_LAYER);
  clear_to(0);
  const backgrounds = rg_game_picture_sizes[RG_SIZE_BACKGROUNDS], levels = rg_game_picture_sizes[RG_SIZE_DEPTHS];
  for (let level = 0; level < levels; level++) {
    for (let bg = 0; bg < backgrounds; bg++) {
      if (!showing(bg) || background_field(bg, RG_BG_LEVEL) !== level) continue;
      mix_as_layer(background_field(bg, RG_BG_SEE_THROUGH));
      fade_unless_left_as_drawn(background_field(bg, RG_BG_FADE_PLACE));
      paint_scenery(bg);
    }
    for (const placed of sprite_layer) {
      if (placed.level !== level) continue;
      mix_as_sprite(placed.sprite);
      fade_unless_left_as_drawn(rg_game_sprite_fade_places[placed.sprite]);
      paint_kept_sprite(placed);
    }
  }
  mix_nothing();
  fade_nothing();
}

/* Reference#paint_owed_repaint */
function rg_screen_paint_owed_rebuild() {
  if (!owed) {
    forget_expired_corners();
    return;
  }
  owed = 0;
  repaint_view();
  forget_kept_shares();
  forget_expired_corners();
}

/* --- screens and scenes --- */

function rg_screen_hold(value) { held = value; }

function rg_screen_frame_started() {
  held = 0;
  frames_begun = 1;
}

/* The top of Reference#advance_frame: the corners of the backgrounds this pass put up go once its
 * picture is painted (Reference#forget_expired_corners), and a tear-free screen trades its pages. */
function rg_screen_frame_ended() {
  if (any_from_corner) corners_expired = 1;
  if (pixels === viewed) return;
  rg_screen_paint_owed_rebuild();
  const finished = pixels;
  pixels = viewed;
  viewed = finished;
  target = pixels;
}

/* Reference#exec_screen */
function rg_screen_set(new_kind, two_pages) {
  const crossing = kind >= 0 && kind !== new_kind;
  if (crossing) {
    clear_to(0);
    shown_backgrounds = [];
    scenery_kept = 0;
  }
  kind = new_kind;
  show_pages(two_pages);
  tint_by_display = tint_mixed_by_display();
  read_block = painted_screen() ? block : 1;
  if (!crossing || new_kind === RG_BITMAP) return 0;
  for (let i = 0; i < rg_game_picture_sizes[RG_SIZE_ALWAYS_UP]; i++) {
    forget_own_cells(rg_game_always_up[i]);
    rg_background_put_up(rg_game_always_up[i]);
  }
  return 1;
}

/* Reference#cross_to_scene_screen */
function rg_screen_cross_to(new_kind, two_pages) {
  return kind >= 0 && kind !== new_kind ? rg_screen_set(new_kind, two_pages) : 0;
}

function rg_scene_enter(scene) { current_scene = scene; }

/* The middle of Reference#take_over, and #take_down_scenery */
function rg_scene_take_down(brings_scenery) {
  let any_scene_owned = false;
  for (const entry of shown_backgrounds) {
    if (background_field(entry, RG_BG_SCENE) !== RG_EVERY_SCENE) any_scene_owned = true;
  }
  if (!any_scene_owned && !brings_scenery) return;

  rg_screen_paint_owed_rebuild();
  const kept = shown_backgrounds.filter((entry) => !background_field(entry, RG_BG_ON_ARRIVAL));
  if (kept.length === shown_backgrounds.length) return;

  shown_backgrounds = kept;
  scenery_kept = 0;
  clear_to(0);
  stamp_in_stack_order(-1);
}

/* Reference#redraw_sprites_over_arrived_scenery */
function rg_scene_redraw_sprites() {
  if (painted_screen() || sprite_layer.length === 0) return;
  request_repaint();
}

/* --- reading it back --- */

function rg_screen_two_pages() { return pixels !== viewed ? 1 : 0; }

/* Framebuffer#to_a */
function rg_screen_stored() {
  rg_screen_paint_owed_rebuild();
  return viewed;
}

/* Framebuffer#block_corner */
function block_corner_across(x) {
  const first = camera_x < 0 ? -camera_x : 0;
  return x >= first ? first + Math.trunc((x - first) / read_block) * read_block : x;
}

/* --- a light (Framebuffer#shade_outside) --- */

const shade_spans = new Int32Array(RG_SCREEN_HEIGHT * 2);
let shade_steps = 0;
let shade_row = 0;

function rg_shade_line() { return shade_row; }
function rg_shade_left(left) { shade_spans[shade_row * 2] = left; }
function rg_shade_right(right) { shade_spans[shade_row * 2 + 1] = right; }
function rg_shade_darkness(amount) { shade_steps = whole_sixteenths(amount); }

/* Reference#work_out_shade */
function rg_screen_work_out_shade() {
  for (shade_row = 0; shade_row < RG_SCREEN_HEIGHT; shade_row++) rg_game_shade_span();
  rg_game_shade_amount();
}

/* Framebuffer#light_off= (rg_screen.c) */
let shade_off = false;
function rg_shade_switch(on) { shade_off = on === 0; }

/* Framebuffer#lit? */
function lit(x, y) {
  if (shade_steps === 0 || shade_off) return true;
  const left = shade_spans[y * 2], right = shade_spans[y * 2 + 1];
  return left <= right ? x >= left && x < right : x >= left || x < right;
}

/* Framebuffer#shown and #pixel */
function rg_screen_shown() {
  rg_screen_paint_owed_rebuild();
  for (let y = 0; y < RG_SCREEN_HEIGHT; y++) {
    for (let x = 0; x < RG_SCREEN_WIDTH; x++) {
      const from_x = block_corner_across(x) + camera_x, from_y = y - (y % read_block) + camera_y;
      const at = from_y * RG_SCREEN_WIDTH + from_x;
      const fade_here = fade_reaches(x, y);
      const color = on_screen(from_x, from_y) ? shown_color(at, viewed[at], fade_here) : faded_where(0, fade_here);
      shown[y * RG_SCREEN_WIDTH + x] = held ? 0x7FFF : lit(x, y) ? color : darkened_by_display(color, shade_steps);
    }
  }
  return shown;
}
