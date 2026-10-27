/*
 * The menu's letters (rg_menu_font.h), laid out as Graphics::MenuFont lays them out, line for line.
 */
#include "rg_menu_font.h"

#include <stddef.h>

int rg_menu_rounded(double value) {
  /* Taking the whole part off leaves the rest exactly, so the half is found exactly too. */
  double whole = (double)(long long)value;
  double rest = value - whole;
  if (rest >= 0.5) whole += 1.0;
  else if (rest <= -0.5) whole -= 1.0;
  return (int)whole;
}

static int nearest_density(double density) { return density >= 1.5 ? 2 : 1; }

static double scale_of(double density) { return density / (double)nearest_density(density); }

const rg_menu_atlas *rg_menu_font_atlas(double density) { return &rg_menu_atlases[nearest_density(density) - 1]; }

int rg_menu_font_line_height(double density) {
  return rg_menu_rounded((double)rg_menu_font_atlas(density)->line_height * scale_of(density));
}

/* The next letter of UTF-8 +text+, moving it on past it; a byte that is not one is taken as itself. */
static uint32_t next_letter(const char **text) {
  const unsigned char *at = (const unsigned char *)*text;
  uint32_t letter = at[0];
  int more = letter >= 0xF0 ? 3 : letter >= 0xE0 ? 2 : letter >= 0xC0 ? 1 : 0;
  if (more) letter &= 0x3Fu >> more;
  int taken = 1;
  for (int i = 1; i <= more && (at[i] & 0xC0) == 0x80; i++, taken++) letter = (letter << 6) | (at[i] & 0x3Fu);
  *text += taken;
  return letter;
}

static const rg_menu_glyph *glyph_of(const rg_menu_atlas *atlas, uint32_t letter) {
  int low = 0, high = atlas->glyph_count - 1;
  while (low <= high) {
    int middle = (low + high) / 2;
    uint32_t found = atlas->glyphs[middle].letter;
    if (found == letter) return &atlas->glyphs[middle];
    if (found < letter) low = middle + 1;
    else high = middle - 1;
  }
  return NULL;
}

static int kerning_of(const rg_menu_atlas *atlas, uint32_t first, uint32_t second) {
  int low = 0, high = atlas->kerning_count - 1;
  while (low <= high) {
    int middle = (low + high) / 2;
    const rg_menu_kerning *pair = &atlas->kerning[middle];
    if (pair->first == first && pair->second == second) return pair->amount;
    if (pair->first < first || (pair->first == first && pair->second < second)) low = middle + 1;
    else high = middle - 1;
  }
  return 0;
}

/* Walks the pen along +words+ in the picture's own pixels, putting each letter where it goes (when
 * +out+ is given), and gives how far it went in the picture's pixels. */
static int pen_walk(const char *words, int x, int y, double density, rg_menu_letter *out, int room, int *count) {
  const rg_menu_atlas *atlas = rg_menu_font_atlas(density);
  double scale = scale_of(density);
  int pen = 0;
  uint32_t previous = 0;
  int placed = 0;
  while (*words) {
    uint32_t letter = next_letter(&words);
    const rg_menu_glyph *glyph = glyph_of(atlas, letter);
    if (!glyph) {
      letter = '?';
      glyph = glyph_of(atlas, letter);
    }
    if (previous) pen += kerning_of(atlas, previous, letter);
    if (out && glyph->width != 0 && placed < room) {
      rg_menu_letter *placing = &out[placed++];
      placing->from[0] = glyph->x;
      placing->from[1] = glyph->y;
      placing->from[2] = glyph->width;
      placing->from[3] = glyph->height;
      placing->to[0] = rg_menu_rounded((double)x + (double)(pen + glyph->left) * scale);
      placing->to[1] = rg_menu_rounded((double)y + (double)glyph->top * scale);
      placing->to[2] = rg_menu_rounded((double)glyph->width * scale);
      placing->to[3] = rg_menu_rounded((double)glyph->height * scale);
    }
    pen += glyph->advance;
    previous = letter;
  }
  if (count) *count = placed;
  return pen;
}

int rg_menu_font_width(const char *words, double density) {
  return rg_menu_rounded((double)pen_walk(words, 0, 0, density, NULL, 0, NULL) * scale_of(density));
}

int rg_menu_font_layout(const char *words, int x, int y, double density, rg_menu_letter *out, int room) {
  int count = 0;
  pen_walk(words, x, y, density, out, room, &count);
  return count;
}
