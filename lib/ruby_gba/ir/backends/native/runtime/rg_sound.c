/*
 * The music player, the console's four voices and the sound log (see rg_sound.h).
 *
 * THE PLAYER. A song is a set of parts played together, each walking its own list of notes, all
 * reading one frame counter so they stay in step. Every frame the player first catches up with
 * what the game asked for — a different tune silences the old one and starts the new one from
 * its first frame — then plays each part's next note if it is due on this frame, then moves the
 * counter on, coming round at the song's end to the frame it loops from. A song that plays once
 * does not come round: it ends there, and on the next frame its parts go quiet and no tune is
 * playing. That is the interpreter's order (Reference::Player#advance), and keeping it is what
 * makes the two logs agree line for line.
 *
 * THE VOICES. The console has four of its own, and every rule below is the console's
 * (Audio::Sound has them in one place for every backend, and the lowering writes the numbers
 * here from there).
 *
 * Two play a SQUARE WAVE: a wave that is high for part of its length and low for the rest.
 *
 *   - its PITCH is how many ticks of a 131,072-a-second clock one wave lasts, a whole number;
 *   - its TONE is how many eighths of the wave are high — half is full and hollow, less is
 *     thinner and brighter;
 *   - its LOUDNESS is 0 to 15, and a note that fades loses one of those every so many 64ths of a
 *     second until it is silent.
 *
 * One loops a WAVEFORM: 32 steps of 0 to 15, played one after another and round again, which
 * can be any shape — a triangle, a sine, a pulse of the game's own.
 *
 *   - its PITCH is how many ticks of a 65,536-a-second clock all 32 steps last;
 *   - its LOUDNESS is one of five: so many quarters of each step, none to all four, with what
 *     does not divide dropped. It does not fade; it plays until it is told otherwise.
 *
 * There is one waveform in the voice at a time. A `wave` puts its own there, and so does a tune
 * with a part on this voice, as it starts. `stop_wave` switches the voice off, and it then stays
 * silent whatever notes it is given until one of those two switches it on again.
 *
 * One makes a HISS: a row of bits shuffled along a place at a time, the voice high or low by the
 * bit that falls off the end.
 *
 *   - its PITCH is how many ticks of a 524,288-a-second clock one step lasts — fast is a thin
 *     high hiss, slow a rumble;
 *   - its TONE is how many bits are in the row: fifteen is a plain hiss, and seven comes round
 *     so soon it is heard as a rattle;
 *   - its LOUDNESS is 0 to 15 and fades the way a square voice's does.
 *
 * A song's first square part plays on the first voice and its second on the second, and a note
 * there holds until the next one. A beep plays on the second voice and fades. So a song with two
 * square parts and a beep share that voice, and whichever was started last is what it plays — as
 * on the console. The wave voice is shared the same way by a song's wave part and the game's
 * `wave`, and the noise voice by a song's drums and the game's `noise`.
 *
 * WHAT THE LOWERING WRITES, all whole numbers.
 *
 * rg_game_sound_rules: the ticks a second of the square voices' clock, the wave voice's and the
 * noise voice's; how many times a second the console hands its voices on to the speaker; the
 * music volume a part sounds at in full and how far to shift back down by it
 * (IR::Tunes::FULL_LEVEL and LEVEL_SHIFT); and sixteen numbers, the wave voice's loudness in
 * quarters for each volume from 0 to 15.
 *
 * rg_game_waveforms: how many waveforms there are, then 32 steps for each.
 *
 * rg_game_music:
 *
 *   song count, then where each song starts in the array, then each song:
 *     total frames, the frame it loops from, 1 if it plays once and ends, how many parts,
 *     then each part:
 *       the kind of voice it plays on (0 square, 1 wave, 2 noise), which of its song's parts it
 *       is, two numbers for what the voice sounds like — a square part's eighths high and 0, a
 *       wave part's waveform and 0, a noise part's bits and the 64ths of a second it holds each
 *       step of volume — notes the first time through, notes every time after,
 *       then those notes, four numbers each: the frame it starts on, its pitch in Hz (0 is a
 *       rest), its volume, and the ticks it lasts on its voice's clock (one wave, or one step
 *       of the hiss)
 *
 * A part has two lists because a song that loops from part way through plays its introduction
 * once: the first list is the whole part, the second what it plays each time it comes round
 * (worked out once, for every backend, by IR::Tunes.loop_passes).
 *
 * rg_game_beeps: how many beeps there are, then four numbers a beep — the ticks one wave lasts,
 * eighths high, the volume it starts at, and the 64ths of a second it holds each step of volume
 * as it fades (0 never fades).
 *
 * rg_game_waves: how many different things the game tells the wave voice to play, then three
 * numbers each — which waveform, the ticks one wave lasts, and its loudness in quarters.
 *
 * rg_game_hits: how many different hits the game makes on the noise voice, then four numbers
 * each — the ticks one step of the hiss lasts, the bits in its row, the volume it starts at, and
 * the 64ths of a second it holds each step of volume as it fades.
 */
#include <stdarg.h>
#include <stdio.h>
#include "rg_sound.h"
#include "rg_driver.h"
#include "rg_runtime.h"

/* A song has at most a part for each voice — the build refuses one with more. */
#define PARTS_MOST 4
#define NUMBERS_PER_NOTE 4
#define NUMBERS_PER_BEEP 4
#define NUMBERS_PER_WAVE 3
#define NUMBERS_PER_HIT 4
#define BEEP_VOICE 2
#define WAVE_STEPS 32
#define VOLUMES 16

/* The kinds of part, by the number the lowering writes for each. */
#define PART_SQUARE 0
#define PART_WAVE 1
#define PART_NOISE 2

/* Where things are in rg_game_sound_rules and rg_game_music (see the layouts above). */
#define SQUARE_CLOCK_HZ (rg_game_sound_rules[0])
#define WAVE_CLOCK_HZ (rg_game_sound_rules[1])
#define NOISE_CLOCK_HZ (rg_game_sound_rules[2])
#define OUTPUT_HZ (rg_game_sound_rules[3])
#define FULL_LEVEL (rg_game_sound_rules[4])
#define LEVEL_SHIFT (rg_game_sound_rules[5])
#define WAVE_QUARTERS 6
#define SONG_COUNT (rg_game_music[0])
#define SONG_STARTS 1
#define NUMBERS_PER_SONG 4
#define NUMBERS_PER_PART 6

/* How much one step of loudness moves the speaker. Two voices at their loudest then swing
 * through half of what a sample can hold. All four at once, at their loudest, can ask for more
 * than a sample holds, and the sum is then held at the end of what it can (see
 * rg_sound_render_frame). */
#define STEP_SIZE 1092

/* The console's clock for one frame, as rg_sdl.c has it: 280,896 ticks of a 2^24-a-second clock.
 * A frame's samples are that share of a second's, and the part of a sample left over is carried
 * to the next frame so no time is lost or made up. */
#define FRAME_TICKS 280896
#define TICKS_A_SECOND_BITS 24

/* --- a loudness that fades --- */

/* The loudness of a square voice or the noise voice: 0 to 15 now, and how it fades. */
typedef struct {
  int32_t volume;       /* 0 to 15, now */
  int32_t hold_samples; /* samples it holds each step of volume for; 0 never fades */
  int32_t left;         /* samples until the next step down */
} fading_volume;

static fading_volume volume_from(int32_t volume, int32_t fade_64ths) {
  int32_t hold = fade_64ths * RG_SOUND_RATE / 64;
  return (fading_volume){volume, hold, hold};
}

/* One sample has gone by. */
static void fade_one_sample(fading_volume *fading) {
  if (fading->hold_samples > 0 && fading->volume > 0 && --fading->left == 0) {
    fading->volume--;
    fading->left = fading->hold_samples;
  }
}

/* --- the square voices --- */

typedef struct {
  int32_t wave_ticks;      /* ticks one wave lasts; 0 when the voice has nothing to play */
  int32_t eighths_high;    /* how many eighths of the wave are high */
  fading_volume loudness;
  int32_t eighth;          /* which eighth of the wave it is in */
  int64_t eighth_progress; /* how far through that eighth, in ticks times samples a second */
} square_voice;

static square_voice squares[RG_SQUARE_VOICES];
static int32_t heard_only; /* a test listening to one voice: its number, or 0 for every voice */
static uint64_t sample_carry; /* the fraction of a sample left over from the last frame */

/* A voice starts a note from the top of its wave. No ticks, or no volume, is silence. */
static void square_start(int32_t voice, int32_t wave_ticks, int32_t eighths_high, int32_t volume, int32_t fade_64ths) {
  square_voice *square = &squares[voice - 1];
  square->wave_ticks = wave_ticks;
  square->eighths_high = eighths_high;
  square->loudness = volume_from(volume, fade_64ths);
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
  if (square->wave_ticks == 0 || square->loudness.volume == 0) return 0;

  int32_t high = eighth_is_high(square->eighths_high, square->eighth);
  int32_t sample = STEP_SIZE * square->loudness.volume * (high ? 8 - square->eighths_high : -square->eighths_high) / 8;

  /* An eighth of a wave lasts wave_ticks / 8 ticks, and a sample lasts the clock's ticks a
   * second over the samples a second: kept as whole numbers by counting in ticks times samples
   * a second. */
  int64_t eighth_length = (int64_t)square->wave_ticks * RG_SOUND_RATE;
  square->eighth_progress += (int64_t)SQUARE_CLOCK_HZ * 8;
  while (square->eighth_progress >= eighth_length) {
    square->eighth_progress -= eighth_length;
    square->eighth = (square->eighth + 1) & 7;
  }
  fade_one_sample(&square->loudness);
  return sample;
}

/* --- the wave voice --- */

typedef struct {
  int32_t steps[WAVE_STEPS]; /* the waveform it loops, each step 0 to 15 */
  int32_t switched_on;       /* off, it is silent whatever it is told to play */
  int32_t wave_ticks;        /* ticks all its steps last; 0 when the voice has nothing to play */
  int32_t quarters;          /* its loudness: how many quarters of each step it keeps, 0 to 4 */
  int32_t cut_sum;           /* every step at that loudness, added up */
  int32_t step;              /* which step it is on */
  int64_t step_progress;     /* how far through that step, in ticks times samples a second */
} wave_voice;

static wave_voice wave;

/* A step at the voice's loudness: so many quarters of it, and what does not divide is dropped. */
static int32_t wave_step_cut(int32_t step) { return (step * wave.quarters) / 4; }

/* The voice's loudness is now +quarters+, whatever it is playing. */
static void wave_set_loudness(int32_t quarters) {
  wave.quarters = quarters;
  wave.cut_sum = 0;
  for (int32_t i = 0; i < WAVE_STEPS; i++) wave.cut_sum += wave_step_cut(wave.steps[i]);
}

/* Waveform number +which+ goes into the voice, which switches it on. It plays nothing until its
 * next note: putting a waveform in stops whatever the voice was playing. */
static void wave_load(int32_t which) {
  if (which < 0 || which >= rg_game_waveforms[0]) rg_fault("there is no waveform number %d", (int)which);
  const int32_t *steps = &rg_game_waveforms[1 + (which * WAVE_STEPS)];
  for (int32_t i = 0; i < WAVE_STEPS; i++) wave.steps[i] = steps[i];
  wave.switched_on = 1;
  wave.wave_ticks = 0;
  wave_set_loudness(wave.quarters);
}

/* The voice starts a note from the top of its waveform — if it is switched on. */
static void wave_start(int32_t wave_ticks, int32_t quarters) {
  wave.wave_ticks = wave.switched_on ? wave_ticks : 0;
  wave.step = 0;
  wave.step_progress = 0;
  wave_set_loudness(quarters);
}

static void wave_switch_off(void) {
  wave.switched_on = 0;
  wave.wave_ticks = 0;
}

/* One sample of the voice. Each step is set either side of the middle of the whole waveform at
 * this loudness, so a wave averages nought whatever its shape, as a square voice's does. */
static int32_t wave_sample(void) {
  if (wave.wave_ticks == 0) return 0;

  int32_t sample = STEP_SIZE * ((WAVE_STEPS * wave_step_cut(wave.steps[wave.step])) - wave.cut_sum) / WAVE_STEPS;

  /* A step lasts wave_ticks / 32 ticks: counted, like a square voice's eighth, in ticks times
   * samples a second. */
  int64_t step_length = (int64_t)wave.wave_ticks * RG_SOUND_RATE;
  wave.step_progress += (int64_t)WAVE_CLOCK_HZ * WAVE_STEPS;
  while (wave.step_progress >= step_length) {
    wave.step_progress -= step_length;
    wave.step = (wave.step + 1) % WAVE_STEPS;
  }
  return sample;
}

/* --- the noise voice --- */

typedef struct {
  int32_t step_ticks;    /* ticks one step of the hiss lasts; 0 when the voice has nothing to play */
  int32_t bits;          /* how many bits are in the row */
  uint32_t row;          /* the row of bits */
  int32_t high;          /* which way the last bit to fall off left the voice */
  int32_t heard_high;    /* ...and which way it stood when the speaker was last handed it */
  fading_volume loudness;
  int64_t row_progress;  /* how far through a step, in ticks times hand-overs a second */
  int64_t hand_progress; /* how far to the next hand-over, in hand-overs times samples a second */
} noise_voice;

static noise_voice hiss;

/* A hit: the row starts with every bit set, and steps from there. No ticks, or no volume, is
 * silence. */
static void noise_start(int32_t step_ticks, int32_t bits, int32_t volume, int32_t fade_64ths) {
  hiss.step_ticks = step_ticks;
  hiss.bits = bits;
  hiss.row = ((uint32_t)1 << bits) - 1;
  hiss.high = 0;
  hiss.heard_high = 0;
  hiss.loudness = volume_from(volume, fade_64ths);
  hiss.row_progress = 0;
  hiss.hand_progress = 0;
}

/* One step of the hiss: the bit at the end falls off and says which way the voice stands, and
 * when it was set it is stirred back into the two places at the other end. That is the whole of
 * what makes the pattern long: every arrangement of the row comes up before any comes again. */
static void noise_step(void) {
  uint32_t fell = hiss.row & 1u;
  hiss.row >>= 1;
  if (fell) hiss.row ^= (uint32_t)3 << (hiss.bits - 2);
  hiss.high = (int32_t)fell;
}

/* One sample of the voice: high and low either side of nought, half the volume each way.
 *
 * The hiss steps on its own clock, however fast, but the speaker is handed it only so many times
 * a second, and hears whichever way it stood then until the next time. A hiss stepping faster
 * than that is heard as those moments and nothing between them — which is the sound the console
 * makes of it, and so the one made here. */
static int32_t noise_sample(void) {
  if (hiss.step_ticks == 0 || hiss.loudness.volume == 0) return 0;

  hiss.hand_progress += OUTPUT_HZ;
  while (hiss.hand_progress >= RG_SOUND_RATE) {
    hiss.hand_progress -= RG_SOUND_RATE;
    int64_t step_length = (int64_t)hiss.step_ticks * OUTPUT_HZ;
    hiss.row_progress += NOISE_CLOCK_HZ;
    while (hiss.row_progress >= step_length) {
      hiss.row_progress -= step_length;
      noise_step();
    }
    hiss.heard_high = hiss.high;
  }
  int32_t sample = STEP_SIZE * hiss.loudness.volume * (hiss.heard_high ? 1 : -1) / 2;
  fade_one_sample(&hiss.loudness);
  return sample;
}

/* --- the sound of a frame --- */

void rg_sound_hear_only(int32_t voice) { heard_only = voice; }

static int32_t heard(int32_t voice, int32_t sample) { return heard_only == 0 || heard_only == voice ? sample : 0; }

int32_t rg_sound_render_frame(int16_t *samples) {
  sample_carry += (uint64_t)RG_SOUND_RATE * FRAME_TICKS;
  int32_t count = (int32_t)(sample_carry >> TICKS_A_SECOND_BITS);
  sample_carry &= ((uint64_t)1 << TICKS_A_SECOND_BITS) - 1;

  for (int32_t i = 0; i < count; i++) {
    int32_t sum = 0; /* every voice moves on, heard or not */
    for (int32_t voice = 1; voice <= RG_SQUARE_VOICES; voice++) sum += heard(voice, square_sample(&squares[voice - 1]));
    sum += heard(RG_WAVE_VOICE, wave_sample());
    sum += heard(RG_NOISE_VOICE, noise_sample());
    if (sum > INT16_MAX) sum = INT16_MAX;
    if (sum < INT16_MIN) sum = INT16_MIN;
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

/* --- the sounds the game makes itself --- */

void rg_sound_enabled(void) { log_sound("enabled"); }

void rg_sound_beep(int32_t which) {
  if (which < 0 || which >= rg_game_beeps[0]) rg_fault("there is no beep number %d", (int)which);
  const int32_t *beep = &rg_game_beeps[1 + (which * NUMBERS_PER_BEEP)];
  log_sound("beep %d", (int)which);
  square_start(BEEP_VOICE, beep[0], beep[1], beep[2], beep[3]);
}

void rg_sound_wave(int32_t which) {
  if (which < 0 || which >= rg_game_waves[0]) rg_fault("there is no wave number %d", (int)which);
  const int32_t *said = &rg_game_waves[1 + (which * NUMBERS_PER_WAVE)];
  log_sound("wave %d", (int)which);
  wave_load(said[0]);
  wave_start(said[1], said[2]);
}

void rg_sound_stop_wave(void) {
  log_sound("stop_wave");
  wave_switch_off();
}

void rg_sound_noise(int32_t which) {
  if (which < 0 || which >= rg_game_hits[0]) rg_fault("there is no hit number %d", (int)which);
  const int32_t *hit = &rg_game_hits[1 + (which * NUMBERS_PER_HIT)];
  log_sound("noise %d", (int)which);
  noise_start(hit[0], hit[1], hit[2], hit[3]);
}

/* --- the player --- */

/* One part of the playing song: the list of notes it is walking now, which comes next, and what
 * it plays them on. */
typedef struct {
  const int32_t *notes;
  int32_t count;
  int32_t next;
  int32_t kind;   /* PART_SQUARE, PART_WAVE or PART_NOISE */
  int32_t voice;  /* the voice it plays on, by the console's count of them */
  int32_t number; /* which of its song's parts it is, which is how the log names it */
  int32_t tone;   /* a square part's eighths high, a wave part's waveform, a noise part's bits */
  int32_t fade;   /* a noise part: the 64ths of a second a hit holds each step of volume */
} part_walk;

/* A note a song's part is holding on a voice: the volume it was written at (0 for a rest), and
 * what it sounds like. Kept here and not read back off the voice, because a beep can borrow the
 * second voice while the part's note is still being held, and it is the part's note the music
 * volume sounds again. A hit on the noise voice is never held: it rings and fades by itself, so
 * a new volume waits for the next hit. */
typedef struct {
  int32_t voice;
  int32_t volume;
  int32_t wave_ticks;
  int32_t eighths_high;
} held_note;

static int32_t wanted = -1;  /* the tune the game last named, or -1 for none */
static int32_t playing = -1; /* ...and the one the player is on, which catches up each frame */
static int32_t ended = -1;   /* a tune that played once and reached its end, or -1 */
static int32_t stops;        /* how many times the game has said stop... */
static int32_t stops_seen;   /* ...and how many of those the player has acted on */

static const int32_t *song; /* the playing song's numbers */
static int32_t song_frame;  /* how far into it, in frames */
static int32_t part_count;
static part_walk parts[PARTS_MOST];

static const int32_t *level_variable; /* where the game keeps its music volume, if it has one */
static int32_t level = -1;            /* the volume the notes sounding were set at (full, at power-on) */

/* The voices holding a note, in the order each first took one since the song started — the order
 * the interpreter's own record keeps, and so the order a change of volume is logged in. */
static held_note holding[PARTS_MOST];
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

/* Every part's list of notes from its start: the first time through, or every time after. The
 * square parts take the square voices in the order they are written; there is one wave voice and
 * one noise voice. */
static void start_walks(int again) {
  const int32_t *part = song + NUMBERS_PER_SONG;
  int32_t squares_met = 0;
  for (int32_t i = 0; i < part_count; i++) {
    int32_t kind = part[0], first = part[4], after = part[5];
    const int32_t *first_notes = part + NUMBERS_PER_PART;
    const int32_t *after_notes = first_notes + (NUMBERS_PER_NOTE * first);
    int32_t voice = kind == PART_WAVE ? RG_WAVE_VOICE : kind == PART_NOISE ? RG_NOISE_VOICE : ++squares_met;
    parts[i] = (part_walk){again ? after_notes : first_notes, again ? after : first, 0, kind, voice, part[1], part[2], part[3]};
    part = after_notes + (NUMBERS_PER_NOTE * after);
  }
  if (squares_met > RG_SQUARE_VOICES) {
    rg_fault("song number %d has %d parts on the square wave, and the most is %d", (int)playing, (int)squares_met,
             RG_SQUARE_VOICES);
  }
}

/* A note's written volume (0 to 15) at the music volume in force: multiplied and shifted back
 * down, so it never rounds up past what was written. */
static int32_t scaled_volume(int32_t volume) { return (volume * level) >> LEVEL_SHIFT; }

/* The wave voice's loudness, in quarters, for a volume of 0 to 15: the nearest of its five. */
static int32_t wave_quarters_at(int32_t volume) {
  if (volume < 0) volume = 0;
  if (volume >= VOLUMES) volume = VOLUMES - 1;
  return rg_game_sound_rules[WAVE_QUARTERS + volume];
}

/* A voice now holds +note+ for its part. */
static void hold_note(held_note note) {
  int32_t at = 0;
  while (at < holding_count && holding[at].voice != note.voice) at++;
  if (at == holding_count) holding_count++;
  holding[at] = note;
  log_sound("loudness %d %d", (int)note.voice, (int)scaled_volume(note.volume));
}

/* The music volume has moved: every voice holding a note takes it. A square voice takes a volume
 * only as a note starts, so the part's note is sounded again at the new one; the wave voice
 * takes one while it plays, so its note carries on. */
static void follow_level(int32_t now) {
  if (now == level) return;
  level = now;
  for (int32_t i = 0; i < holding_count; i++) {
    const held_note *note = &holding[i];
    if (note->volume <= 0) continue;
    log_sound("loudness %d %d", (int)note->voice, (int)scaled_volume(note->volume));
    if (note->voice == RG_WAVE_VOICE) {
      wave_set_loudness(wave_quarters_at(scaled_volume(note->volume)));
    } else {
      square_start(note->voice, note->wave_ticks, note->eighths_high, scaled_volume(note->volume), 0);
    }
  }
}

/* A part's voice goes quiet, the way a rest on it does: a square voice and the noise voice with
 * nothing to play, the wave voice at no loudness. */
static void rest_on(const part_walk *part) {
  switch (part->kind) {
  case PART_WAVE: wave_set_loudness(0); break;
  case PART_NOISE: noise_start(0, part->tone, 0, 0); break;
  default: square_start(part->voice, 0, 0, 0, 0); break;
  }
}

/* Every voice the playing tune uses goes quiet — its own voices and no others, so a one-part tune
 * ending does not cut off a beep on the second voice — and none of them holds a note any more. */
static void silence_song(void) {
  log_sound("stop_music");
  for (int32_t i = 0; i < part_count; i++) rest_on(&parts[i]);
  holding_count = 0;
}

/* The tune the game asked for has changed, or it said stop: silence what was playing and start
 * the new one from its first frame, with its waveform in the wave voice if it has a part there.
 *
 * A TUNE THAT PLAYED ONCE AND ENDED is looked at first (IR::Tunes.plays_once? has the rule every
 * backend keeps). While the game still names it and has not said stop, nothing plays: its parts
 * go quiet on the frame after its last, and it stays that way. Anything else the game says —
 * another tune, no tune, or a stop and the same tune named again — forgets the end, and is then
 * caught up with as usual, which for the same tune is from its first note. */
static void switch_to_wanted_song(void) {
  if (ended >= 0) {
    if (wanted == ended && stops == stops_seen) {
      if (playing >= 0) silence_song();
      playing = -1;
      return;
    }
    ended = -1;
  }
  if (wanted == playing && stops == stops_seen) return;

  stops_seen = stops;
  if (playing >= 0) silence_song();
  playing = wanted;
  song_frame = 0;
  part_count = 0;
  if (playing < 0) return;

  song = &rg_game_music[rg_game_music[SONG_STARTS + playing]];
  part_count = song[3];
  if (part_count > PARTS_MOST) {
    rg_fault("song number %d has %d parts, and the most is %d", (int)playing, (int)part_count, PARTS_MOST);
  }
  start_walks(0);
  for (int32_t i = 0; i < part_count; i++) {
    if (parts[i].kind != PART_WAVE) continue;
    wave_load(parts[i].tone);
    break;
  }
}

/* One note of a part, due on this frame: said in the log the way the interpreter's player says
 * it, and started on the part's voice. */
static void play_note(part_walk *part, const int32_t *note) {
  int32_t pitch = note[1], volume = note[2], ticks = note[3];
  int32_t written = pitch == 0 ? 0 : volume;
  int32_t sounded = level_variable ? scaled_volume(written) : written;
  log_sound("note %d %d", (int)playing, (int)pitch);
  log_sound("voice %d %d %d %d", (int)part->voice, (int)playing, (int)pitch, (int)volume);
  switch (part->kind) {
  case PART_WAVE:
    if (level_variable) hold_note((held_note){part->voice, written, 0, 0});
    if (pitch == 0) {
      log_sound("stop_wave");
      rest_on(part);
    } else {
      log_sound("part_wave %d %d %d", (int)playing, (int)part->number, (int)pitch);
      wave_start(ticks, wave_quarters_at(sounded));
    }
    break;
  case PART_NOISE:
    if (level_variable) log_sound("loudness %d %d", (int)part->voice, (int)sounded);
    if (pitch == 0) {
      log_sound("noise_rest");
      rest_on(part);
    } else {
      log_sound("part_noise %d %d %d", (int)playing, (int)part->number, (int)pitch);
      noise_start(ticks, part->tone, sounded, part->fade);
    }
    break;
  default:
    if (level_variable) hold_note((held_note){part->voice, written, ticks, part->tone});
    square_start(part->voice, ticks, part->tone, sounded, 0);
    break;
  }
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

    play_note(part, note);
    part->next++;
  }

  song_frame++;
  if (song_frame < song[0]) return;
  if (song[2]) {
    /* A tune that plays once goes no further: its last frame's notes sound for that frame, and
     * the next frame is the one its parts go quiet on. */
    ended = playing;
    return;
  }
  song_frame = song[1];
  start_walks(1);
}
