/*
 * What the window keeps for a player (see rg_window.h), as plain C with no window under it.
 */
#include "rg_window.h"
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* SDL's scancodes are USB's usage numbers for the key, which do not change; rg_sdl.c asserts
 * every one of these is SDL's. */
#define KEY_A 4
#define KEY_N 17
#define KEY_M 16
#define KEY_P 19
#define KEY_S 22
#define KEY_X 27
#define KEY_Z 29
#define KEY_RETURN 40
#define KEY_BACKSPACE 42
#define KEY_TAB 43
#define KEY_F1 58
#define KEY_F3 60
#define KEY_F11 68
#define KEY_RIGHT 79
#define KEY_LEFT 80
#define KEY_DOWN 81
#define KEY_UP 82
#define KEY_RIGHT_SHIFT 229

/* mGBA's keys, so a player who has used it knows them: the arrows for the pad, X for A, Z for B, A
 * and S for the shoulders, Return for Start and Backspace for Select, and Right Shift for Select
 * too, for a keyboard with no Backspace. */
static const int default_keys[RG_WINDOW_BUTTONS][RG_WINDOW_KEYS_A_BUTTON] = {
  {KEY_X, 0},          /* a */
  {KEY_Z, 0},          /* b */
  {KEY_BACKSPACE, KEY_RIGHT_SHIFT}, /* select */
  {KEY_RETURN, 0},     /* start */
  {KEY_RIGHT, 0},      /* right */
  {KEY_LEFT, 0},       /* left */
  {KEY_UP, 0},         /* up */
  {KEY_DOWN, 0},       /* down */
  {KEY_S, 0},          /* r */
  {KEY_A, 0},          /* l */
};

/* On a gamepad the buttons are where the console has them: A on the right, B below it. The
 * numbers are SDL_GamepadButton's, in the order names list them. */
static const int default_pad[RG_WINDOW_BUTTONS] = {1, 0, 4, 6, 14, 13, 11, 12, 10, 9};

/* Keys the console has no use for, so no button is ever mapped to one: tab is held to fast
 * forward as an emulator does, and the others are near enough to the letters they stand for. */
static const int default_hotkeys[RG_HOTKEY_COUNT] = {
  KEY_P,   /* pause */
  KEY_N,   /* step */
  KEY_F3,  /* frame rate */
  KEY_F11, /* fullscreen */
  KEY_M,   /* mute */
  KEY_F1,  /* menu */
  KEY_TAB, /* fast forward */
};

static const char *const button_names[RG_WINDOW_BUTTONS] = {"A", "B", "Select", "Start", "Right", "Left", "Up", "Down", "R", "L"};
static const char *const button_settings[RG_WINDOW_BUTTONS] = {"a", "b", "select", "start", "right", "left", "up", "down", "r", "l"};
static const char *const hotkey_names[RG_HOTKEY_COUNT] = {"Pause", "Step one frame", "Show frame rate", "Fullscreen", "Mute",
                                                          "Show menu", "Fast forward"};
static const char *const hotkey_settings[RG_HOTKEY_COUNT] = {"pause", "step", "frame_rate", "fullscreen", "mute", "menu",
                                                             "fast_forward"};
static const char *const pad_names[RG_WINDOW_PAD_BUTTONS] = {
  "south", "east", "west", "north", "back", "guide", "start", "left stick", "right stick", "left shoulder", "right shoulder",
  "d-pad up", "d-pad down", "d-pad left", "d-pad right"};
static const char *const pad_settings[RG_WINDOW_PAD_BUTTONS] = {
  "south", "east", "west", "north", "back", "guide", "start", "left_stick", "right_stick", "left_shoulder", "right_shoulder",
  "dpad_up", "dpad_down", "dpad_left", "dpad_right"};
static const char *const panel_names[RG_PANEL_COUNT] = {"controls", "variables"};

/* What is remembered, and so what is written to the settings file. */
typedef struct {
  int scale, fullscreen, volume, muted, show_frame_rate, show_frame_time, fast_speed;
  int keys[RG_WINDOW_BUTTONS][RG_WINDOW_KEYS_A_BUTTON];
  int pad[RG_WINDOW_BUTTONS];
  int hotkeys[RG_HOTKEY_COUNT];
} settings;

static settings now;

/* What is not: it is how the window is at this moment. */
static int paused, steps_owed, fast_held, menu_kept_up, changes;
static int panels[RG_PANEL_COUNT];
static int unwritten, frames_since_change;
static char problems_read[1024];

static const char *(*name_of_key)(int);
static int (*key_with_name)(const char *);

/* --- names --- */

void rg_window_use_key_names(const char *(*name_of)(int), int (*named)(const char *)) {
  name_of_key = name_of;
  key_with_name = named;
}

const char *rg_window_key_name(int key) {
  /* A few buffers taken in turn, so a sentence that names two keys can ask for both. */
  static char names[4][64];
  static int next;
  char *name = names[next++ % 4];
  if (key == RG_NO_KEY) return "none";
  const char *given = name_of_key ? name_of_key(key) : NULL;
  if (given && given[0]) {
    snprintf(name, sizeof names[0], "%s", given);
  } else {
    snprintf(name, sizeof names[0], "key %d", key);
  }
  return name;
}

/* The key a name is, or RG_NO_KEY for one that is not a key's. "key 4" is always understood, as
 * the name of a key nothing else names. */
static int key_named(const char *name) {
  int number;
  char more;
  if (sscanf(name, "key %d%c", &number, &more) == 1 && number > 0) return number;
  return key_with_name ? key_with_name(name) : RG_NO_KEY;
}

const char *rg_window_button_name(int button) { return button >= 0 && button < RG_WINDOW_BUTTONS ? button_names[button] : "?"; }
const char *rg_window_hotkey_name(int hotkey) { return hotkey >= 0 && hotkey < RG_HOTKEY_COUNT ? hotkey_names[hotkey] : "?"; }
const char *rg_window_pad_button_name(int pad_button) {
  return pad_button >= 0 && pad_button < RG_WINDOW_PAD_BUTTONS ? pad_names[pad_button] : "?";
}
const char *rg_window_button_setting(int button) { return button >= 0 && button < RG_WINDOW_BUTTONS ? button_settings[button] : "?"; }
const char *rg_window_hotkey_setting(int hotkey) { return hotkey >= 0 && hotkey < RG_HOTKEY_COUNT ? hotkey_settings[hotkey] : "?"; }

const char *rg_window_panel_name(int panel) { return panel >= 0 && panel < RG_PANEL_COUNT ? panel_names[panel] : "?"; }
int rg_window_panel_named(const char *name) {
  for (int i = 0; i < RG_PANEL_COUNT; i++)
    if (strcmp(name, panel_names[i]) == 0) return i;
  return -1;
}

/* --- remembering --- */

/* Something that is remembered changed: it is due to be written once things are quiet. */
static void remember_change(void) {
  unwritten = 1;
  frames_since_change = 0;
}

static void set_int(int *setting, int value) {
  if (*setting == value) return;
  *setting = value;
  remember_change();
}

static int clamped(int value, int least, int most) { return value < least ? least : value > most ? most : value; }

int rg_window_settings_due(void) {
  if (!unwritten) return 0;
  if (frames_since_change < RG_SETTINGS_QUIET_FRAMES) {
    frames_since_change++;
    return 0;
  }
  return 1;
}
int rg_window_settings_unwritten(void) { return unwritten; }
void rg_window_settings_written(void) { unwritten = 0; }
void rg_window_settings_not_written(void) { frames_since_change = 0; }

void rg_window_set_problems(const char *text) { snprintf(problems_read, sizeof problems_read, "%s", text); }
const char *rg_window_problems(void) { return problems_read; }

/* --- pause, step, fast forward --- */

void rg_window_pause(void) { paused = 1; }
void rg_window_resume(void) {
  paused = 0;
  steps_owed = 0;
}
void rg_window_toggle_pause(void) {
  if (paused) rg_window_resume();
  else rg_window_pause();
}
int rg_window_paused(void) { return paused; }

void rg_window_step(void) {
  if (paused) steps_owed = 1;
}
int rg_window_take_step(void) {
  if (!paused || !steps_owed) return 0;
  steps_owed = 0;
  return 1;
}

void rg_window_fast_forward(int held) { fast_held = held != 0; }
int rg_window_fast_forwarding(void) { return fast_held && !paused; }
void rg_window_set_fast_speed(int times) { set_int(&now.fast_speed, clamped(times, RG_FAST_SPEED_LEAST, RG_FAST_SPEED_MOST)); }
int rg_window_fast_speed(void) { return now.fast_speed; }

/* --- the window --- */

void rg_window_set_scale(int scale) {
  scale = clamped(scale, RG_WINDOW_SCALE_LEAST, RG_WINDOW_SCALE_MOST);
  if (scale == now.scale) return;
  set_int(&now.scale, scale);
  changes |= RG_CHANGE_SCALE;
}
int rg_window_scale(void) { return now.scale; }

void rg_window_size_changed(int width, int height, int picture_width, int picture_height) {
  if (now.fullscreen || picture_width <= 0 || picture_height <= 0) return;
  int across = width / picture_width, down = height / picture_height;
  set_int(&now.scale, clamped(across < down ? across : down, RG_WINDOW_SCALE_LEAST, RG_WINDOW_SCALE_MOST));
}

void rg_window_set_fullscreen(int on) {
  on = on != 0;
  if (on == now.fullscreen) return;
  set_int(&now.fullscreen, on);
  changes |= RG_CHANGE_FULLSCREEN;
}
void rg_window_toggle_fullscreen(void) { rg_window_set_fullscreen(!now.fullscreen); }
int rg_window_fullscreen(void) { return now.fullscreen; }
void rg_window_fullscreen_happened(int on) { set_int(&now.fullscreen, on != 0); }

int rg_window_take_changes(void) {
  int taken = changes;
  changes = 0;
  return taken;
}

/* --- sound --- */

void rg_window_set_volume(int percent) { set_int(&now.volume, clamped(percent, 0, 100)); }
int rg_window_volume(void) { return now.volume; }
void rg_window_set_mute(int on) { set_int(&now.muted, on != 0); }
void rg_window_toggle_mute(void) { rg_window_set_mute(!now.muted); }
int rg_window_muted(void) { return now.muted; }

uint32_t rg_window_gain(void) {
  if (now.muted) return 0;
  return (uint32_t)now.volume * (uint32_t)now.volume * 65536u / 10000u;
}

void rg_window_apply_volume(int16_t *samples, size_t count) {
  uint32_t gain = rg_window_gain();
  if (gain >= 65536u) return;
  for (size_t i = 0; i < count; i++) samples[i] = (int16_t)(((int64_t)samples[i] * (int64_t)gain) / 65536);
}

/* --- what is shown --- */

void rg_window_set_show_frame_rate(int on) { set_int(&now.show_frame_rate, on != 0); }
void rg_window_toggle_frame_rate(void) { rg_window_set_show_frame_rate(!now.show_frame_rate); }
int rg_window_shows_frame_rate(void) { return now.show_frame_rate; }
void rg_window_set_show_frame_time(int on) { set_int(&now.show_frame_time, on != 0); }
int rg_window_shows_frame_time(void) { return now.show_frame_time; }

#define METER_NS 500000000ull
static uint64_t meter_began_ns;
static uint64_t meter_frames;
static double meter_rate;
static int meter_measured;

void rg_window_frame_played(uint64_t now_ns) {
  if (meter_began_ns == 0) meter_began_ns = now_ns;
  meter_frames++;
}

double rg_window_frames_a_second(uint64_t now_ns) {
  if (meter_began_ns == 0) meter_began_ns = now_ns;
  uint64_t elapsed = now_ns - meter_began_ns;
  if (elapsed >= METER_NS) {
    meter_rate = (double)meter_frames * 1e9 / (double)elapsed;
    meter_measured = 1;
    meter_began_ns = now_ns;
    meter_frames = 0;
  }
  /* Until the first half second is up, what there is so far: a window is not to say 0 fps for its
   * first moments. */
  if (!meter_measured && meter_frames >= 2 && elapsed > 0) return (double)(meter_frames - 1) * 1e9 / (double)elapsed;
  return meter_rate;
}

void rg_window_toggle_menu(void) { menu_kept_up = !menu_kept_up; }
int rg_window_menu_kept_up(void) { return menu_kept_up; }

void rg_window_show_panel(int panel, int shown) {
  if (panel >= 0 && panel < RG_PANEL_COUNT) panels[panel] = shown != 0;
}
int rg_window_panel_shown(int panel) { return panel >= 0 && panel < RG_PANEL_COUNT && panels[panel]; }

/* --- keys and gamepad buttons --- */

int rg_window_key_button(int key) {
  if (key == RG_NO_KEY) return -1;
  for (int b = 0; b < RG_WINDOW_BUTTONS; b++)
    for (int s = 0; s < RG_WINDOW_KEYS_A_BUTTON; s++)
      if (now.keys[b][s] == key) return b;
  return -1;
}

int rg_window_key_hotkey(int key) {
  if (key == RG_NO_KEY) return -1;
  for (int h = 0; h < RG_HOTKEY_COUNT; h++)
    if (now.hotkeys[h] == key) return h;
  return -1;
}

int rg_window_button_key(int button, int slot) {
  if (button < 0 || button >= RG_WINDOW_BUTTONS || slot < 0 || slot >= RG_WINDOW_KEYS_A_BUTTON) return RG_NO_KEY;
  return now.keys[button][slot];
}
int rg_window_hotkey_key(int hotkey) { return hotkey >= 0 && hotkey < RG_HOTKEY_COUNT ? now.hotkeys[hotkey] : RG_NO_KEY; }
int rg_window_pad_button(int button) { return button >= 0 && button < RG_WINDOW_BUTTONS ? now.pad[button] : 0; }

static char notice[192];

const char *rg_window_notice(void) { return notice; }
void rg_window_clear_notice(void) { notice[0] = '\0'; }

static const char *say(const char *format, ...) __attribute__((format(printf, 1, 2)));
static const char *say(const char *format, ...) {
  va_list args;
  va_start(args, format);
  vsnprintf(notice, sizeof notice, format, args);
  va_end(args);
  return notice;
}

/* Why +key+ cannot be a button's or a hotkey's, when another has it: a sentence, or NULL when it
 * is free. +button+ and +hotkey+ are the one asking, -1 for neither. */
static const char *refusal(int key, int button, int hotkey) {
  int owner = rg_window_key_button(key);
  if (owner >= 0 && owner != button)
    return say("%s is already the %s button. Clear it there first, then it can be used here.", rg_window_key_name(key),
               button_names[owner]);
  int taken = rg_window_key_hotkey(key);
  if (taken >= 0 && taken != hotkey)
    return say("%s is the hotkey for \"%s\". Change that hotkey first, then this key can be used here.", rg_window_key_name(key),
               hotkey_names[taken]);
  return NULL;
}

const char *rg_window_bind_key(int button, int slot, int key) {
  if (button < 0 || button >= RG_WINDOW_BUTTONS || slot < 0 || slot >= RG_WINDOW_KEYS_A_BUTTON) return say("There is no such button.");
  if (key != RG_NO_KEY) {
    if (key == RG_KEY_ESCAPE) return say("Escape gives up choosing a key, so it cannot be one.");
    const char *why = refusal(key, button, -1);
    if (why) return why;
    /* Already this button's other key: it moves here, rather than being the button's twice. */
    for (int s = 0; s < RG_WINDOW_KEYS_A_BUTTON; s++)
      if (s != slot) {
        if (now.keys[button][s] == key) remember_change();
        if (now.keys[button][s] == key) now.keys[button][s] = RG_NO_KEY;
      }
  }
  set_int(&now.keys[button][slot], key);
  rg_window_clear_notice();
  return NULL;
}

const char *rg_window_bind_hotkey(int hotkey, int key) {
  if (hotkey < 0 || hotkey >= RG_HOTKEY_COUNT) return say("There is no such hotkey.");
  if (key != RG_NO_KEY) {
    if (key == RG_KEY_ESCAPE) return say("Escape gives up choosing a key, so it cannot be one.");
    const char *why = refusal(key, -1, hotkey);
    if (why) return why;
  }
  set_int(&now.hotkeys[hotkey], key);
  rg_window_clear_notice();
  return NULL;
}

const char *rg_window_bind_pad(int button, int pad_button) {
  if (button < 0 || button >= RG_WINDOW_BUTTONS) return say("There is no such button.");
  if (pad_button < 0 || pad_button >= RG_WINDOW_PAD_BUTTONS) return say("The window cannot use that gamepad button.");
  for (int b = 0; b < RG_WINDOW_BUTTONS; b++)
    if (b != button && now.pad[b] == pad_button) set_int(&now.pad[b], now.pad[button]);
  set_int(&now.pad[button], pad_button);
  rg_window_clear_notice();
  return NULL;
}

void rg_window_reset_pad(void) {
  for (int b = 0; b < RG_WINDOW_BUTTONS; b++) set_int(&now.pad[b], default_pad[b]);
}

/* Every key a button or a hotkey has, in the order a clash is settled in: the later one of two
 * that share a key is the one that loses it. Each slot is told as an index into this walk. */
#define KEY_SLOTS (RG_WINDOW_BUTTONS * RG_WINDOW_KEYS_A_BUTTON + RG_HOTKEY_COUNT)
static int *key_slot(settings *in, int index) {
  if (index < RG_WINDOW_BUTTONS * RG_WINDOW_KEYS_A_BUTTON) return &in->keys[index / RG_WINDOW_KEYS_A_BUTTON][index % RG_WINDOW_KEYS_A_BUTTON];
  return &in->hotkeys[index - RG_WINDOW_BUTTONS * RG_WINDOW_KEYS_A_BUTTON];
}

static const char *slot_owner_name(int index) {
  return index < RG_WINDOW_BUTTONS * RG_WINDOW_KEYS_A_BUTTON ? button_names[index / RG_WINDOW_KEYS_A_BUTTON]
                                                            : hotkey_names[index - RG_WINDOW_BUTTONS * RG_WINDOW_KEYS_A_BUTTON];
}

/* Appends a sentence and a newline to +out+, which holds +room+ bytes; a sentence that does not
 * fit is left out. */
static void append(char *out, size_t room, const char *format, ...) __attribute__((format(printf, 3, 4)));
static void append(char *out, size_t room, const char *format, ...) {
  size_t used = strlen(out);
  if (used + 1 >= room) return;
  va_list args;
  va_start(args, format);
  int wrote = vsnprintf(out + used, room - used, format, args);
  va_end(args);
  if (wrote < 0 || (size_t)wrote + 2 > room - used) {
    out[used] = '\0';
    return;
  }
  out[used + (size_t)wrote] = '\n';
  out[used + (size_t)wrote + 1] = '\0';
}

/* No key is two things: where two have one, the later loses it and it is said. A button's key
 * that a hotkey would have taken is the button's, since a console button is what a player came
 * for. */
static int settle_clashes(settings *in, char *problems, size_t room) {
  int found = 0;
  for (int later = 1; later < KEY_SLOTS; later++) {
    int *key = key_slot(in, later);
    if (*key == RG_NO_KEY) continue;
    for (int earlier = 0; earlier < later; earlier++) {
      if (*key_slot(in, earlier) != *key) continue;
      /* Two keys of the same button are the same thing said twice, and are not a clash. */
      if (later < RG_WINDOW_BUTTONS * RG_WINDOW_KEYS_A_BUTTON && earlier / RG_WINDOW_KEYS_A_BUTTON == later / RG_WINDOW_KEYS_A_BUTTON) {
        *key = RG_NO_KEY;
        break;
      }
      append(problems, room, "%s is used for both %s and %s. It stays with %s and is taken off %s.", rg_window_key_name(*key),
             slot_owner_name(earlier), slot_owner_name(later), slot_owner_name(earlier), slot_owner_name(later));
      *key = RG_NO_KEY;
      found++;
      break;
    }
  }
  return found;
}

void rg_window_reset_keys(void) {
  settings fresh = now;
  memcpy(fresh.keys, default_keys, sizeof fresh.keys);
  char said[256] = "";
  settle_clashes(&fresh, said, sizeof said);
  if (memcmp(&fresh, &now, sizeof fresh) != 0) remember_change();
  now = fresh;
  if (said[0]) say("Keys are back as they were. %s", said);
  else rg_window_clear_notice();
}

void rg_window_reset_hotkeys(void) {
  settings fresh = now;
  memcpy(fresh.hotkeys, default_hotkeys, sizeof fresh.hotkeys);
  /* The defaults are no console button's, but a button may have been given one since. */
  for (int h = 0; h < RG_HOTKEY_COUNT; h++)
    for (int b = 0; b < RG_WINDOW_BUTTONS; b++)
      for (int s = 0; s < RG_WINDOW_KEYS_A_BUTTON; s++)
        if (fresh.keys[b][s] == fresh.hotkeys[h]) fresh.hotkeys[h] = RG_NO_KEY;
  if (memcmp(&fresh, &now, sizeof fresh) != 0) remember_change();
  now = fresh;
  rg_window_clear_notice();
}

void rg_window_use_defaults(void) {
  memset(&now, 0, sizeof now);
  now.scale = RG_WINDOW_SCALE_START;
  now.volume = 100;
  now.show_frame_rate = 1;
  now.fast_speed = 4;
  memcpy(now.keys, default_keys, sizeof now.keys);
  memcpy(now.pad, default_pad, sizeof now.pad);
  memcpy(now.hotkeys, default_hotkeys, sizeof now.hotkeys);
  paused = steps_owed = fast_held = menu_kept_up = changes = 0;
  memset(panels, 0, sizeof panels);
  unwritten = 0;
  frames_since_change = 0;
  problems_read[0] = '\0';
  notice[0] = '\0';
  meter_began_ns = 0;
  meter_frames = 0;
  meter_rate = 0.0;
  meter_measured = 0;
}

/* --- choosing a key by pressing it --- */

static enum { WAITING_FOR_NOTHING, WAITING_FOR_BUTTON_KEY, WAITING_FOR_HOTKEY, WAITING_FOR_PAD } waiting;
static int waiting_button, waiting_slot, waiting_hotkey;

void rg_window_capture_key_for_button(int button, int slot) {
  waiting = WAITING_FOR_BUTTON_KEY;
  waiting_button = button;
  waiting_slot = slot;
  rg_window_clear_notice();
}
void rg_window_capture_key_for_hotkey(int hotkey) {
  waiting = WAITING_FOR_HOTKEY;
  waiting_hotkey = hotkey;
  rg_window_clear_notice();
}
void rg_window_capture_pad_for_button(int button) {
  waiting = WAITING_FOR_PAD;
  waiting_button = button;
  rg_window_clear_notice();
}
void rg_window_capture_cancel(void) { waiting = WAITING_FOR_NOTHING; }
int rg_window_capturing(void) { return waiting != WAITING_FOR_NOTHING; }

int rg_window_capture_key(int key) {
  if (waiting != WAITING_FOR_BUTTON_KEY && waiting != WAITING_FOR_HOTKEY) return 0;
  if (key == RG_KEY_ESCAPE) {
    waiting = WAITING_FOR_NOTHING;
    return 1;
  }
  const char *why = waiting == WAITING_FOR_BUTTON_KEY ? rg_window_bind_key(waiting_button, waiting_slot, key)
                                                      : rg_window_bind_hotkey(waiting_hotkey, key);
  /* A key that was refused is said, and the window goes on waiting for another. */
  if (!why) waiting = WAITING_FOR_NOTHING;
  return 1;
}

int rg_window_capture_pad(int pad_button) {
  if (waiting != WAITING_FOR_PAD) return 0;
  if (rg_window_bind_pad(waiting_button, pad_button)) return 1; /* a button that is not a standard one: wait for another */
  waiting = WAITING_FOR_NOTHING;
  return 1;
}

const char *rg_window_capture_prompt(void) {
  static char prompt[96];
  switch (waiting) {
  case WAITING_FOR_BUTTON_KEY:
    snprintf(prompt, sizeof prompt, "Press a key for %s (Escape to give up)...", button_names[waiting_button]);
    break;
  case WAITING_FOR_HOTKEY:
    snprintf(prompt, sizeof prompt, "Press a key for \"%s\" (Escape to give up)...", hotkey_names[waiting_hotkey]);
    break;
  case WAITING_FOR_PAD:
    snprintf(prompt, sizeof prompt, "Press a gamepad button for %s...", button_names[waiting_button]);
    break;
  default:
    prompt[0] = '\0';
  }
  return prompt;
}

/* --- hotkeys --- */

void rg_window_hotkey_changed(int hotkey, int down) {
  if (hotkey == RG_HOTKEY_FAST_FORWARD) {
    rg_window_fast_forward(down);
    return;
  }
  if (!down) return;
  switch (hotkey) {
  case RG_HOTKEY_PAUSE:
    rg_window_toggle_pause();
    break;
  case RG_HOTKEY_STEP:
    rg_window_step();
    break;
  case RG_HOTKEY_FRAME_RATE:
    rg_window_toggle_frame_rate();
    break;
  case RG_HOTKEY_FULLSCREEN:
    rg_window_toggle_fullscreen();
    break;
  case RG_HOTKEY_MUTE:
    rg_window_toggle_mute();
    break;
  case RG_HOTKEY_MENU:
    rg_window_toggle_menu();
    break;
  default:
    break;
  }
}

/* --- the game's variables --- */

#define WATCH_MOST 512
static struct {
  char name[56];
  int32_t value;
} watched[WATCH_MOST];
static int watched_count, watched_dropped;

void rg_window_watch_begin(void) {
  watched_count = 0;
  watched_dropped = 0;
}
void rg_window_watch_note(const char *name, int32_t value) {
  if (watched_count == WATCH_MOST) {
    watched_dropped++;
    return;
  }
  snprintf(watched[watched_count].name, sizeof watched[watched_count].name, "%s", name);
  watched[watched_count].value = value;
  watched_count++;
}
int rg_window_watch_count(void) { return watched_count; }
const char *rg_window_watch_name(int i) { return i >= 0 && i < watched_count ? watched[i].name : ""; }
int32_t rg_window_watch_value(int i) { return i >= 0 && i < watched_count ? watched[i].value : 0; }
int rg_window_watch_dropped(void) { return watched_dropped; }

/* --- the settings file --- */

size_t rg_window_settings_text(char *out, size_t room) {
  size_t used = 0;
  /* Each line is written whole or, when the room is gone, not at all, with the length it wanted
   * still counted, as snprintf does. */
#define LINE(...)                                                                                      \
  do {                                                                                                 \
    int wrote = snprintf(used < room ? out + used : NULL, used < room ? room - used : 0, __VA_ARGS__); \
    if (wrote > 0) used += (size_t)wrote;                                                              \
  } while (0)
  LINE("# The window's settings: one `name = value` to a line, and a line starting with # is a note.\n");
  LINE("# The window writes this file when something is changed in its menu, and reads it when it opens,\n");
  LINE("# so it can be edited by hand while the window is closed.\n");
  LINE("scale = %d\n", now.scale);
  LINE("fullscreen = %s\n", now.fullscreen ? "on" : "off");
  LINE("volume = %d\n", now.volume);
  LINE("mute = %s\n", now.muted ? "on" : "off");
  LINE("frame_rate = %s\n", now.show_frame_rate ? "on" : "off");
  LINE("frame_time = %s\n", now.show_frame_time ? "on" : "off");
  LINE("fast_forward_speed = %d\n", now.fast_speed);
  LINE("\n# Keys, as SDL names them (Backspace, Right Shift, Left, X). A button has a line for each of its keys.\n");
  for (int b = 0; b < RG_WINDOW_BUTTONS; b++) {
    int written = 0;
    for (int s = 0; s < RG_WINDOW_KEYS_A_BUTTON; s++) {
      if (now.keys[b][s] == RG_NO_KEY) continue;
      LINE("key.%s = %s\n", button_settings[b], rg_window_key_name(now.keys[b][s]));
      written++;
    }
    if (!written) LINE("key.%s = none\n", button_settings[b]);
  }
  LINE("\n# Gamepad buttons: south, east, west, north, back, guide, start, left_stick, right_stick,\n");
  LINE("# left_shoulder, right_shoulder, dpad_up, dpad_down, dpad_left, dpad_right.\n");
  for (int b = 0; b < RG_WINDOW_BUTTONS; b++) LINE("pad.%s = %s\n", button_settings[b], pad_settings[now.pad[b]]);
  LINE("\n# Keys the window keeps for itself. No console button may use one of them.\n");
  for (int h = 0; h < RG_HOTKEY_COUNT; h++) LINE("hotkey.%s = %s\n", hotkey_settings[h], rg_window_key_name(now.hotkeys[h]));
#undef LINE
  return used;
}

/* The text with its ends trimmed of spaces, tabs and the line's end; changes the text in place. */
static char *trimmed(char *text) {
  while (*text == ' ' || *text == '\t') text++;
  size_t length = strlen(text);
  while (length && (text[length - 1] == ' ' || text[length - 1] == '\t' || text[length - 1] == '\r' || text[length - 1] == '\n')) length--;
  text[length] = '\0';
  return text;
}

static int equal_ignoring_case(const char *a, const char *b) {
  for (; *a && *b; a++, b++) {
    char one = *a >= 'A' && *a <= 'Z' ? (char)(*a - 'A' + 'a') : *a;
    char other = *b >= 'A' && *b <= 'Z' ? (char)(*b - 'A' + 'a') : *b;
    if (one != other) return 0;
  }
  return *a == *b;
}

/* on/off in the ways a person writes them; -1 for neither. */
static int truth(const char *value) {
  static const char *const yes[] = {"on", "yes", "true", "1"};
  static const char *const no[] = {"off", "no", "false", "0"};
  for (size_t i = 0; i < sizeof yes / sizeof yes[0]; i++) {
    if (equal_ignoring_case(value, yes[i])) return 1;
    if (equal_ignoring_case(value, no[i])) return 0;
  }
  return -1;
}

static int index_of(const char *const *names, int count, const char *name) {
  for (int i = 0; i < count; i++)
    if (equal_ignoring_case(names[i], name)) return i;
  return -1;
}

/* A whole number in a range, or a sentence about why not. */
static int whole_number(const char *value, int least, int most, int *into) {
  char *end;
  long number = strtol(value, &end, 10);
  if (end == value || *end != '\0' || number < least || number > most) return 0;
  *into = (int)number;
  return 1;
}

int rg_window_settings_read(const char *text, char *problems, size_t room) {
  if (room) problems[0] = '\0';
  settings candidate = now;
  int touched_keys[RG_WINDOW_BUTTONS] = {0};
  int said = 0;
  int line_number = 0;
  char copy[256];

#define PROBLEM(...)                                                    \
  do {                                                                  \
    char what[200];                                                     \
    snprintf(what, sizeof what, __VA_ARGS__);                           \
    if (room) append(problems, room, "Line %d: %s", line_number, what); \
    said++;                                                             \
  } while (0)

  for (const char *at = text; *at;) {
    const char *start = at;
    const char *end = strchr(at, '\n');
    size_t length = end ? (size_t)(end - at) : strlen(at);
    at += length + (end ? 1 : 0);
    line_number++;
    if (length >= sizeof copy) {
      PROBLEM("that line is too long to be a setting, so it is left out.");
      continue;
    }
    memcpy(copy, start, length);
    copy[length] = '\0';
    char *line = trimmed(copy);
    if (*line == '\0' || *line == '#') continue;
    char *equals = strchr(line, '=');
    if (!equals) {
      PROBLEM("\"%s\" is not `name = value`, so it is left out.", line);
      continue;
    }
    *equals = '\0';
    char *name = trimmed(line);
    char *value = trimmed(equals + 1);
    for (char *c = name; *c; c++)
      if (*c >= 'A' && *c <= 'Z') *c = (char)(*c - 'A' + 'a');
    int number, flag;

    if (strcmp(name, "scale") == 0) {
      if (whole_number(value, RG_WINDOW_SCALE_LEAST, RG_WINDOW_SCALE_MOST, &number)) candidate.scale = number;
      else PROBLEM("scale is a whole number from %d to %d, not \"%s\".", RG_WINDOW_SCALE_LEAST, RG_WINDOW_SCALE_MOST, value);
    } else if (strcmp(name, "volume") == 0) {
      if (whole_number(value, 0, 100, &number)) candidate.volume = number;
      else PROBLEM("volume is a whole number from 0 to 100, not \"%s\".", value);
    } else if (strcmp(name, "fast_forward_speed") == 0) {
      if (whole_number(value, RG_FAST_SPEED_LEAST, RG_FAST_SPEED_MOST, &number)) candidate.fast_speed = number;
      else PROBLEM("fast_forward_speed is a whole number from %d to %d, not \"%s\".", RG_FAST_SPEED_LEAST, RG_FAST_SPEED_MOST, value);
    } else if (strcmp(name, "fullscreen") == 0 || strcmp(name, "mute") == 0 || strcmp(name, "frame_rate") == 0 ||
               strcmp(name, "frame_time") == 0) {
      flag = truth(value);
      if (flag < 0) {
        PROBLEM("%s is on or off, not \"%s\".", name, value);
      } else if (strcmp(name, "fullscreen") == 0) {
        candidate.fullscreen = flag;
      } else if (strcmp(name, "mute") == 0) {
        candidate.muted = flag;
      } else if (strcmp(name, "frame_rate") == 0) {
        candidate.show_frame_rate = flag;
      } else {
        candidate.show_frame_time = flag;
      }
    } else if (strncmp(name, "key.", 4) == 0) {
      int button = index_of(button_settings, RG_WINDOW_BUTTONS, name + 4);
      int key = equal_ignoring_case(value, "none") ? RG_NO_KEY : key_named(value);
      if (button < 0) {
        PROBLEM("there is no button called \"%s\" (they are a, b, select, start, right, left, up, down, r, l).", name + 4);
      } else if (key == RG_NO_KEY && !equal_ignoring_case(value, "none")) {
        PROBLEM("\"%s\" is not a key's name, so %s keeps the key it had.", value, rg_window_button_name(button));
      } else {
        /* The first line for a button replaces the keys it had; each after that adds one. */
        if (!touched_keys[button]) memset(candidate.keys[button], 0, sizeof candidate.keys[button]);
        touched_keys[button] = 1;
        int slot = 0;
        while (slot < RG_WINDOW_KEYS_A_BUTTON && candidate.keys[button][slot] != RG_NO_KEY) slot++;
        if (key == RG_NO_KEY) continue;
        if (slot == RG_WINDOW_KEYS_A_BUTTON) PROBLEM("%s has room for %d keys, so \"%s\" is left out.", rg_window_button_name(button), RG_WINDOW_KEYS_A_BUTTON, value);
        else candidate.keys[button][slot] = key;
      }
    } else if (strncmp(name, "pad.", 4) == 0) {
      int button = index_of(button_settings, RG_WINDOW_BUTTONS, name + 4);
      int pad = index_of(pad_settings, RG_WINDOW_PAD_BUTTONS, value);
      if (button < 0) PROBLEM("there is no button called \"%s\" (they are a, b, select, start, right, left, up, down, r, l).", name + 4);
      else if (pad < 0) PROBLEM("\"%s\" is not a gamepad button the window knows, so %s keeps the one it had.", value, rg_window_button_name(button));
      else candidate.pad[button] = pad;
    } else if (strncmp(name, "hotkey.", 7) == 0) {
      int hotkey = index_of(hotkey_settings, RG_HOTKEY_COUNT, name + 7);
      int key = equal_ignoring_case(value, "none") ? RG_NO_KEY : key_named(value);
      if (hotkey < 0) PROBLEM("there is no hotkey called \"%s\".", name + 7);
      else if (key == RG_NO_KEY && !equal_ignoring_case(value, "none")) PROBLEM("\"%s\" is not a key's name, so \"%s\" keeps the key it had.", value, rg_window_hotkey_name(hotkey));
      else candidate.hotkeys[hotkey] = key;
    } else {
      PROBLEM("there is no setting called \"%s\", so the line is left out.", name);
    }
  }
#undef PROBLEM

  /* Escape gives up choosing a key, so it is no button's and no hotkey's. */
  for (int i = 0; i < (int)KEY_SLOTS; i++)
    if (*key_slot(&candidate, i) == RG_KEY_ESCAPE) {
      if (room) append(problems, room, "Escape gives up choosing a key, so %s cannot use it and has no key.", slot_owner_name(i));
      *key_slot(&candidate, i) = RG_NO_KEY;
      said++;
    }

  char clashes[512] = "";
  said += settle_clashes(&candidate, clashes, sizeof clashes);
  if (room && clashes[0]) {
    size_t used = strlen(problems);
    snprintf(problems + used, room - used, "%s", clashes);
  }

  /* What is read is not due to be written back, but a window that is already open has to be
   * told what changed in it. */
  if (candidate.fullscreen != now.fullscreen) changes |= RG_CHANGE_FULLSCREEN;
  if (candidate.scale != now.scale) changes |= RG_CHANGE_SCALE;
  now = candidate;
  return said;
}
