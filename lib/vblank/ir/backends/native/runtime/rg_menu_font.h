/*
 * THE LETTERS THE WINDOW MENU IS WRITTEN IN (Graphics::MenuFont in the library, which this is
 * written again from): Inter at 15 points, drawn once into pictures by tools/make_menu_font.rb, and
 * handed to this file as C data by the build (rg_window_menu_data.c), so the program needs no font
 * library and no font file. The window puts a density's picture of every letter on the screen's
 * card once, then writes a word by copying each letter out of it to where rg_menu_font_layout says.
 *
 * There are pictures at two densities: one pixel a point, for an ordinary screen, and two, for a
 * Retina one. A screen of any other density is written with the nearer of the two, scaled.
 */
#ifndef RG_MENU_FONT_H
#define RG_MENU_FONT_H

#include <stdint.h>
#include "rg_window_menu.h"

#ifdef __cplusplus
extern "C" {
#endif

/* A letter of the font: where it is in the picture, where it sits from the pen and the top of
 * the line, and how far the pen moves after it, all in the picture's pixels. */
typedef struct {
  uint32_t letter; /* its Unicode number */
  int x, y, width, height, left, top, advance;
} rg_menu_glyph;

/* Two letters that sit closer, or further apart, than their advances say. */
typedef struct {
  uint32_t first, second;
  int amount;
} rg_menu_kerning;

/* One density's picture of every letter: +alpha+ is how much of each pixel the letters cover, 0
 * to 255, a byte each, +width+ by +height+, a row at a time from the top. Glyphs and kerning are in
 * order of their letters, to be looked up by halves. */
typedef struct {
  int density, line_height, width, height;
  const uint8_t *alpha;
  const rg_menu_glyph *glyphs;
  int glyph_count;
  const rg_menu_kerning *kerning;
  int kerning_count;
} rg_menu_atlas;

/* The pictures, at one pixel a point and at two. */
extern const rg_menu_atlas rg_menu_atlases[2];

/* The picture the letters at +density+ (pixels a point) are copied from. */
const rg_menu_atlas *rg_menu_font_atlas(double density);
/* How tall a line of words is at +density+, in pixels. */
int rg_menu_font_line_height(double density);
/* How wide +words+ (UTF-8) are at +density+, in pixels. */
int rg_menu_font_width(const char *words, double density);
/* Each letter of +words+, written with the top left of their line at +x+, +y+ (pixels), at
 * +density+, put in +out+ (room for +room+); gives how many. A letter the font does not have is
 * written as a question mark, and a space is only room. */
int rg_menu_font_layout(const char *words, int x, int y, double density, rg_menu_letter *out, int room);

/* A number rounded to the nearest whole one, a half away from nought, as Ruby rounds: the menu's
 * pixels have to come out the same in both. */
int rg_menu_rounded(double value);

#ifdef __cplusplus
}
#endif

#endif
