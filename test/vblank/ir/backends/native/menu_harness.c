/*
 * The window menu's C (runtime/rg_window_menu.c) driven a command to a line, for
 * test_native_window_menu.rb to play the same keys through it and through the Ruby copy:
 *
 *   picture 240 160                  a window that many pixels at each size, the menu closed
 *   most_scale 6                     the biggest the window can be made
 *   toggle                           open the menu, or close it
 *   press up|down|left|right|enter|close
 *   hotkey NAME                      a hotkey pressed, as rg_window.c takes it: frame_rate, mute...
 *   draw WIDTH DENSITY HELD FAST RATE WORK
 *                                    print what the menu draws; RATE and WORK are words, - for none
 *   state                            print whether it is open and whether Quit was chosen
 *
 * What is drawn is printed a part to a line: "box x y width height radius r g b a", or
 * "words r g b a text" followed by a "letter" line for each letter, its rectangle in the font's
 * picture and in the window. Then "end".
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "rg_window.h"
#include "rg_window_menu.h"

static rg_menu_drawing drawing;

/* The menu's key a word names, in rg_menu_key's order. */
static rg_menu_key key_named(const char *name) {
  static const char *const names[] = {"up", "down", "left", "right", "enter", "close"};
  for (int i = 0; i < (int)(sizeof names / sizeof names[0]); i++)
    if (strcmp(name, names[i]) == 0) return (rg_menu_key)i;
  fprintf(stderr, "no menu key is called %s\n", name);
  exit(2);
}

static void print_drawing(void) {
  for (int i = 0; i < drawing.part_count; i++) {
    const rg_menu_part *part = &drawing.parts[i];
    if (part->is_box) {
      printf("box %d %d %d %d %d %d %d %d %d\n", part->x, part->y, part->width, part->height, part->radius, part->color[0], part->color[1],
             part->color[2], part->color[3]);
      continue;
    }
    printf("words %d %d %d %d %s\n", part->color[0], part->color[1], part->color[2], part->color[3], part->text);
    for (int l = part->first_letter; l < part->first_letter + part->letter_count; l++) {
      const rg_menu_letter *letter = &drawing.letters[l];
      printf("letter %d %d %d %d %d %d %d %d\n", letter->from[0], letter->from[1], letter->from[2], letter->from[3], letter->to[0],
             letter->to[1], letter->to[2], letter->to[3]);
    }
  }
  printf("end\n");
}

int main(void) {
  rg_window_use_defaults();
  rg_window_menu_reset(240, 160);
  char line[256];
  while (fgets(line, sizeof line, stdin)) {
    char *command = strtok(line, " \n");
    if (!command) continue;
    if (strcmp(command, "picture") == 0) {
      int width = atoi(strtok(NULL, " \n"));
      int height = atoi(strtok(NULL, " \n"));
      rg_window_menu_reset(width, height);
    } else if (strcmp(command, "most_scale") == 0) {
      rg_window_menu_set_most_scale(atoi(strtok(NULL, " \n")));
    } else if (strcmp(command, "toggle") == 0) {
      rg_window_menu_toggle();
    } else if (strcmp(command, "press") == 0) {
      rg_window_menu_press(key_named(strtok(NULL, " \n")));
    } else if (strcmp(command, "hotkey") == 0) {
      const char *name = strtok(NULL, " \n");
      for (int h = 0; h < RG_HOTKEY_COUNT; h++)
        if (strcmp(rg_window_hotkey_setting(h), name) == 0) rg_window_hotkey_changed(h, 1);
    } else if (strcmp(command, "draw") == 0) {
      int width = atoi(strtok(NULL, " \n"));
      double density = strtod(strtok(NULL, " \n"), NULL);
      int held = atoi(strtok(NULL, " \n"));
      int fast = atoi(strtok(NULL, " \n"));
      const char *rate = strtok(NULL, " \n");
      const char *work = strtok(NULL, " \n");
      rg_window_menu_draw(&drawing, width, density, held, fast, strcmp(rate, "-") ? rate : NULL, strcmp(work, "-") ? work : NULL);
      print_drawing();
    } else if (strcmp(command, "state") == 0) {
      printf("open %d quit %d\n", rg_window_menu_is_open(), rg_window_menu_quit_chosen());
    }
  }
  return 0;
}
