/*
 * The game's picture, drawn in software: the console's 240x160 screen as an array of colors,
 * and everything the game does to it.
 *
 * It is a port of the interpreter's own picture (backends/reference.rb and
 * reference/framebuffer.rb), method for method, because the interpreter is what a desktop build
 * is checked against pixel for pixel. That includes the parts that look like bookkeeping — when
 * the whole view is rebuilt, which scenery is up, what a scene takes down as it arrives — since
 * each of them decides what a pixel holds on some frame.
 *
 * A color is the console's: fifteen bits, five each of red, green and blue, red lowest. A
 * picture's pixel can carry a sixteenth bit, the one that marks a see-through pixel in the art;
 * it is kept as it is, the way the interpreter keeps it, and only a blend drops it.
 *
 * The art comes from the generated game (game.c), as the arrays declared at the bottom.
 */
#ifndef RG_SCREEN_H
#define RG_SCREEN_H

#include <stdint.h>

#define RG_SCREEN_WIDTH 240
#define RG_SCREEN_HEIGHT 160

/* The kinds of screen a `screen` can name. Two of the same kind share a display; changing kind
 * replaces the whole display (see IR::SceneHandover). */
enum { RG_BITMAP = 0, RG_TILED = 1, RG_ROTOZOOM = 2 };

/* --- what the generated game calls --- */

void rg_screen_hold(int32_t held);              /* switched off until the first frame is set up */
void rg_screen_set(int32_t kind);               /* a `screen` statement */
void rg_screen_cross_to(int32_t kind);          /* a scene arriving on the screen it draws on */
void rg_screen_paint_owed_rebuild(void);        /* rebuild the whole view, if a rebuild is owed */

void rg_screen_clear(int32_t color);
void rg_screen_fill_rect(int32_t x, int32_t y, int32_t width, int32_t height, int32_t color);
void rg_screen_pixel(int32_t x, int32_t y, int32_t color);
/* Points worked out when the game was built — the pixels of a line of text — as (dx, dy)
 * pairs, painted from (x, y). */
void rg_screen_points(int32_t x, int32_t y, int32_t color, const int16_t *points, int32_t count);
/* One digit of a live number: +starts+ says where each of the ten digits' points begin in
 * +points+ (eleven entries). A value outside 0..9 draws nothing. */
void rg_screen_digit(int32_t value, int32_t x, int32_t y, int32_t color, const int16_t *points,
                     const int32_t *starts);

void rg_background_stamp(int32_t background);
void rg_background_put_up(int32_t background);
/* +pivot_x+, +pivot_y+: the point on screen it turns around, which the statement says. */
void rg_background_turn(int32_t background, int32_t angle, int32_t size, int32_t pivot_x, int32_t pivot_y);

/* A scene taking over: remembered, then its screen, then what comes down. */
void rg_scene_enter(int32_t scene);
void rg_scene_take_down(int32_t brings_scenery);

/* The sprites on screen this frame, said between begin and end. Each sprite has a number of its
 * own, the same every frame. First every sprite the frame draws is taken off, shown or not
 * (rg_object_take_off, with one of its pictures for its size); then each one that is shown is
 * added, back to front.
 *
 * What the end does with them is the game's, settled when it was built (rg_game_picture_sizes):
 * a game whose scenery moves, turns or sits in front of a sprite has its whole view rebuilt from
 * its layers, and taking a sprite off does nothing. Any other game keeps its scenery as it is and
 * draws the sprites straight onto it, so taking one off puts back the scenery it was covering. */
void rg_objects_begin(void);
void rg_object_take_off(int32_t sprite, int32_t image);
void rg_objects_add(int32_t sprite, int32_t image, int32_t x, int32_t y, int32_t level);
void rg_objects_end(void);

/* Which of a sprite's pictures it is showing: number +pose+ of +count+. A number outside them is
 * a fault, as it is in the interpreter. */
int32_t rg_pose_image(const int32_t *poses, int32_t count, int32_t pose);

/* Do two sprites' DRAWN pixels touch — one that is not see-through in each, on the same spot? */
int32_t rg_pixels_overlap(int32_t a_image, int32_t a_x, int32_t a_y, int32_t b_image, int32_t b_x, int32_t b_y);

/* A sprite told to draw with list number +which+ of the +lists+ of colors it was given shows
 * that list's row of its pictures, which come after its own row; a number naming none of them
 * shows its own. */
static inline int32_t rg_colors_row(int32_t which, int32_t lists) { return which >= 0 && which < lists ? which + 1 : 0; }

/* A fade toward black (0) or white (1), in sixteenths of the display or, when +walked+, in
 * thirty-seconds of a walk through the colors (see Backends::FadeSteps). */
void rg_screen_fade(int32_t toward_white, int32_t steps, int32_t walked);
/* A tint toward +color+, in thirty-seconds. */
void rg_screen_tint(int32_t color, int32_t steps);
/* How far +amount+ (a percentage, or with +fraction_bits+ >= 0 a fraction of one) is, in steps. */
int32_t rg_fade_steps(int32_t amount, int32_t fraction_bits, int32_t walked);

/* Two colors for a line of text, and the test that says which. */
static inline int32_t rg_pick_color(int32_t showing, int32_t color, int32_t picked) {
  return showing != 0 ? picked : color;
}

/* --- what the runtimes call --- */

/* The frame boundary's part in the picture: it is switched on from here. */
void rg_screen_frame_started(void);

/* The picture as it is SHOWN, rebuilt first if a rebuild is owed: RG_SCREEN_WIDTH times
 * RG_SCREEN_HEIGHT colors, row by row, with the fade or tint in force mixed in. */
const uint16_t *rg_screen_shown(void);

/* --- the art, from the generated game --- */

/* Sprite pictures: each image is three numbers in rg_game_images (where its pixels start in
 * rg_game_image_pixels, its width and its height). A pixel is the sixteen bits the picture
 * stores, or RG_NOT_DRAWN where what is behind shows. A sprite drawn with another list of colors
 * has a picture of its own for each list, made when the game is built. */
#define RG_NOT_DRAWN (-1)
extern const int32_t rg_game_image_pixels[];
extern const int32_t rg_game_images[];
#define RG_IMAGE_FIELDS 3
/* The most sprites a game may have; the build refuses more. */
#define RG_MAX_SPRITES 512

/* Background tiles, as colors, with RG_SEE_THROUGH where the layer behind shows. No color is that
 * number, since a tile's color is fifteen bits. */
#define RG_SEE_THROUGH 0xFFFFu
extern const uint16_t rg_game_tile_pixels[];

/* Each background is RG_BG_FIELDS numbers in rg_game_backgrounds, in the order the stack draws
 * them; its map's cells are in rg_game_map_cells, -1 for an empty cell. Its scene is the number
 * the game counts that scene by, RG_EVERY_SCENE for scenery every screen shows, or
 * RG_NEVER_ARRIVES for a scene nothing hands the screen over to (so never shown). Its place in
 * the stack is how far forward the layer it named is among the layers the game declared, or
 * RG_NO_LAYER for one that named none. */
#define RG_EVERY_SCENE (-1)
#define RG_NEVER_ARRIVES (-2)
#define RG_NO_LAYER (-1)
/* The most backgrounds a game may have; the build refuses more. */
#define RG_MAX_BACKGROUNDS 64
enum {
  RG_BG_TILE_W, RG_BG_TILE_H, RG_BG_MAP_COLS, RG_BG_MAP_ROWS, RG_BG_GRID_COLS, RG_BG_GRID_ROWS,
  RG_BG_MAP_START, RG_BG_TILES_START, RG_BG_SCENE, RG_BG_LEVEL, RG_BG_ON_ARRIVAL, RG_BG_STACK_PLACE,
  RG_BG_FIELDS
};
extern const int32_t rg_game_backgrounds[];
extern const int16_t rg_game_map_cells[];

/* [how many backgrounds, how many depths the picture is built at, how many backgrounds every
 * screen drawn from tiles shows, 1 for a game whose whole view is rebuilt from its layers] */
enum { RG_SIZE_BACKGROUNDS, RG_SIZE_DEPTHS, RG_SIZE_ALWAYS_UP, RG_SIZE_REBUILT_WHOLE };
extern const int32_t rg_game_picture_sizes[];
extern const int32_t rg_game_always_up[];

/* sin(d) in 256ths for d = 0..449, the table every backend turns a picture by (IR::Affine), and
 * the four numbers that turn it into a matrix: what a size of 1.0 is (Build::SCALE_ONE), what
 * the matrix calls 1.0 (Affine::ONE_TH), the largest number it holds (Affine::MAX) and the
 * smallest size (Affine::MIN_SCALE). */
extern const int32_t rg_game_sines[];
extern const int32_t rg_game_turn_rules[];

#endif
