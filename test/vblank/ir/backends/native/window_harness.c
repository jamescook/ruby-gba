/*
 * Drives runtime/rg_window.c with no window, a command to a line of standard input and its
 * answer to a line of standard output. See test_native_window.rb.
 *
 * The keys have the names SDL gives them, for the few this knows: letters, Return, Escape,
 * Backspace, Tab, Space, ",", F1, F3, F11, the arrows and Right Shift.
 */
#define _DEFAULT_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "rg_window.h"

static const struct {
  const char *name;
  int key;
} key_table[] = {
  {"A", 4},      {"B", 5},    {"M", 16},        {"N", 17},      {"P", 19},          {"S", 22},   {"X", 27},
  {"Z", 29},     {"Q", 20},   {"Return", 40},   {"Escape", 41}, {"Backspace", 42},  {"Tab", 43}, {"Space", 44},
  {",", 54},     {"F1", 58},  {"F3", 60},       {"F11", 68},    {"Right", 79},      {"Left", 80}, {"Down", 81},
  {"Up", 82},    {"Right Shift", 229},
};
#define KEYS (sizeof key_table / sizeof key_table[0])

static const char *name_of(int key) {
  for (size_t i = 0; i < KEYS; i++)
    if (key_table[i].key == key) return key_table[i].name;
  return "";
}

static int key_named(const char *name) {
  for (size_t i = 0; i < KEYS; i++)
    if (strcasecmp(key_table[i].name, name) == 0) return key_table[i].key;
  return RG_NO_KEY;
}

/* A key as the commands write it: its name with _ for a space, or "none". */
static int key_word(const char *word) {
  char spaced[64];
  size_t i = 0;
  for (; word[i] && i + 1 < sizeof spaced; i++) spaced[i] = word[i] == '_' ? ' ' : word[i];
  spaced[i] = '\0';
  return strcmp(spaced, "none") == 0 ? RG_NO_KEY : key_named(spaced);
}

static int button_word(const char *word) {
  for (int b = 0; b < RG_WINDOW_BUTTONS; b++)
    if (strcmp(rg_window_button_setting(b), word) == 0) return b;
  return -1;
}

static int hotkey_word(const char *word) {
  for (int h = 0; h < RG_HOTKEY_COUNT; h++)
    if (strcmp(rg_window_hotkey_setting(h), word) == 0) return h;
  return -1;
}

static int pad_word(const char *word) {
  for (int p = 0; p < RG_WINDOW_PAD_BUTTONS; p++) {
    char name[32];
    snprintf(name, sizeof name, "%s", rg_window_pad_button_name(p));
    for (char *c = name; *c; c++) if (*c == ' ' || *c == '-') *c = '_';
    if (strcmp(name, word) == 0) return p;
  }
  return -1;
}

static void said(const char *result) { puts(result ? result : "ok"); }

int main(void) {
  rg_window_use_key_names(name_of, key_named);
  rg_window_use_defaults();
  char line[1024];
  while (fgets(line, sizeof line, stdin)) {
    char *words[16];
    int count = 0;
    for (char *word = strtok(line, " \t\r\n"); word && count < 16; word = strtok(NULL, " \t\r\n")) words[count++] = word;
    if (!count) continue;
    const char *c = words[0];
    int n = count > 1 ? atoi(words[1]) : 0;
    if (!strcmp(c, "reset")) rg_window_use_defaults();
    else if (!strcmp(c, "paused")) printf("%d\n", rg_window_paused());
    else if (!strcmp(c, "pause")) rg_window_pause();
    else if (!strcmp(c, "resume")) rg_window_resume();
    else if (!strcmp(c, "toggle_pause")) rg_window_toggle_pause();
    else if (!strcmp(c, "step")) rg_window_step();
    else if (!strcmp(c, "consume_step")) printf("%d\n", rg_window_consume_step());
    else if (!strcmp(c, "fast_forward")) rg_window_fast_forward(n);
    else if (!strcmp(c, "fast_forwarding")) printf("%d\n", rg_window_fast_forwarding());
    else if (!strcmp(c, "set_fast_speed")) rg_window_set_fast_speed(n);
    else if (!strcmp(c, "fast_speed")) printf("%d\n", rg_window_fast_speed());
    else if (!strcmp(c, "set_scale")) rg_window_set_scale(n);
    else if (!strcmp(c, "scale")) printf("%d\n", rg_window_scale());
    else if (!strcmp(c, "size_changed")) rg_window_size_changed(n, atoi(words[2]), 240, 160);
    else if (!strcmp(c, "set_fullscreen")) rg_window_set_fullscreen(n);
    else if (!strcmp(c, "toggle_fullscreen")) rg_window_toggle_fullscreen();
    else if (!strcmp(c, "fullscreen_happened")) rg_window_fullscreen_happened(n);
    else if (!strcmp(c, "fullscreen")) printf("%d\n", rg_window_fullscreen());
    else if (!strcmp(c, "consume_changes")) printf("%d\n", rg_window_consume_changes());
    else if (!strcmp(c, "set_volume")) rg_window_set_volume(n);
    else if (!strcmp(c, "volume")) printf("%d\n", rg_window_volume());
    else if (!strcmp(c, "set_mute")) rg_window_set_mute(n);
    else if (!strcmp(c, "toggle_mute")) rg_window_toggle_mute();
    else if (!strcmp(c, "muted")) printf("%d\n", rg_window_muted());
    else if (!strcmp(c, "gain")) printf("%u\n", (unsigned)rg_window_gain());
    else if (!strcmp(c, "apply_volume")) {
      int16_t samples[16];
      int total = count - 1;
      for (int i = 0; i < total; i++) samples[i] = (int16_t)atoi(words[i + 1]);
      rg_window_apply_volume(samples, (size_t)total);
      for (int i = 0; i < total; i++) printf("%d ", samples[i]);
      putchar('\n');
    } else if (!strcmp(c, "toggle_frame_rate")) rg_window_toggle_frame_rate();
    else if (!strcmp(c, "frame_rate_shown")) printf("%d\n", rg_window_shows_frame_rate());
    else if (!strcmp(c, "frame_played")) rg_window_frame_played((uint64_t)atoll(words[1]), count > 2 ? (uint64_t)atoll(words[2]) : 0);
    else if (!strcmp(c, "frames_a_second")) printf("%.1f\n", rg_window_frames_a_second((uint64_t)atoll(words[1])));
    else if (!strcmp(c, "frame_work_ms")) printf("%.2f\n", rg_window_frame_work_ms((uint64_t)atoll(words[1])));
    else if (!strcmp(c, "hotkey")) rg_window_hotkey_changed(hotkey_word(words[1]), atoi(words[2]));
    else if (!strcmp(c, "owner")) {
      int key = key_word(words[1]);
      int button = rg_window_key_button(key), hotkey = rg_window_key_hotkey(key);
      if (button >= 0) printf("button %s\n", rg_window_button_setting(button));
      else if (hotkey >= 0) printf("hotkey %s\n", rg_window_hotkey_setting(hotkey));
      else puts("none");
    } else if (!strcmp(c, "keys_of")) {
      int b = button_word(words[1]);
      printf("%s %s\n", rg_window_key_name(rg_window_button_key(b, 0)), rg_window_key_name(rg_window_button_key(b, 1)));
    } else if (!strcmp(c, "hotkey_of")) printf("%s\n", rg_window_key_name(rg_window_hotkey_key(hotkey_word(words[1]))));
    else if (!strcmp(c, "pad_of")) printf("%s\n", rg_window_pad_button_name(rg_window_pad_button(button_word(words[1]))));
    else if (!strcmp(c, "bind_key")) said(rg_window_bind_key(button_word(words[1]), atoi(words[2]), key_word(words[3])));
    else if (!strcmp(c, "bind_hotkey")) said(rg_window_bind_hotkey(hotkey_word(words[1]), key_word(words[2])));
    else if (!strcmp(c, "bind_pad")) said(rg_window_bind_pad(button_word(words[1]), pad_word(words[2])));
    else if (!strcmp(c, "reset_keys")) rg_window_reset_keys();
    else if (!strcmp(c, "reset_pad")) rg_window_reset_pad();
    else if (!strcmp(c, "reset_hotkeys")) rg_window_reset_hotkeys();
    else if (!strcmp(c, "notice")) printf("[%s]\n", rg_window_notice());
    else if (!strcmp(c, "capture_key")) rg_window_capture_key_for_button(button_word(words[1]), atoi(words[2]));
    else if (!strcmp(c, "capture_hotkey")) rg_window_capture_key_for_hotkey(hotkey_word(words[1]));
    else if (!strcmp(c, "capture_pad")) rg_window_capture_pad_for_button(button_word(words[1]));
    else if (!strcmp(c, "press")) printf("%d [%s]\n", rg_window_capture_key(key_word(words[1])), rg_window_notice());
    else if (!strcmp(c, "press_pad")) printf("%d\n", rg_window_capture_pad(pad_word(words[1])));
    else if (!strcmp(c, "capturing")) printf("%d [%s]\n", rg_window_capturing(), rg_window_capture_prompt());
    else if (!strcmp(c, "write") || !strcmp(c, "write_own")) {
      static char text[8192];
      size_t wanted = rg_window_settings_text(text, sizeof text, !strcmp(c, "write_own") ? RG_SETTINGS_OWN : RG_SETTINGS_ALL);
      printf("%s--- %zu\n", text, wanted);
    } else if (!strcmp(c, "write_small")) {
      char text[40];
      size_t wanted = rg_window_settings_text(text, sizeof text, RG_SETTINGS_ALL);
      printf("%zu %zu\n", wanted, strlen(text));
    } else if (!strcmp(c, "mark_inherited")) {
      rg_window_mark_settings_inherited();
    } else if (!strcmp(c, "read")) {
      /* The text of a settings file follows, up to a line that is just a full stop. */
      static char text[8192];
      size_t used = 0;
      while (fgets(line, sizeof line, stdin) && strcmp(line, ".\n") != 0) {
        size_t length = strlen(line);
        memcpy(text + used, line, length);
        used += length;
      }
      text[used] = '\0';
      char problems[1024];
      int found = rg_window_settings_read(text, problems, sizeof problems);
      printf("%d problems\n%s", found, problems);
    } else if (!strcmp(c, "due")) printf("%d\n", rg_window_settings_due((uint64_t)atoll(words[1])));
    else if (!strcmp(c, "unwritten")) printf("%d\n", rg_window_settings_unwritten());
    else if (!strcmp(c, "mark_written")) rg_window_mark_settings_written();
    else if (!strcmp(c, "mark_write_failed")) rg_window_mark_settings_write_failed();
    else if (!strcmp(c, "watch")) {
      rg_window_watch_begin();
      for (int i = 0; i < 600; i++) {
        char name[16];
        snprintf(name, sizeof name, "v%d", i);
        rg_window_watch_note(name, i * 2);
      }
      printf("%d %s %d %d\n", rg_window_watch_count(), rg_window_watch_name(5), (int)rg_window_watch_value(5), rg_window_watch_dropped());
    } else printf("unknown command %s\n", c);
    fflush(stdout);
  }
  return 0;
}
