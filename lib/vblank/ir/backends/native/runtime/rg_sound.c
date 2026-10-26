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
 * (IR::Tunes::FULL_LEVEL and LEVEL_SHIFT); sixteen numbers, the wave voice's loudness in
 * quarters for each volume from 0 to 15; and the part of a rank that is a sound effect's order
 * (IR::Tunes::ORDER_MASK), nought for the song.
 *
 * rg_game_effects: how many sound effects there are, 1 if any of them plays the wave voice (see
 * wave_put_in), then five numbers each, in the order they were declared — the song it plays (by
 * which the log names it), which entry of rg_game_music holds its notes, its rank
 * (IR::Tunes.effect_rank), its group (-1 for none, else which of the game's groups), and its
 * priority (IR::Tunes.priority_of) — then every effect's number again, highest rank first
 * (IR::Tunes.effects_by_rank). An effect plays its parts' notes once each as written, so only the
 * first list of each part of its entry is walked.
 *
 * rg_game_waveforms: how many waveforms there are, then 32 steps for each.
 *
 * rg_game_music:
 *
 *   how many entries there are — every song, numbered as the log numbers them, and then every
 *   sound effect's notes again, as written, since the same Score played as a tune is put right for
 *   coming round and an effect never comes round — then where each entry starts in the array,
 *   then each entry:
 *     total frames, the frame it loops from, 1 if it plays once and ends, its rank
 *     (IR::Tunes.song_rank: who gives way on the mixer), how many parts,
 *     then each part:
 *       the kind of voice it plays on (0 square, 1 wave, 2 noise, 3 a recording on the mixer),
 *       which of its song's parts it is, two numbers for what the voice sounds like — a square
 *       part's eighths high and 0, a wave part's waveform and 0, a noise part's bits and the
 *       64ths of a second it holds each step of volume, a recorded part's lane (which of the
 *       song's recorded parts it is) and 0 — notes the first time through, notes every time
 *       after,
 *       then those notes, four numbers each: the frame it starts on, which of the songs' pitches
 *       it is (0 is a rest; a pitch need not be a whole number of Hz, so the log is given the
 *       number and reads the pitch back from it), its volume, and the ticks it lasts on its
 *       voice's clock (one wave, or one step of the hiss) — or, on a recorded part, which row of
 *       rg_game_note_sounds it sounds (-1 for a rest)
 *
 * rg_game_note_sounds: how many rows, then eight numbers each — the recording a note plays, how
 * far through it the mixer reads for each of its own samples (the note's pitch), how far back it
 * reads at the recording's end, and the note's shape: 1 if it has one, then its four numbers.
 * The note's own shape, else its part's, else its recording's; everything a recorded note is,
 * but how loud.
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
#include <stdbool.h>
#include <stdio.h>
#include "rg_sound.h"
#include "rg_driver.h"
#include "rg_mix.h"
#include "rg_runtime.h"

/* A song has at most a part for each of the console's own voices and one for each of the mixer's:
 * a game is checked the way a cartridge build checks it, and that refuses a song with more. */
#define PARTS_MOST 20
#define NUMBERS_PER_NOTE 4
#define NUMBERS_PER_NOTE_SOUND 8
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
#define PART_RECORDED 3

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
#define NUMBERS_PER_SONG 5
#define NUMBERS_PER_PART 6
#define EFFECT_COUNT (rg_game_effects[0])
#define EFFECTS_PLAY_WAVE (rg_game_effects[1])
#define EFFECT_ROWS 2
#define NUMBERS_PER_EFFECT 5
/* Each effect's numbers in rg_game_effects, by where they are in its row. */
#define EFFECT_SONG 0
#define EFFECT_NOTES 1
#define EFFECT_RANK 2
#define EFFECT_GROUP 3
#define EFFECT_PRIORITY 4
/* Room for every sound effect a game has, each keeping where it is: a game's own effects are a
 * handful, and a cartridge's whole set of sequences, decoded, is a few hundred. More stops the
 * program, saying so. */
#define EFFECTS_MOST 512

/* How much one step of loudness moves the speaker. Two voices at their loudest then swing
 * through half of what a sample can hold. All four at once, at their loudest, can ask for more
 * than a sample holds, and the sum is then held at the end of what it can (see
 * rg_sound_render_frame). */
#define STEP_SIZE 1092

/* How much one step of the mixer's byte moves the speaker: its loudest, 127, is about half of
 * what a sample holds, as two console voices at their loudest are. */
#define MIX_STEP 128

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
/* Which waveform a player last put in the voice, or -1 once the game's own `wave` or `stop_wave`
 * has been there since (see wave_put_in). */
static int32_t loaded_waveform = -1;

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
  loaded_waveform = which;
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
 * silence.
 *
 * Where a hit starts in its pattern is the emulator's answer. The pattern is one long loop and
 * the same loop wherever it is picked up, so the start is all there is to choose, and every bit
 * set is where the emulator this sound is checked against picks it up. */
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

  /* The mixer's newest slice, at the mix's own rate, is stretched over the frame: each sample the
   * speaker plays holds the slice's sample at the same point of the frame, as the console's
   * stream holds each sample until the next. It is heard only with every voice. */
  const int32_t *mixed;
  int32_t mixed_count = heard_only == 0 ? rg_mix_newest_slice(&mixed) : 0;

  for (int32_t i = 0; i < count; i++) {
    int32_t sum = 0; /* every voice moves on, heard or not */
    for (int32_t voice = 1; voice <= RG_SQUARE_VOICES; voice++) sum += heard(voice, square_sample(&squares[voice - 1]));
    sum += heard(RG_WAVE_VOICE, wave_sample());
    sum += heard(RG_NOISE_VOICE, noise_sample());
    if (mixed_count > 0) sum += mixed[(int64_t)i * mixed_count / count] * MIX_STEP;
    /* Past what a sample holds, it is held at the end: left to wrap, the loudest moment of a
     * game would come out as a jump to the other side of nought. */
    if (sum > INT16_MAX) sum = INT16_MAX;
    if (sum < INT16_MIN) sum = INT16_MIN;
    samples[i] = (int16_t)sum;
  }
  return count;
}

/* --- the log --- */

void rg_sound_log(const char *format, ...) {
  char line[64];
  va_list args;
  va_start(args, format);
  vsnprintf(line, sizeof line, format, args);
  va_end(args);
  rg_active_driver->sound_logged(line);
}

/* --- the sounds the game makes itself --- */

void rg_sound_enabled(void) { rg_sound_log("enabled"); }

void rg_sound_beep(int32_t which) {
  if (which < 0 || which >= rg_game_beeps[0]) rg_fault("there is no beep number %d", (int)which);
  const int32_t *beep = &rg_game_beeps[1 + (which * NUMBERS_PER_BEEP)];
  rg_sound_log("beep %d", (int)which);
  square_start(BEEP_VOICE, beep[0], beep[1], beep[2], beep[3]);
}

void rg_sound_wave(int32_t which) {
  if (which < 0 || which >= rg_game_waves[0]) rg_fault("there is no wave number %d", (int)which);
  const int32_t *said = &rg_game_waves[1 + (which * NUMBERS_PER_WAVE)];
  rg_sound_log("wave %d", (int)which);
  wave_load(said[0]);
  wave_start(said[1], said[2]);
  loaded_waveform = -1; /* no player's waveform is there now (see wave_put_in) */
}

void rg_sound_stop_wave(void) {
  rg_sound_log("stop_wave");
  wave_switch_off();
  loaded_waveform = -1;
}

void rg_sound_noise(int32_t which) {
  if (which < 0 || which >= rg_game_hits[0]) rg_fault("there is no hit number %d", (int)which);
  const int32_t *hit = &rg_game_hits[1 + (which * NUMBERS_PER_HIT)];
  rg_sound_log("noise %d", (int)which);
  noise_start(hit[0], hit[1], hit[2], hit[3]);
}

/* --- the player --- */

/* One part of the playing song: the list of notes it is walking now, which comes next, and what
 * it plays them on. */
typedef struct {
  const int32_t *notes;
  int32_t count;
  int32_t next;
  int32_t kind;   /* PART_SQUARE, PART_WAVE, PART_NOISE or PART_RECORDED */
  int32_t voice;  /* the voice it plays on, by the console's count of them; 0 for a recorded part */
  int32_t number; /* which of its song's parts it is, which is how the log names it */
  int32_t tone;   /* a square part's eighths high, a wave part's waveform, a noise part's bits, a
                   * recorded part's lane: which of the song's recorded parts it is */
  int32_t fade;   /* a noise part: the 64ths of a second a hit holds each step of volume */
} part_walk;

/* A note a song's part is holding on a voice: the volume it was written at (0 for a rest), and
 * what it sounds like. Kept here and not read back off the voice, because a beep can borrow the
 * second voice while the part's note is still being held, and it is the part's note the music
 * volume sounds again. A hit on the noise voice is never held: it rings and fades by itself, so
 * a new volume waits for the next hit. A recorded part's note is held on the mixer, by its lane,
 * and its volume is a loudness out of 512. */
typedef struct {
  int32_t voice; /* a console voice, or 0 for the mixer */
  int32_t lane;  /* a recorded part's lane, for the mixer */
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

void rg_music_request_one_of(const int32_t *songs, int32_t count, int32_t which) {
  if (which >= 0 && which < count) rg_music_request(songs[which]);
}

void rg_music_stop(void) {
  wanted = -1;
  stops++;
}

void rg_music_follow_level(const int32_t *variable) { level_variable = variable; }

/* Song number +number+'s numbers, from its length on. */
static const int32_t *song_numbers(int32_t number) { return &rg_game_music[rg_game_music[SONG_STARTS + number]]; }

/* The part of song number +number+ written at +part+, as a walk of its notes from their start:
 * the first time through, or every time after. Hands back where the song's next part is written.
 * The square parts take the square voices in the order they are written (+squares_met+ counts
 * them); there is one wave voice and one noise voice; a recorded part takes no console voice,
 * and the mixer finds it one a note at a time. */
static const int32_t *read_part(int32_t number, const int32_t *part, int again, int32_t *squares_met, part_walk *walk) {
  int32_t kind = part[0], first = part[4], after = part[5];
  const int32_t *first_notes = part + NUMBERS_PER_PART;
  const int32_t *after_notes = first_notes + (NUMBERS_PER_NOTE * first);
  int32_t voice = kind == PART_WAVE      ? RG_WAVE_VOICE
                  : kind == PART_NOISE    ? RG_NOISE_VOICE
                  : kind == PART_RECORDED ? 0
                                          : ++*squares_met;
  if (*squares_met > RG_SQUARE_VOICES) {
    rg_fault("song number %d has more parts on the square wave than the %d there are", (int)number, RG_SQUARE_VOICES);
  }
  *walk = (part_walk){again ? after_notes : first_notes, again ? after : first, 0, kind, voice, part[1], part[2], part[3]};
  return after_notes + (NUMBERS_PER_NOTE * after);
}

/* Every part of the playing song, walked from its start. */
static void start_walks(int again) {
  const int32_t *part = song + NUMBERS_PER_SONG;
  int32_t squares_met = 0;
  for (int32_t i = 0; i < part_count; i++) part = read_part(playing, part, again, &squares_met, &parts[i]);
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

/* The log's line for a note held at +volume+ at the music volume in force: a console voice by its
 * number, a recorded part by its lane on the mixer. */
static void log_held_loudness(const held_note *note) {
  if (note->voice == 0) {
    rg_sound_log("mixer_loudness %d %d", (int)note->lane, (int)scaled_volume(note->volume));
  } else {
    rg_sound_log("loudness %d %d", (int)note->voice, (int)scaled_volume(note->volume));
  }
}

/* A voice now holds +note+ for its part. */
static void hold_note(held_note note) {
  int32_t at = 0;
  while (at < holding_count && (holding[at].voice != note.voice || (note.voice == 0 && holding[at].lane != note.lane))) at++;
  if (at == holding_count) holding_count++;
  holding[at] = note;
  log_held_loudness(&note);
}

/* The music volume has moved: every voice holding a note takes it. A square voice takes a volume
 * only as a note starts, so the part's note is sounded again at the new one; the wave voice and a
 * mixer voice take one while they play, so their notes carry on — a recorded part's only while
 * the mixer is still sounding it, since its recording may have run out or its note be falling
 * away after a rest. */
static void follow_level(int32_t now) {
  if (now == level) return;
  level = now;
  for (int32_t i = 0; i < holding_count; i++) {
    const held_note *note = &holding[i];
    if (note->volume <= 0) continue;
    if (note->voice == 0 && !rg_mix_rescale_music(note->lane, scaled_volume(note->volume))) continue;
    log_held_loudness(note);
    if (note->voice == 0) continue;
    if (note->voice == RG_WAVE_VOICE) {
      wave_set_loudness(wave_quarters_at(scaled_volume(note->volume)));
    } else {
      square_start(note->voice, note->wave_ticks, note->eighths_high, scaled_volume(note->volume), 0);
    }
  }
}

/* A console voice goes quiet, the way a rest on it does: a square voice and the noise voice with
 * nothing to play, the wave voice at no loudness. */
static void silence_voice(int32_t voice) {
  switch (voice) {
  case RG_WAVE_VOICE: wave_set_loudness(0); break;
  case RG_NOISE_VOICE: noise_start(0, hiss.bits, 0, 0); break;
  default: square_start(voice, 0, 0, 0, 0); break;
  }
}

/* A part rests: its console voice goes quiet. A recorded part's rest is the mixer's. */
static void rest_on(const part_walk *part) {
  if (part->kind != PART_RECORDED) silence_voice(part->voice);
}

/* --- who holds a console voice --- */

/* A console voice a song and the sound effects share is held by whoever last wrote a note there
 * that sounds, by their rank (IR::Tunes.song_rank and effect_rank): a note takes the voice when
 * nobody holding it outranks it, and a rest or a note at volume 0 lets it go. Nobody is rank 0. The
 * voices are kept in the order each was first written, which is the order an effect's end lets
 * them go in (Reference::Player#finish_effect). */
#define ORDER_MASK (rg_game_sound_rules[WAVE_QUARTERS + VOLUMES])
static int32_t holders[RG_NOISE_VOICE + 1];
static int32_t holder_order[RG_NOISE_VOICE];
static int32_t holder_count;

static int32_t claim_voice(int32_t voice, int32_t rank, int32_t sounds) {
  if (holders[voice] > rank) return 0;

  int32_t known = 0;
  for (int32_t i = 0; i < holder_count; i++) known |= holder_order[i] == voice;
  if (!known) holder_order[holder_count++] = voice;
  holders[voice] = sounds ? rank : 0;
  return 1;
}

/* Does a note on a console voice make a sound? Not a rest, and not at volume 0 — nor, on the wave
 * voice, at a volume whose nearest of that voice's five is none. */
static int32_t note_sounds(int32_t kind, int32_t pitch, int32_t volume) {
  if (pitch == 0 || volume <= 0) return 0;
  return kind != PART_WAVE || wave_quarters_at(volume) != 0;
}

/* A NOTE IN ITS OWN WAVEFORM, in a game whose sound effects play the wave voice. The tune and an
 * effect can each want theirs in the voice, which holds one, so a note there — not a rest — puts
 * its own in first when another is there, switching the voice on, as the console's player does.
 * Nothing is put in as a tune starts, since an effect may hold the voice then; and the game's own
 * `wave` and `stop_wave` leave no player's waveform there, so the next note puts its own back.
 * A game whose effects never play the wave voice keeps the plain rule instead: a tune puts its
 * waveform in as it starts, and its notes play whatever is there. */
static void wave_put_in(int32_t which) {
  if (which == loaded_waveform) return;
  wave_load(which);
}

/* Every voice the playing tune uses goes quiet — its own voices and no others, so a one-part tune
 * ending does not cut off a beep on the second voice, nor a note of a sound effect holding one —
 * and none of them holds a note any more. Its notes on the mixer end, a shaped one falling away. */
static void silence_song(void) {
  rg_sound_log("stop_music");
  for (int32_t i = 0; i < part_count; i++) {
    if (parts[i].kind == PART_RECORDED || (holders[parts[i].voice] & ORDER_MASK) != 0) continue;
    rest_on(&parts[i]);
  }
  for (int32_t voice = 1; voice <= RG_NOISE_VOICE; voice++) {
    if ((holders[voice] & ORDER_MASK) == 0) holders[voice] = 0;
  }
  holding_count = 0;
  rg_mix_release_all_music();
}

/* The tune the game asked for has changed, or it said stop: silence what was playing and start
 * the new one from its first frame — with its waveform in the wave voice if it has a part there,
 * unless the game's sound effects play that voice too, when each note puts its own in instead
 * (see wave_put_in).
 *
 * A TUNE THAT PLAYED ONCE AND ENDED is looked at first (IR::Tunes.plays_once? has the rule every
 * backend keeps). While the game still names it and has not said stop, nothing plays: its parts
 * go quiet on the frame after its last, and it stays that way. Anything else the game says —
 * another tune, no tune, or a stop and the same tune named again — forgets the end, and is then
 * caught up with as usual, which for the same tune is from its first note.
 *
 * True when it changed what is playing. */
static bool switch_to_wanted_song(void) {
  if (ended >= 0) {
    if (wanted == ended && stops == stops_seen) {
      if (playing >= 0) silence_song();
      playing = -1;
      return false;
    }
    ended = -1;
  }
  if (wanted == playing && stops == stops_seen) return false;

  stops_seen = stops;
  if (playing >= 0) silence_song();
  playing = wanted;
  song_frame = 0;
  part_count = 0;
  if (playing < 0) return true;

  song = song_numbers(playing);
  part_count = song[4];
  if (part_count > PARTS_MOST) {
    rg_fault("song number %d has %d parts, and the most is %d", (int)playing, (int)part_count, PARTS_MOST);
  }
  start_walks(0);
  if (EFFECTS_PLAY_WAVE) return true; /* each note puts its own waveform in (see wave_put_in) */
  for (int32_t i = 0; i < part_count; i++) {
    if (parts[i].kind != PART_WAVE) continue;
    wave_load(parts[i].tone);
    break;
  }
  return true;
}

/* A note of a part that plays a recording, due on this frame (Reference::Player#play_song_frame's
 * recorded branch). Its loudness on the mixer, out of 512, is written in the note itself (see
 * IR::Tunes.mix_loudness), since a recorded note's volume can hold a fraction. A note that makes
 * no sound — a rest, or one at loudness 0 — lets the part's voice go and is heard; one that does
 * is heard only if the mixer found it a voice, and a note that was not heard is not logged at
 * all: the part carries on in time, silent there. Its loudness follows the music volume when the
 * game keeps one. */
static void play_recorded_note(const part_walk *part, const int32_t *note) {
  int32_t pitch = note[1], loudness = note[2], sound = note[3];
  if (pitch == 0 || loudness <= 0) {
    rg_mix_release_music(-1, part->tone);
  } else {
    const int32_t *numbers = &rg_game_note_sounds[1 + (sound * NUMBERS_PER_NOTE_SOUND)];
    if (!rg_mix_start_music_note(-1, part->tone, song[3], numbers, level_variable ? scaled_volume(loudness) : loudness)) {
      return;
    }
  }
  rg_sound_log("note %d %d", (int)playing, (int)pitch);
  if (level_variable) hold_note((held_note){0, part->tone, pitch == 0 ? 0 : loudness, 0, 0});
}

/* One note of a part, due on this frame: said in the log the way the interpreter's player says
 * it, and started on the part's voice — when the song may have the voice: a sound effect ranked
 * above it holding the voice keeps it, and the note is not played (the part carries on in time,
 * silent there). */
static void play_note(part_walk *part, const int32_t *note) {
  if (part->kind == PART_RECORDED) {
    play_recorded_note(part, note);
    return;
  }

  int32_t pitch = note[1], volume = note[2], ticks = note[3];
  if (!claim_voice(part->voice, song[3], note_sounds(part->kind, pitch, volume))) return;

  int32_t written = pitch == 0 ? 0 : volume;
  int32_t sounded = level_variable ? scaled_volume(written) : written;
  rg_sound_log("note %d %d", (int)playing, (int)pitch);
  rg_sound_log("voice %d %d %d %d", (int)part->voice, (int)playing, (int)pitch, (int)volume);
  switch (part->kind) {
  case PART_WAVE:
    if (level_variable) hold_note((held_note){part->voice, 0, written, 0, 0});
    if (pitch == 0) {
      rg_sound_log("stop_wave");
      rest_on(part);
    } else {
      rg_sound_log("part_wave %d %d %d", (int)playing, (int)part->number, (int)pitch);
      if (EFFECTS_PLAY_WAVE) wave_put_in(part->tone);
      wave_start(ticks, wave_quarters_at(sounded));
    }
    break;
  case PART_NOISE:
    if (level_variable) rg_sound_log("loudness %d %d", (int)part->voice, (int)sounded);
    if (pitch == 0) {
      rg_sound_log("noise_rest");
      rest_on(part);
    } else {
      rg_sound_log("part_noise %d %d %d", (int)playing, (int)part->number, (int)pitch);
      noise_start(ticks, part->tone, sounded, part->fade);
    }
    break;
  default:
    if (level_variable) hold_note((held_note){part->voice, 0, written, ticks, part->tone});
    square_start(part->voice, ticks, part->tone, sounded, 0);
    break;
  }
}

/* --- sound effects --- */

/* Every sound effect's state, by its number. An effect is a song played once over the tune,
 * walking its parts as a song does, from its first note each time it is asked for. */
static uint8_t effect_asked[EFFECTS_MOST];     /* asked for since the last frame */
static uint8_t effect_asked_now[EFFECTS_MOST]; /* ...as this frame found it */
static uint8_t effect_stopping[EFFECTS_MOST];  /* cut off by another of its group, on this frame */
static uint8_t effect_running[EFFECTS_MOST];
static int32_t effect_frame[EFFECTS_MOST];
static int32_t effect_cursors[EFFECTS_MOST][PARTS_MOST];

static const int32_t *effect_row(int32_t effect) { return &rg_game_effects[EFFECT_ROWS + (effect * NUMBERS_PER_EFFECT)]; }

/* Is this effect its group's one now: asked for — even when it is stopping first, to start again
 * — or sounding and not stopping? */
static int32_t effect_pending(int32_t effect) {
  return effect_asked[effect] || (effect_running[effect] && !effect_stopping[effect]);
}

static void refuse_too_many_effects(void) {
  if (EFFECT_COUNT > EFFECTS_MOST) rg_fault("the game has %d sound effects, and the most is %d", (int)EFFECT_COUNT, EFFECTS_MOST);
}

/* START effect number +effect+ at the next frame, from its first note, whether or not it is
 * sounding already (Reference::Player#request_effect). If another of its GROUP is sounding or
 * already asked for — the first of them, in the order they were declared — one of lower priority
 * is not played, and one of at least that priority stops that one on the next frame and starts in
 * its place. */
static void request_effect(int32_t effect) {
  refuse_too_many_effects();
  const int32_t *row = effect_row(effect);
  if (row[EFFECT_GROUP] >= 0) {
    for (int32_t other = 0; other < EFFECT_COUNT; other++) {
      const int32_t *other_row = effect_row(other);
      if (other_row[EFFECT_GROUP] != row[EFFECT_GROUP] || !effect_pending(other)) continue;
      if (row[EFFECT_PRIORITY] < other_row[EFFECT_PRIORITY]) return;
      effect_asked[other] = 0;
      effect_stopping[other] = 1;
      break;
    }
  }
  effect_asked[effect] = 1;
}

void rg_effect_request_one_of(const int32_t *effects, int32_t count, int32_t which) {
  if (which >= 0 && which < count) request_effect(effects[which]);
}

/* The song's note held on +voice+, if it has one, is gone: a sound effect has written the voice,
 * so a change of music volume leaves it alone. */
static void drop_held_note(int32_t voice) {
  int32_t kept = 0;
  for (int32_t i = 0; i < holding_count; i++) {
    if (holding[i].voice != voice) holding[kept++] = holding[i];
  }
  holding_count = kept;
}

/* An effect over (Reference::Player#finish_effect): every console voice it still holds goes quiet
 * and is free, in the order each was first written, and its notes on the mixer end, a shaped one
 * falling away as it would at a rest. */
static void finish_effect(int32_t effect) {
  const int32_t *row = effect_row(effect);
  int32_t number = row[EFFECT_SONG], rank = row[EFFECT_RANK];
  effect_running[effect] = 0;
  for (int32_t i = 0; i < holder_count; i++) {
    int32_t voice = holder_order[i];
    if (holders[voice] != rank) continue;
    holders[voice] = 0;
    rg_sound_log("note %d 0", (int)number);
    rg_sound_log("voice %d %d 0 0", (int)voice, (int)number);
    if (voice == RG_NOISE_VOICE) rg_sound_log("noise_rest");
    if (voice == RG_WAVE_VOICE) rg_sound_log("stop_wave");
    silence_voice(voice);
  }

  const int32_t *numbers = song_numbers(row[EFFECT_NOTES]);
  const int32_t *part = numbers + NUMBERS_PER_SONG;
  int32_t squares_met = 0;
  for (int32_t i = 0; i < numbers[4]; i++) {
    part_walk walk;
    part = read_part(number, part, 0, &squares_met, &walk);
    if (walk.kind == PART_RECORDED && rg_mix_release_music(effect, walk.tone)) rg_sound_log("note %d 0", (int)number);
  }
}

/* One note of an effect's part, due on this frame. A recorded note sounds on a voice of the mixer
 * at its own volume (an effect is not the music), and is logged only if it was heard. A note on a
 * console voice is played if the effect's rank lets it take the voice, at its written volume. */
static void play_effect_note(int32_t effect, const part_walk *part, const int32_t *note) {
  const int32_t *row = effect_row(effect);
  int32_t number = row[EFFECT_SONG], rank = row[EFFECT_RANK];
  int32_t pitch = note[1], volume = note[2];
  int32_t sounds = note_sounds(part->kind, pitch, volume);

  if (part->kind == PART_RECORDED) {
    int32_t sound = note[3];    /* its row of rg_game_note_sounds */
    int32_t loudness = note[2]; /* a recorded note's volume is written as its loudness, out of 512 */
    int32_t heard = sounds ? rg_mix_start_music_note(effect, part->tone, rank,
                                                     &rg_game_note_sounds[1 + (sound * NUMBERS_PER_NOTE_SOUND)],
                                                     loudness)
                           : rg_mix_release_music(effect, part->tone);
    if (heard) rg_sound_log("note %d %d", (int)number, (int)pitch);
    return;
  }
  if (!claim_voice(part->voice, rank, sounds)) return;

  int32_t ticks = note[3];
  drop_held_note(part->voice);
  rg_sound_log("note %d %d", (int)number, (int)pitch);
  rg_sound_log("voice %d %d %d %d", (int)part->voice, (int)number, (int)pitch, (int)volume);
  switch (part->kind) {
  case PART_WAVE:
    if (pitch == 0) {
      rg_sound_log("stop_wave");
      silence_voice(part->voice);
    } else {
      rg_sound_log("part_wave %d %d %d", (int)number, (int)part->number, (int)pitch);
      wave_put_in(part->tone);
      wave_start(ticks, wave_quarters_at(volume));
    }
    break;
  case PART_NOISE:
    if (pitch == 0) {
      rg_sound_log("noise_rest");
      silence_voice(part->voice);
    } else {
      rg_sound_log("part_noise %d %d %d", (int)number, (int)part->number, (int)pitch);
      noise_start(ticks, part->tone, volume, part->fade);
    }
    break;
  default: square_start(part->voice, ticks, part->tone, pitch == 0 ? 0 : volume, 0); break;
  }
}

/* ONE SOUND EFFECT'S FRAME (Reference::Player#play_effect_frame). Cut off by another of its group,
 * it stops first. Asked for, it starts from its first note; past its last frame it lets go of
 * what it still holds; and sounding, it plays whatever notes are due. */
static void play_effect_frame(int32_t effect) {
  int32_t number = effect_row(effect)[EFFECT_SONG];
  const int32_t *numbers = song_numbers(effect_row(effect)[EFFECT_NOTES]);
  if (effect_stopping[effect]) {
    effect_stopping[effect] = 0;
    finish_effect(effect);
  }
  if (effect_asked_now[effect]) {
    effect_running[effect] = 1;
    effect_frame[effect] = 0;
    for (int32_t i = 0; i < PARTS_MOST; i++) effect_cursors[effect][i] = 0;
    rg_sound_log("sound_effect %d", (int)effect);
  } else if (effect_running[effect] && effect_frame[effect] >= numbers[0]) {
    finish_effect(effect);
  }
  if (!effect_running[effect]) return;

  if (numbers[4] > PARTS_MOST) rg_fault("a sound effect has %d parts, and the most is %d", (int)numbers[4], PARTS_MOST);
  const int32_t *part = numbers + NUMBERS_PER_SONG;
  int32_t squares_met = 0;
  for (int32_t i = 0; i < numbers[4]; i++) {
    part_walk walk;
    part = read_part(number, part, 0, &squares_met, &walk);
    int32_t *cursor = &effect_cursors[effect][i];
    if (*cursor >= walk.count) continue;
    const int32_t *note = walk.notes + (NUMBERS_PER_NOTE * *cursor);
    if (note[0] != effect_frame[effect]) continue;
    (*cursor)++;
    play_effect_note(effect, &walk, note);
  }
  effect_frame[effect]++;
}

/* --- the frame --- */

static void play_song_frame(void);

/* SOUND EFFECTS PLAY AROUND THE SONG, highest rank first (IR::Tunes.effects_by_rank): the effects
 * that outrank the tune before its parts, the rest after. So a note that loses its voice to one
 * due on the same frame is never written at all — whoever writes a voice first on a frame keeps
 * it. */
void rg_music_frame(void) {
  if (level < 0) level = FULL_LEVEL;
  refuse_too_many_effects();
  switch_to_wanted_song();
  for (int32_t effect = 0; effect < EFFECT_COUNT; effect++) {
    effect_asked_now[effect] = effect_asked[effect];
    effect_asked[effect] = 0;
  }
  int32_t tune = playing >= 0 ? song[3] : -1;
  const int32_t *by_rank = &rg_game_effects[EFFECT_ROWS + (EFFECT_COUNT * NUMBERS_PER_EFFECT)];
  int32_t at = 0;
  while (at < EFFECT_COUNT && effect_row(by_rank[at])[EFFECT_RANK] > tune) play_effect_frame(by_rank[at++]);
  if (playing >= 0) play_song_frame();
  while (at < EFFECT_COUNT) play_effect_frame(by_rank[at++]);
}

/* A TUNE NAMED `this_frame: true`, started where the game names it rather than at the next frame
 * (Reference::Player#start_song_here): the catching up and the tune's first frame, here, so the
 * next frame plays its second. The sound effects are not moved on — they had this frame already. */
void rg_music_start_here(void) {
  if (level < 0) level = FULL_LEVEL;
  if (switch_to_wanted_song() && playing >= 0) play_song_frame();
}

/* AN EFFECT ASKED FOR `this_frame: true`, started where the game asks rather than at the next frame
 * (Reference::Player#start_effect_here): in rank order, every effect of a group waiting to be cut
 * off is cut off, and this one plays its first frame. Nothing sounding is moved on. One not played
 * because another of its group outranks it is not asked for, and nothing happens. */
void rg_effect_start_here_one_of(const int32_t *effects, int32_t count, int32_t which) {
  if (which < 0 || which >= count) return;
  int32_t asked = effects[which];
  request_effect(asked);
  if (!effect_asked[asked]) return;

  const int32_t *by_rank = &rg_game_effects[EFFECT_ROWS + (EFFECT_COUNT * NUMBERS_PER_EFFECT)];
  for (int32_t at = 0; at < EFFECT_COUNT; at++) {
    int32_t effect = by_rank[at];
    if (effect == asked) {
      effect_asked[asked] = 0;
      effect_asked_now[asked] = 1;
      play_effect_frame(asked);
      effect_asked_now[asked] = 0;
    } else if (effect_stopping[effect]) {
      effect_stopping[effect] = 0;
      finish_effect(effect);
    }
  }
}

void rg_music_start_here_one_of(const int32_t *songs, int32_t count, int32_t which) {
  if (which < 0 || which >= count) return;
  rg_music_request(songs[which]);
  rg_music_start_here();
}

static void play_song_frame(void) {
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
