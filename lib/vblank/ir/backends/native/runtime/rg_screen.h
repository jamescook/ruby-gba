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
#include "rg_list.h"

#include "rg_console.h"

/* The kinds of screen a `screen` can name. Two of the same kind share a display; changing kind
 * replaces the whole display (see IR::SceneHandover). */
enum { RG_BITMAP = 0, RG_TILED = 1, RG_ROTOZOOM = 2 };

/* --- what the generated game calls --- */

void rg_screen_hold(int32_t held);              /* switched off until the first frame is set up */
/* A `screen` statement. +two_pages+ is 1 for a tear-free screen: two pictures, the one being
 * drawn and the one being shown, traded between frames.
 *
 * Both answer 1 when the scenery every screen drawn from tiles shows was put up again, as
 * declared, because a screen of another kind had replaced the display. The game then puts what
 * says which map each of those backgrounds shows back to the first. */
/* +backdrop+ is the colour shown wherever nothing is drawn (IR::SceneHandover#backdrop_of). */
int32_t rg_screen_set(int32_t kind, int32_t two_pages, int32_t backdrop);
int32_t rg_screen_cross_to(int32_t kind, int32_t two_pages, int32_t backdrop); /* a scene arriving on the screen it draws on */
void rg_screen_paint_owed_rebuild(void);        /* rebuild the whole view, if a rebuild is owed */

void rg_screen_clear(int32_t color);
void rg_screen_fill_rect(int32_t x, int32_t y, int32_t width, int32_t height, int32_t color);
void rg_screen_pixel(int32_t x, int32_t y, int32_t color);

/* Everything drawn between these two stays inside that part of the screen; what falls outside
 * is not drawn. The area in force before comes back at the end. */
void rg_screen_inside(int32_t x, int32_t y, int32_t width, int32_t height);
void rg_screen_inside_ended(void);

/* Move the window onto the picture: screen (0, 0) shows what was drawn at (x, y). Where the
 * window is now, which a test reads back as the interpreter's camera_x and camera_y. */
void rg_screen_camera(int32_t x, int32_t y);
int32_t rg_screen_camera_x(void);
int32_t rg_screen_camera_y(void);

/* A picture painted into the picture with its top left at (x, y); and one of +count+ pictures,
 * picked by +pose+, where a number naming none paints nothing. */
void rg_screen_blit(int32_t image, int32_t x, int32_t y);
void rg_screen_blit_pose(const int32_t *poses, int32_t count, int32_t pose, int32_t x, int32_t y);

/* Column +slice+ of a picture, stretched to +height+ rows from +top+ and painted +width+ pixels
 * across from +x+. */
void rg_screen_column(int32_t image, int32_t slice, int32_t x, int32_t top, int32_t height, int32_t width);

/* The patch of the picture a sprite on a painted screen is about to cover, +width+ by +height+
 * at (x, y), kept in buffer number +buffer+; and that patch painted back. */
void rg_patch_save(int32_t buffer, int32_t width, int32_t height, int32_t x, int32_t y);
void rg_patch_restore(int32_t buffer, int32_t width, int32_t height, int32_t x, int32_t y);
/* Points worked out when the game was built — the pixels of a line of text — as (dx, dy)
 * pairs, painted from (x, y). */
void rg_screen_points(int32_t x, int32_t y, int32_t color, const int16_t *points, int32_t count);
/* One digit of a live number: +starts+ says where each of the ten digits' points begin in
 * +points+ (eleven entries). A value outside 0..9 draws nothing. */
void rg_screen_digit(int32_t value, int32_t x, int32_t y, int32_t color, const int16_t *points,
                     const int32_t *starts);

void rg_background_stamp(int32_t background);
void rg_background_put_up(int32_t background);
/* The start of Reference#take_over: a background coming up as a scene takes over goes up as
 * declared, so the cells the game changed of its name are forgotten before anything is painted. */
void rg_background_forget_cells(int32_t background);
/* Put a background's window at (x, y) of its map, in pixels: the picture slides. Whether it comes
 * round again is the background's (RG_BG_NEVER_WRAPS, below). */
void rg_background_scroll(int32_t background, int32_t x, int32_t y);
/* Reference#exec_place_bar: a status bar's top at a row of the screen. */
void rg_place_bar(int32_t background, int32_t top);
/* Reference#exec_in_loop: while +on+, a scroll or a bar's top is the end of a pass placing the
 * frame's writes, and a background that pass put up still shows from its corner. */
void rg_screen_placing_at_pass_end(int32_t on);
/* One cell becomes tile number +tile+ of the background's tiles. A cell the map does not have is
 * left alone. */
void rg_background_set_tile(int32_t background, int32_t col, int32_t row, int32_t tile);
/* Every cell becomes map number +which+ of the background's maps, as it was declared. A number
 * naming none of them leaves the cells alone. */
void rg_background_show_map(int32_t background, int32_t which);
/* Every tile of the background is drawn from now on with step number +which+ of the lists of
 * colors it can be told (RG_BG_COLOR_STEPS of them). A number naming none of them is the colors
 * it was drawn in. */
void rg_background_draw_with(int32_t background, int32_t which);
/* +pivot_x+, +pivot_y+: the point on screen it turns around, which the statement says. */
void rg_background_turn(int32_t background, int32_t angle, int32_t size, int32_t pivot_x, int32_t pivot_y);

/* A BENT BACKGROUND has every line of the screen at its own distance across, on top of where the
 * background is scrolled to (RG_BG_BENT, below). How far is the game's to work out, once a pass
 * for every line, in the gap between frames (Reference#work_out_bends): rg_screen_work_out_bends
 * calls rg_game_work_out_bends there, which hands each bend's lines to rg_bend_work_out in the
 * console's order, and the picture reads what was worked out however often it is painted. For
 * each line rg_bend_work_out calls rg_game_bend_offsets with one background and one line of the
 * screen in mind, and the game answers for the background asked about, after running whatever its
 * block says to run first:
 *
 *   if (rg_bend_asked(2)) { row = rg_bend_line(); ...; rg_bend_answer(offset); }
 *
 * The block may change the game's variables, so it runs exactly as often as the interpreter runs
 * it: 160 times a pass. Before the first gap every line sits flat, as on the console. Where a
 * bend is written, the game asks for the picture to be built again with
 * rg_screen_request_rebuild. */
void rg_screen_request_rebuild(void);
void rg_screen_work_out_bends(void);
void rg_bend_work_out(int32_t background, int32_t first_line, int32_t past_line);
int32_t rg_bend_asked(int32_t background);
int32_t rg_bend_line(void);
void rg_bend_answer(int32_t offset);
void rg_game_bend_offsets(void);
void rg_game_work_out_bends(void);

/* A LIGHT darkens the picture everywhere outside one span of each row, as it is shown
 * (Reference#work_out_shade, Framebuffer#shade_outside). In the gap between frames,
 * rg_screen_work_out_shade asks the game where each row's span is, by calling rg_game_shade_span
 * with one row of the screen in mind, and then how dark the rest goes, by calling
 * rg_game_shade_amount:
 *
 *   row = rg_shade_line(); rg_shade_left(left); rg_shade_right(right);    rg_shade_darkness(amount);
 *
 * The span runs from left up to but not including right; a left past its right comes round the
 * edge of the screen. The amount is out of 100.
 *
 * A game whose light takes turns with the scenes it is off in calls rg_shade_switch as each frame
 * ends, before it is shown, with whether the scene that just ran has it on (1) or off (0): off
 * darkens nothing from that picture on, and on waits for the light worked out after it. */
void rg_screen_work_out_shade(void);
int32_t rg_shade_line(void);
void rg_shade_left(int32_t left);
void rg_shade_right(int32_t right);
void rg_shade_darkness(int32_t amount);
void rg_shade_switch(int32_t on);
void rg_game_shade_span(void);
void rg_game_shade_amount(void);

/* A scene taking over: remembered, then its screen, then what comes down, and once its scenery is
 * up — or the last scene's is down — the sprites of this frame back over it. */
void rg_scene_enter(int32_t scene);
void rg_scene_take_down(int32_t brings_scenery);
void rg_scene_redraw_sprites(int32_t brings_scenery);

/* The sprites on screen this frame, said between begin and end. Each sprite has a number of its
 * own, the same every frame. First every sprite the frame draws is taken off, shown or not
 * (rg_object_take_off, with one of its pictures for its size); then each one that is shown is
 * added, back to front.
 *
 * What the end does with them is the game's, settled when it was built (rg_game_picture_sizes):
 * a game whose scenery moves, turns or sits in front of a sprite has its whole view rebuilt from
 * its layers, and taking a sprite off does nothing. Any other game keeps its scenery as it is and
 * draws the sprites straight onto it, so taking one off puts back the scenery it was covering.
 *
 * A sprite that turns or resizes is said with the two _turned ones: +angle+ in degrees clockwise
 * from upright, +size+ counted as the game counts a size (rg_game_turn_rules says what 1.0 is),
 * both about the middle of its picture. Taking one off puts back every pixel it could have
 * covered: the whole box the display gives it when it +resizes+, and a square as wide as its
 * own diagonal when it only turns. Adding one says +resizes+ too, because the rows of that box a
 * picture that only turns can reach decide whether it is on the screen at all. */
void rg_objects_begin(void);
void rg_object_take_off(int32_t sprite, int32_t image);
void rg_object_take_off_turned(int32_t sprite, int32_t image, int32_t resizes);
void rg_objects_add(int32_t sprite, int32_t image, int32_t x, int32_t y, int32_t level);
void rg_objects_add_turned(int32_t sprite, int32_t image, int32_t x, int32_t y, int32_t level, int32_t angle,
                           int32_t size, int32_t resizes);
void rg_objects_end(void);

/* Which sprite of a run the game puts in order is drawn next: the one the number +said+ names of
 * the run's +count+, as the list the game keeps the order in holds it, read as the interpreter
 * reads it. A number below nought counts back from the last, and one that still names none is a
 * fault. */
int32_t rg_place_in_ordered_run(int32_t said, int32_t count);

/* Which of a sprite's pictures it is showing, for a collision: number +pose+ of +count+, read as
 * the interpreter reads it. A number below nought counts back from the last, and one that still
 * names none is a fault. */
int32_t rg_pose_image(const int32_t *poses, int32_t count, int32_t pose);

/* Do two sprites' DRAWN pixels touch — one that is not see-through in each, on the same spot? */
int32_t rg_pixels_overlap(int32_t a_image, int32_t a_x, int32_t a_y, int32_t b_image, int32_t b_x, int32_t b_y);

/* Where choice number +which+ is in a row that holds a sprite's own first and then +others+ more:
 * the lists of colors it can be drawn with, or the layers it can be put in. A number naming none
 * of the others is its own. */
static inline int32_t rg_place_of_choice(int32_t which, int32_t others) { return which >= 0 && which < others ? which + 1 : 0; }

/* TILES AND PICTURES THE GAME PAINTS FROM A LIST (a run: see rg_game_tile_runs). A run takes what
 * its list holds now: tile k is the 32 bytes from k × 32, each byte two pixels with the left one
 * in the low four bits, each four bits a place in the run's colors, and place 0 see-through. A
 * slot the game never filled reads as 0. Until its first copy a run shows nothing at all.
 * Nothing is rebuilt here; the game asks for that itself where the interpreter does. */
void rg_tiles_copy(int32_t run, const rg_list *list);

/* A SEE-THROUGH LAYER is mixed with what is behind it as the picture is painted: so much of the
 * layer, so much of what is already there (IR::SeeThrough). How much is two amounts the game
 * may work out as it runs, so the picture asks the game for them when it needs them, by calling
 * rg_game_see_through_amounts with one layer in mind. The game answers for the layer that is
 * asked about:
 *
 *   if (rg_see_through_asked(0)) rg_see_through_answer(shows, behind);
 *
 * rg_see_through_told is the game saying, before a frame is drawn, that a layer's amounts have
 * been worked out again: the picture is rebuilt when they come to other sixteenths than the
 * ones last told. */
void rg_see_through_told(int32_t layer);
int32_t rg_see_through_asked(int32_t layer);
void rg_see_through_answer(int32_t shows, int32_t behind);
void rg_game_see_through_amounts(void);

/* A fade toward black (0) or white (1), in sixteenths of the display or, when +walked+, in
 * thirty-seconds of a walk through the colors (see Backends::FadeSteps). */
void rg_screen_fade(int32_t toward_white, int32_t steps, int32_t walked);
/* The same fade PLACED IN THE STACK: what is behind the layer it names fades, and that layer and
 * everything in front of it are left as drawn. +layer_place+ is how far forward that layer is
 * among the layers the game declared, or RG_NO_LAYER when it is none of them, and then
 * everything fades. Each thing says how far forward such a layer can be and still leave it as
 * drawn (RG_BG_FADE_PLACE, rg_game_sprite_fade_places). */
void rg_screen_fade_under(int32_t layer_place, int32_t toward_white, int32_t steps, int32_t walked);
/* The same fade HELD TO A RECTANGLE: inside it (+reaches+ RG_FADE_INSIDE) or everywhere but it
 * (RG_FADE_OUTSIDE), the rest of the screen as drawn. The rectangle is +left+, +top+, +right+
 * and +bottom+ in screen pixels, the right and bottom one past the last pixel. Always the
 * display's own fade, in sixteenths (see IR::Fading). */
#define RG_FADE_WHOLE_SCREEN 0
#define RG_FADE_INSIDE 1
#define RG_FADE_OUTSIDE 2
void rg_screen_fade_in_area(int32_t reaches, int32_t left, int32_t top, int32_t right, int32_t bottom,
                            int32_t toward_white, int32_t steps);
/* A tint toward +color+, in thirty-seconds. On the plain bitmap screen the display mixes it in as
 * it draws, at eight bits a channel; on every other screen the game writes the tinted colors
 * itself. That follows the screen up, so a tint kept across a change of screen changes with it. */
void rg_screen_tint(int32_t color, int32_t steps);
/* How far +amount+ (a percentage, or with +fraction_bits+ >= 0 a fraction of one) is, in steps. */
int32_t rg_fade_steps(int32_t amount, int32_t fraction_bits, int32_t walked);

/* The picture shown in flat blocks of +size+ pixels each way from now on, 1 being the picture as
 * drawn; a size past either end of the sizes there are stops at that end. Nothing drawn changes.
 * The blocks are fixed to the screen, one starting at every column and row that is a multiple of
 * the size, and each shows the color at its top left corner. Which things go into blocks was
 * settled when the game was built (RG_BG_IN_BLOCKS, rg_game_sprite_blocks). */
void rg_screen_pixelate(int32_t size);

/* Two colors for a line of text, and the test that says which. */
static inline int32_t rg_pick_color(int32_t showing, int32_t color, int32_t picked) {
  return showing != 0 ? picked : color;
}

/* --- what the runtimes call --- */

/* The frame boundary's two parts in the picture. As a frame ends, a tear-free screen trades its
 * pages, before anything that can stop the run there. As the next begins, the picture is
 * switched on. */
void rg_screen_frame_ended(void);
void rg_screen_frame_started(void);

/* The picture as it is SHOWN, rebuilt first if a rebuild is owed: RG_SCREEN_WIDTH times
 * RG_SCREEN_HEIGHT colors, row by row, with the fade or tint in force mixed in. */
const uint16_t *rg_screen_shown(void);

/* The same page as it is STORED: no window moved over it, no fade or tint. What a test counts
 * drawn pixels in; a player never sees it. */
const uint16_t *rg_screen_stored(void);

/* 1 while the screen is tear-free, and so two pages. */
int32_t rg_screen_two_pages(void);

/* The sprites the game last said are on screen (Reference#sprites), back to front: how many, and
 * each by its place among them. A row says whose the sprite is and which picture it shows, both
 * as the number of a name (rg_game_sprite_names, rg_game_image_pictures), and where it is. They
 * stand until the game next says its sprites, however many frames that is. */
typedef struct { int32_t name, picture, x, y; } rg_drawn_sprite;
int32_t rg_screen_drawn_count(void);
rg_drawn_sprite rg_screen_drawn_sprite(int32_t place);

/* --- the art, from the generated game --- */

/* Sprite pictures: each image is three numbers in rg_game_images (where its pixels start in
 * rg_game_image_pixels, its width and its height). A pixel is the fifteen bits of colour the
 * picture stores, or RG_NOT_DRAWN where what is behind shows, so sixteen signed bits hold every
 * one. A sprite drawn with another list of colors has a picture of its own for each list, made
 * when the game is built. */
#define RG_NOT_DRAWN (-1)
extern const int16_t rg_game_image_pixels[];
extern const int32_t rg_game_images[];
#define RG_IMAGE_FIELDS 3
/* The most sprites a game may have; the build refuses more. */
#define RG_MAX_SPRITES 512
/* For each sprite, by its number: which see-through layer it was declared in, counting through
 * rg_game_see_through, or RG_SOLID. */
#define RG_SOLID (-1)
extern const int32_t rg_game_sprite_see_through[];
/* For each sprite, by its number: the furthest forward a placed fade's layer can be and still
 * leave it as drawn, as RG_BG_FADE_PLACE says for a background. */
extern const int32_t rg_game_sprite_fade_places[];
/* What a run says a sprite it drew by. For each sprite, by its number: the number of the name the
 * game declared it under, or RG_NO_NAME for one it named nothing for, such as a letter of text.
 * And for each image, by its number: the number of the name the author gave the picture, the
 * same whatever colors the image is that picture in. */
#define RG_NO_NAME (-1)
extern const int32_t rg_game_sprite_names[];
extern const int32_t rg_game_image_pictures[];
/* A SPRITE IN BLOCKS is put into them a box at a time, and the boxes are the ones a console
 * draws it as: a pose trimmed to what it draws, a big picture cut into pieces (Backends::SpriteCut,
 * which the build asks). For each sprite, by its number, rg_game_sprite_blocks is RG_NOT_IN_BLOCKS
 * for one the game leaves as drawn whatever the size, or where its boxes start in
 * rg_game_sprite_boxes. There: how many pictures it can show, and for each the number of the
 * picture's name (as rg_game_image_pictures has it), how many boxes it is drawn as, and each box
 * as its left, top, width and height inside the picture, the one in front first. A sprite that
 * turns or resizes is put into blocks whole and has no pictures listed. */
#define RG_NOT_IN_BLOCKS (-1)
extern const int32_t rg_game_sprite_blocks[];
extern const int32_t rg_game_sprite_boxes[];

/* Each layer the game can be seen through is RG_ST_FIELDS numbers in rg_game_see_through: 1 when
 * both its amounts are numbers written in the program, 1 when it was given one amount (how much
 * of what is behind shows, the layer taking the rest of a whole) rather than two, and 1 when any
 * sprite was declared in it. */
enum { RG_ST_AMOUNTS_WRITTEN, RG_ST_ONE_AMOUNT, RG_ST_HOLDS_A_SPRITE, RG_ST_FIELDS };
extern const int32_t rg_game_see_through[];
/* The most see-through layers a game may have; the build refuses more. */
#define RG_MAX_SEE_THROUGH 16

/* Background tiles, as colors, with RG_SEE_THROUGH where the layer behind shows. No color is that
 * number, since a tile's color is fifteen bits. */
#define RG_SEE_THROUGH 0xFFFFu
extern const uint16_t rg_game_tile_pixels[];

/* Each background is RG_BG_FIELDS numbers in rg_game_backgrounds, in the order the stack draws
 * them. Its scene is the number the game counts that scene by, RG_EVERY_SCENE for scenery every
 * screen shows, or RG_NEVER_ARRIVES for a scene nothing hands the screen over to (so never
 * shown). Its place in the stack is how far forward the layer it named is among the layers the
 * game declared, or RG_NO_LAYER for one that named none.
 *
 * Its maps are entries of rg_game_maps from RG_BG_FIRST_MAP on, the first being the one it shows
 * when the game starts. RG_BG_SHOWABLE_MAPS is how many of them it can be handed while the game
 * runs, which is none for a background declared with one map.
 *
 * A background scrolls over the grid of the map it shows (RG_MAP_GRID_COLS by RG_MAP_GRID_ROWS
 * cells) and its picture comes round again at that grid's edge, unless RG_BG_NEVER_WRAPS is 1:
 * one with a map too big for any grid, or with maps of different sizes, shows nothing past the
 * edge of its map (IR::TileMap).
 *
 * Two scenes may each declare a background by the same name. Each is an entry here with its own
 * maps, and they share what the game does to the name, as the interpreter keeps that by name:
 * the scroll, the turn, the colors it is told, and the run's own copy of the cells. RG_BG_KEPT_BY
 * is the entry that keeps those for the name: the last one the program declares, wherever the
 * stack puts it, and the one every statement naming the background reaches. Its see-through
 * layer is also the one RG_BG_SEE_THROUGH gives every entry of the name.
 *
 * RG_BG_SEE_THROUGH is which see-through layer it is in, counting through rg_game_see_through,
 * or RG_SOLID. RG_BG_BENT is 1 for one the game bends (rg_game_bend_offsets).
 *
 * RG_BG_FADE_PLACE is the furthest forward a placed fade's layer can be and still leave it as
 * drawn, or RG_NO_LAYER when every placed fade reaches it. That is its own place in the stack,
 * unless something else was declared by its name further forward: the interpreter knows what a
 * placed fade leaves alone by name, so the two are left or reached together.
 *
 * Its tiles are RG_BG_TILES pictures in rg_game_tile_pixels from RG_BG_TILES_START on, in the
 * colors they were drawn in. One that can be drawn from other lists of colors has the same
 * pictures again after those, once for each of the RG_BG_COLOR_STEPS steps it can be told, a
 * step swapping the colors by the place each pixel was drawn at.
 *
 * RG_BG_IN_BLOCKS is 1 for one that is drawn in blocks while the picture is shown in them, and 0
 * for one the game leaves as drawn. RG_BG_CAN_TURN is 1 for one declared as able to turn, turned
 * yet or not.
 *
 * RG_BG_PAINTED is RG_NOT_PAINTED for a background with no tile the game paints. For one with
 * any it is where its tiles start in rg_game_painted_tiles, two numbers a tile: the run that
 * paints it and which of the run's tiles it is, or RG_NOT_PAINTED and nought for a tile that is
 * a picture. RG_BG_RUN_COLORS is then where the colors its painted tiles are shown in start in
 * rg_game_run_colors: sixteen for each run the game has, by place, with RG_SEE_THROUGH where a
 * place shows what is behind; and the same again for each step of colors it can be told.
 *
 * RG_BG_BAR_TOP is RG_NOT_A_BAR for a background, and for a status bar the row of the screen it was
 * declared to start at (Nodes::Background#bar_top). A status bar takes no level: it is painted in
 * front of every background and behind every sprite, so its RG_BG_LEVEL is RG_NOT_A_BAR too. */
#define RG_EVERY_SCENE (-1)
#define RG_NEVER_ARRIVES (-2)
#define RG_NO_LAYER (-1)
#define RG_NOT_A_BAR (-1)
/* The most backgrounds a game may have; the build refuses more. */
#define RG_MAX_BACKGROUNDS 64
enum {
  RG_BG_TILE_W, RG_BG_TILE_H, RG_BG_FIRST_MAP, RG_BG_SHOWABLE_MAPS, RG_BG_KEPT_BY, RG_BG_NEVER_WRAPS,
  RG_BG_TILES_START, RG_BG_SCENE, RG_BG_LEVEL, RG_BG_ON_ARRIVAL, RG_BG_STACK_PLACE,
  RG_BG_SEE_THROUGH, RG_BG_BENT, RG_BG_FADE_PLACE, RG_BG_TILES, RG_BG_COLOR_STEPS, RG_BG_IN_BLOCKS,
  RG_BG_CAN_TURN, RG_BG_PAINTED, RG_BG_RUN_COLORS, RG_BG_BAR_TOP, RG_BG_FIELDS
};
extern const int32_t rg_game_backgrounds[];
#define RG_NOT_PAINTED (-1)
extern const int32_t rg_game_painted_tiles[];
extern const uint16_t rg_game_run_colors[];

/* Each run of tiles the game paints from a list is RG_RUN_FIELDS numbers in rg_game_tile_runs. A
 * run a background shows says how many tiles it has, and its width and height are nought. A run
 * that is a sprite's picture says the picture's width and height, and its tiles are the
 * picture's, left to right and then top to bottom. RG_RUN_PLACES is where the run's pixels are
 * kept among every run's, as places in its colors.
 *
 * A painted picture is an image like any other, once for each list of colors a sprite is drawn
 * with. RG_RUN_IMAGES of them are listed in rg_game_run_images from entry RG_RUN_FIRST_IMAGE on,
 * each RG_RUN_IMAGE_FIELDS numbers: the image, and the sixteen colors its places show, the first
 * being RG_NOT_DRAWN. */
enum { RG_RUN_TILES, RG_RUN_WIDTH, RG_RUN_HEIGHT, RG_RUN_PLACES, RG_RUN_FIRST_IMAGE, RG_RUN_IMAGES, RG_RUN_FIELDS };
enum { RG_RUN_IMAGE_FIELDS = 17 };
extern const int32_t rg_game_tile_runs[];
extern const int32_t rg_game_run_images[];

/* Each map is RG_MAP_FIELDS numbers in rg_game_maps: where its cells start in rg_game_map_cells,
 * how many columns and rows it has, and the grid it comes round at (nought each way for a
 * background that never comes round). Its cells are row after row, each the number of a tile or
 * RG_CELL_EMPTY where the map has none. */
#define RG_CELL_EMPTY (-1)
enum { RG_MAP_CELLS, RG_MAP_COLS, RG_MAP_ROWS, RG_MAP_GRID_COLS, RG_MAP_GRID_ROWS, RG_MAP_FIELDS };
extern const int32_t rg_game_maps[];
extern const int16_t rg_game_map_cells[];

/* [how many backgrounds, how many depths the picture is built at, how many backgrounds every
 * screen drawn from tiles shows, 1 for a game whose whole view is rebuilt from its layers, how
 * many layers it can be seen through, 1 for a game that shows more than one kind of screen, the
 * biggest block a picture can be shown in (Backends::Blocks), how many runs of tiles it paints
 * from lists, how many pixels those runs hold between them, how many images it has] */
enum {
  RG_SIZE_BACKGROUNDS, RG_SIZE_DEPTHS, RG_SIZE_ALWAYS_UP, RG_SIZE_REBUILT_WHOLE, RG_SIZE_SEE_THROUGH,
  RG_SIZE_SCREEN_KINDS_CHANGE, RG_SIZE_LARGEST_BLOCK, RG_SIZE_RUNS, RG_SIZE_RUN_PIXELS, RG_SIZE_IMAGES
};
extern const int32_t rg_game_picture_sizes[];
extern const int32_t rg_game_always_up[];

/* sin(d) in 256ths for d = 0..449, the table every backend turns a picture by (IR::Affine), and
 * the four numbers that turn it into a matrix: what a size of 1.0 is (Build::SCALE_ONE), what
 * the matrix calls 1.0 (Affine::ONE_TH), the largest number it holds (Affine::MAX) and the
 * smallest size (Affine::MIN_SCALE). */
extern const int32_t rg_game_sines[];
extern const int32_t rg_game_turn_rules[];

#endif
