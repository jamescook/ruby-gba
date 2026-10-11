/*
 * The music player, the square-wave voices and the sound log (see rg_sound.h).
 *
 * THE PLAYER. A song is a set of parts played together, each walking its own list of notes, all
 * reading one frame counter so they stay in step. Every frame the player first catches up with
 * what the game asked for — a different tune silences the old one and starts the new one from
 * its first frame — then plays each part's next note if it is due on this frame, then moves the
 * counter on, coming round at the song's end to the frame it loops from. That is the
 * interpreter's order (Reference::Player#advance), and keeping it is what makes the two logs
 * agree line for line.
 *
 * THE VOICES. The console has two voices that each play a square wave: a wave that is high for
 * part of its length and low for the rest. Three things set what one sounds like, and they are
 * all the console's own rules (Audio::Sound has them in one place for every backend):
 *
 *   - its PITCH is how many ticks of a 131,072-a-second clock one wave lasts, a whole number;
 *   - its TONE is how many eighths of the wave are high — half is full and hollow, less is
 *     thinner and brighter;
 *   - its LOUDNESS is 0 to 15, and a note that fades loses one of those every so many 64ths of a
 *     second until it is silent.
 *
 * A song's first part plays on the first voice and its second on the second, and a note there
 * holds until the next one. A beep plays on the second voice and fades. So a song with two parts
 * and a beep share that voice, and whichever was started last is what it plays — as on the
 * console.
 *
 * WHAT THE LOWERING WRITES, all whole numbers. rg_game_music:
 *
 *   the music volume a part sounds at in full, how far to shift back down by it
 *     (IR::Tunes::FULL_LEVEL and LEVEL_SHIFT), and the voices' clock in ticks a second;
 *   song count, then where each song starts in the array, then each song:
 *     total frames, the frame it loops from, how many parts, then each part:
 *       eighths of its wave that are high, notes the first time through, notes every time after,
 *       then those notes, four numbers each: the frame it starts on, its pitch in Hz (0 is a
 *       rest), its volume, and the ticks one wave of it lasts
 *
 * A part has two lists because a song that loops from part way through plays its introduction
 * once: the first list is the whole part, the second what it plays each time it comes round
 * (worked out once, for every backend, by IR::Tunes.loop_passes).
 *
 * rg_game_beeps: how many beeps there are, then four numbers a beep — the ticks one wave lasts,
 * eighths high, the volume it starts at, and the 64ths of a second it holds each step of volume
 * as it fades (0 never fades).
 */
#include <stdarg.h>
#include <stdio.h>
#include "rg_sound.h"
#include "rg_driver.h"
#include "rg_runtime.h"

/* The console's two square voices. A song has at most that many square-wave parts — the build
 * refuses one with more — so the same number is also the most parts the player walks. */
#define VOICES 2
#define NUMBERS_PER_NOTE 4
#define NUMBERS_PER_BEEP 4
#define BEEP_VOICE 2

/* Where things are in rg_game_music (see the layout above). */
#define FULL_LEVEL (rg_game_music[0])
#define LEVEL_SHIFT (rg_game_music[1])
#define CLOCK_HZ (rg_game_music[2])
#define SONG_COUNT (rg_game_music[3])
#define SONG_STARTS 4

/* How much one step of loudness moves the speaker. Both voices at their loudest then swing
 * through half of what a sample can hold, which leaves the other half for the recorded sound a
 * game plays over them. */
#define STEP_SIZE 1092

/* The console's clock for one frame, as rg_sdl.c has it: 280,896 ticks of a 2^24-a-second clock.
 * A frame's samples are that share of a second's, and the part of a sample left over is carried
 * to the next frame so no time is lost or made up. */
#define FRAME_TICKS 280896
#define TICKS_A_SECOND_BITS 24

/* --- the voices --- */

typedef struct {
  int32_t wave_ticks;     /* ticks one wave lasts; 0 when the voice has nothing to play */
  int32_t eighths_high;   /* how many eighths of the wave are high */
  int32_t volume;         /* 0 to 15, now */
  int32_t fade_samples;   /* samples it holds each step of volume for; 0 never fades */
  int32_t fade_left;      /* samples until the next step down */
  int32_t eighth;         /* which eighth of the wave it is in */
  int64_t eighth_progress; /* how far through that eighth, in ticks times samples a second */
} square_voice;

static square_voice squares[VOICES];
static int32_t heard_only; /* a test listening to one voice: its number, or 0 for both */
static uint64_t sample_carry; /* the fraction of a sample left over from the last frame */

/* A voice starts a note from the top of its wave. No ticks, or no volume, is silence. */
static void square_start(int32_t voice, int32_t wave_ticks, int32_t eighths_high, int32_t volume, int32_t fade_64ths) {
  square_voice *square = &squares[voice - 1];
  square->wave_ticks = wave_ticks;
  square->eighths_high = eighths_high;
  square->volume = volume;
  square->fade_samples = fade_64ths * RG_SOUND_RATE / 64;
  square->fade_left = square->fade_samples;
  square->eighth = 0;
  square->eighth_progress = 0;
}

/* The console's own order of high and low through a wave, for each tone: which of the eight
 * parts are high. (It makes no difference to the ear where in the wave the high part falls.) */
static int32_t eighth_is_high(int32_t eighths_high, int32_t eighth) {
  switch (eighths_high) {
  case 1: return eighth == 7;
  case 2: return eighth == 0 || eighth == 7;
  case 4: return eighth == 0 || eighth >= 5;
  default: return eighth >= 1 && eighth <= 6;
  }
}

/* One sample of a voice. High and low are set either side of nought by how long each lasts, so
 * a wave averages nought whatever its tone and starting or stopping one does not jolt the
 * speaker to one side. */
static int32_t square_sample(square_voice *square) {
  if (square->wave_ticks == 0 || square->volume == 0) return 0;

  int32_t high = eighth_is_high(square->eighths_high, square->eighth);
  int32_t sample = STEP_SIZE * square->volume * (high ? 8 - square->eighths_high : -square->eighths_high) / 8;

  /* An eighth of a wave lasts wave_ticks / 8 ticks, and a sample lasts CLOCK_HZ / rate ticks:
   * kept as whole numbers by counting in ticks times samples a second. */
  int64_t eighth_length = (int64_t)square->wave_ticks * RG_SOUND_RATE;
  square->eighth_progress += (int64_t)CLOCK_HZ * 8;
  while (square->eighth_progress >= eighth_length) {
    square->eighth_progress -= eighth_length;
    square->eighth = (square->eighth + 1) & 7;
  }
  if (square->fade_samples > 0 && --square->fade_left == 0) {
    square->volume--;
    square->fade_left = square->fade_samples;
  }
  return sample;
}

void rg_sound_hear_only(int32_t voice) { heard_only = voice; }

int32_t rg_sound_render_frame(int16_t *samples) {
  sample_carry += (uint64_t)RG_SOUND_RATE * FRAME_TICKS;
  int32_t count = (int32_t)(sample_carry >> TICKS_A_SECOND_BITS);
  sample_carry &= ((uint64_t)1 << TICKS_A_SECOND_BITS) - 1;

  for (int32_t i = 0; i < count; i++) {
    int32_t sum = 0;
    for (int32_t voice = 1; voice <= VOICES; voice++) {
      int32_t sample = square_sample(&squares[voice - 1]); /* every voice moves on, heard or not */
      if (heard_only == 0 || heard_only == voice) sum += sample;
    }
    samples[i] = (int16_t)sum;
  }
  return count;
}

/* --- the log --- */

static void log_sound(const char *format, ...) {
  char line[64];
  va_list args;
  va_start(args, format);
  vsnprintf(line, sizeof line, format, args);
  va_end(args);
  rg_active_driver->sound_logged(line);
}

void rg_sound_enabled(void) { log_sound("enabled"); }

void rg_sound_beep(int32_t which) {
  if (which < 0 || which >= rg_game_beeps[0]) rg_fault("there is no beep number %d", (int)which);
  const int32_t *beep = &rg_game_beeps[1 + (which * NUMBERS_PER_BEEP)];
  log_sound("beep %d", (int)which);
  square_start(BEEP_VOICE, beep[0], beep[1], beep[2], beep[3]);
}

/* --- the player --- */

/* One part of the playing song: the list of notes it is walking now, and which comes next. */
typedef struct {
  const int32_t *notes;
  int32_t count;
  int32_t next;
  int32_t eighths_high;
} part_walk;

/* A note a song's part is holding on a voice: the volume it was written at (0 for a rest), and
 * what it sounds like. Kept here and not read back off the voice, because a beep can borrow the
 * second voice while the part's note is still being held, and it is the part's note the music
 * volume sounds again. */
typedef struct {
  int32_t voice;
  int32_t volume;
  int32_t wave_ticks;
  int32_t eighths_high;
} held_note;

static int32_t wanted = -1;  /* the tune the game last named, or -1 for none */
static int32_t playing = -1; /* ...and the one the player is on, which catches up each frame */
static int32_t stops;        /* how many times the game has said stop... */
static int32_t stops_seen;   /* ...and how many of those the player has acted on */

static const int32_t *song; /* the playing song's numbers */
static int32_t song_frame;  /* how far into it, in frames */
static int32_t part_count;
static part_walk parts[VOICES];

static const int32_t *level_variable; /* where the game keeps its music volume, if it has one */
static int32_t level = -1;            /* the volume the notes sounding were set at (full, at power-on) */

/* The voices holding a note, in the order each first took one since the song started — the order
 * the interpreter's own record keeps, and so the order a change of volume is logged in. */
static held_note holding[VOICES];
static int32_t holding_count;

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
    int32_t first = part[1], after = part[2];
    const int32_t *first_notes = part + 3;
    const int32_t *after_notes = first_notes + (NUMBERS_PER_NOTE * first);
    parts[i] = (part_walk){again ? after_notes : first_notes, again ? after : first, 0, part[0]};
    part = after_notes + (NUMBERS_PER_NOTE * after);
  }
}

/* A note's written volume (0 to 15) at the music volume in force: multiplied and shifted back
 * down, so it never rounds up past what was written. */
static int32_t scaled_volume(int32_t volume) { return (volume * level) >> LEVEL_SHIFT; }

/* A voice now holds +note+ for its part. */
static void hold_note(held_note note) {
  int32_t at = 0;
  while (at < holding_count && holding[at].voice != note.voice) at++;
  if (at == holding_count) holding_count++;
  holding[at] = note;
  log_sound("loudness %d %d", (int)note.voice, (int)scaled_volume(note.volume));
}

/* The music volume has moved: every voice holding a note takes it. A square voice takes a volume
 * only as a note starts, so the part's note is sounded again at the new one. */
static void follow_level(int32_t now) {
  if (now == level) return;
  level = now;
  for (int32_t i = 0; i < holding_count; i++) {
    const held_note *note = &holding[i];
    if (note->volume <= 0) continue;
    log_sound("loudness %d %d", (int)note->voice, (int)scaled_volume(note->volume));
    square_start(note->voice, note->wave_ticks, note->eighths_high, scaled_volume(note->volume), 0);
  }
}

/* The tune the game asked for has changed, or it said stop: silence what was playing — its own
 * voices and no others, so a one-part tune ending does not cut off a beep on the second voice —
 * and start the new one from its first frame. */
static void switch_to_wanted_song(void) {
  if (wanted == playing && stops == stops_seen) return;

  stops_seen = stops;
  if (playing >= 0) {
    log_sound("stop_music");
    for (int32_t voice = 1; voice <= part_count; voice++) square_start(voice, 0, 0, 0, 0);
  }
  holding_count = 0;
  playing = wanted;
  song_frame = 0;
  part_count = 0;
  if (playing < 0) return;

  song = &rg_game_music[rg_game_music[SONG_STARTS + playing]];
  part_count = song[2];
  if (part_count > VOICES) {
    rg_fault("song number %d has %d parts, and the most is %d", (int)playing, (int)part_count, VOICES);
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

    int32_t voice = i + 1, pitch = note[1], volume = note[2], wave_ticks = note[3];
    int32_t written = pitch == 0 ? 0 : volume;
    log_sound("note %d %d", (int)playing, (int)pitch);
    log_sound("voice %d %d %d %d", (int)voice, (int)playing, (int)pitch, (int)volume);
    if (level_variable) hold_note((held_note){voice, written, wave_ticks, part->eighths_high});
    square_start(voice, wave_ticks, part->eighths_high, level_variable ? scaled_volume(written) : written, 0);
    part->next++;
  }

  song_frame++;
  if (song_frame < song[0]) return;
  song_frame = song[1];
  start_walks(1);
}
