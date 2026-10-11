/*
 * The music player and the sound log (see rg_sound.h).
 *
 * A song is a set of parts played together, each walking its own list of notes, all reading one
 * frame counter so they stay in step. Every frame the player first catches up with what the game
 * asked for — a different tune silences the old one and starts the new one from its first frame
 * — then plays each part's next note if it is due on this frame, then moves the counter on,
 * coming round at the song's end to the frame it loops from. That is the interpreter's order
 * (Reference::Player#advance), and keeping it is what makes the two logs agree line for line.
 *
 * THE SONGS, as the lowering writes them into rg_game_music, all whole numbers:
 *
 *   the music volume a part sounds at in full, and how far to shift back down by it
 *     (IR::Tunes::FULL_LEVEL and LEVEL_SHIFT — written by the lowering so they cannot drift);
 *   song count, then where each song starts in the array, then each song:
 *     total frames, the frame it loops from, how many parts, then each part:
 *       notes the first time through, notes every time after, then those notes,
 *       three numbers each: the frame it starts on, its pitch in Hz (0 is a rest), its volume
 *
 * A part has two lists because a song that loops from part way through plays its introduction
 * once: the first list is the whole part, the second what it plays each time it comes round
 * (worked out once, for every backend, by IR::Tunes.loop_passes).
 */
#include <stdarg.h>
#include <stdio.h>
#include "rg_sound.h"
#include "rg_driver.h"
#include "rg_runtime.h"

/* As many square-wave parts as a song can have: the console has two square voices for music. A
 * build refuses a song with more, so this is a guard on the table rather than a rule. */
#define MOST_PARTS 2
#define NUMBERS_PER_NOTE 3

/* Where things are in rg_game_music (see the layout above). */
#define FULL_LEVEL (rg_game_music[0])
#define LEVEL_SHIFT (rg_game_music[1])
#define SONG_COUNT (rg_game_music[2])
#define SONG_STARTS 3

/* One part of the playing song: the list of notes it is walking now, and which comes next. */
typedef struct {
  const int32_t *notes;
  int32_t count;
  int32_t next;
} part_walk;

/* A voice holding a note, and the volume the note was written at (0 for a rest). */
typedef struct {
  int32_t voice;
  int32_t volume;
} held_note;

static int32_t wanted = -1;  /* the tune the game last named, or -1 for none */
static int32_t playing = -1; /* ...and the one the player is on, which catches up each frame */
static int32_t stops;        /* how many times the game has said stop... */
static int32_t stops_seen;   /* ...and how many of those the player has acted on */

static const int32_t *song; /* the playing song's numbers */
static int32_t song_frame;  /* how far into it, in frames */
static int32_t part_count;
static part_walk parts[MOST_PARTS];

static const int32_t *level_variable; /* where the game keeps its music volume, if it has one */
static int32_t level = -1;            /* the volume the notes sounding were set at (full, at power-on) */

/* The voices holding a note, in the order each first took one since the song started — the order
 * the interpreter's own record keeps, and so the order a change of volume is logged in. */
static held_note holding[MOST_PARTS];
static int32_t holding_count;

static void log_sound(const char *format, ...) {
  char line[64];
  va_list args;
  va_start(args, format);
  vsnprintf(line, sizeof line, format, args);
  va_end(args);
  rg_active_driver->sound_logged(line);
}

void rg_sound_enabled(void) { log_sound("enabled"); }
void rg_sound_beep(int32_t which) { log_sound("beep %d", (int)which); }

void rg_music_request(int32_t number) {
  if (number < 0 || number >= SONG_COUNT) rg_fault("there is no song number %d", (int)number);
  wanted = number;
}

void rg_music_stop(void) {
  wanted = -1;
  stops++;
}

void rg_music_follow_level(const int32_t *variable) { level_variable = variable; }

/* Every part's list of notes from its start: the first time through, or every time after. */
static void start_walks(int again) {
  const int32_t *part = song + 3;
  for (int32_t i = 0; i < part_count; i++) {
    int32_t first = part[0], after = part[1];
    const int32_t *first_notes = part + 2;
    const int32_t *after_notes = first_notes + (NUMBERS_PER_NOTE * first);
    parts[i] = (part_walk){again ? after_notes : first_notes, again ? after : first, 0};
    part = after_notes + (NUMBERS_PER_NOTE * after);
  }
}

/* A note's written volume (0 to 15) at the music volume in force: multiplied and shifted back
 * down, so it never rounds up past what was written. */
static int32_t scaled_volume(int32_t volume) { return (volume * level) >> LEVEL_SHIFT; }

/* A voice now holds a note written at +volume+ (0 for a rest). */
static void hold_note(int32_t voice, int32_t volume) {
  int32_t at = 0;
  while (at < holding_count && holding[at].voice != voice) at++;
  if (at == holding_count) holding_count++;
  holding[at] = (held_note){voice, volume};
  log_sound("loudness %d %d", (int)voice, (int)scaled_volume(volume));
}

/* The music volume has moved: every voice holding a note takes it. A square voice takes a volume
 * only as a note starts, so the note is sounded again at the new one. */
static void follow_level(int32_t now) {
  if (now == level) return;
  level = now;
  for (int32_t i = 0; i < holding_count; i++) {
    if (holding[i].volume > 0) log_sound("loudness %d %d", (int)holding[i].voice, (int)scaled_volume(holding[i].volume));
  }
}

/* The tune the game asked for has changed, or it said stop: silence what was playing and start
 * the new one from its first frame. */
static void switch_to_wanted_song(void) {
  if (wanted == playing && stops == stops_seen) return;

  stops_seen = stops;
  if (playing >= 0) log_sound("stop_music");
  holding_count = 0;
  playing = wanted;
  song_frame = 0;
  if (playing < 0) return;

  song = &rg_game_music[rg_game_music[SONG_STARTS + playing]];
  part_count = song[2];
  if (part_count > MOST_PARTS) {
    rg_fault("song number %d has %d parts, and the most is %d", (int)playing, (int)part_count, MOST_PARTS);
  }
  start_walks(0);
}

void rg_music_frame(void) {
  if (level < 0) level = FULL_LEVEL;
  switch_to_wanted_song();
  if (playing < 0) return;

  if (level_variable) follow_level(*level_variable);
  for (int32_t i = 0; i < part_count; i++) {
    part_walk *part = &parts[i];
    if (part->next >= part->count) continue;
    const int32_t *note = part->notes + (NUMBERS_PER_NOTE * part->next);
    if (note[0] != song_frame) continue;

    int32_t voice = i + 1, pitch = note[1], volume = note[2];
    log_sound("note %d %d", (int)playing, (int)pitch);
    log_sound("voice %d %d %d %d", (int)voice, (int)playing, (int)pitch, (int)volume);
    if (level_variable) hold_note(voice, pitch == 0 ? 0 : volume);
    part->next++;
  }

  song_frame++;
  if (song_frame < song[0]) return;
  song_frame = song[1];
  start_walks(1);
}
