/*
 * The mixer (see rg_mix.h): the interpreter's Reference::Mixer, step for step.
 *
 * ONE FRAME'S SLICE. Each sounding voice reads its recording from where it got to, one sample for
 * each sample of the slice, and adds the sample times its loudness into a running total for that
 * place in the slice. How fast it reads is its STEP: how many samples of the recording go by for
 * each sample of the slice, in 65536ths, so a note pitched up reads faster and one recorded at
 * another rate is read at the rate the mix runs at. The part of a sample that does not make a
 * whole one is carried, frame to frame. A voice that reaches the end of its recording reads back
 * by however far it holds from, or, with nothing to go back to, stops there and gives its voice
 * back. When every voice is in, each total is held to what a byte holds, -128 to 127: on the
 * finished sum, so a loud voice and a loud one of the other sign cancel.
 *
 * A NOTE WITH A SHAPE slides its loudness rather than stepping it: once a frame its shape says
 * where the note should be by the frame's end, and the loudness moves there a little with every
 * sample. That loudness, its GAIN, keeps sixteen bits of fraction, since a slow fade moves it by
 * much less than one a sample. Whether the game shapes any note at all is settled once for the
 * whole game, and it decides what the mix reads for a note WITHOUT a shape: its gain in a game
 * that shapes something, set as the note starts and again when the music volume moves, and its
 * loudness in one that shapes nothing. That is the console's arithmetic, kept to the bit.
 *
 * WHAT THE LOWERING WRITES, all whole numbers.
 *
 * rg_game_mix: 1 if the game mixes anything at all; how many samples a frame's slice holds; 1 if
 * any note in the game has a shape; one sample's share of a frame, out of 65536 (what a shaped
 * note's distance to its next gain is multiplied by to slide it there); how many voices there
 * are; and the shifts the arithmetic is done in — the loudness's, the step's, the gain's
 * fraction, the slide's split, and a shape's full level and the shift it scales by.
 *
 * rg_game_recordings: how many recordings, then seven numbers each — where its samples start in
 * rg_game_recording_samples, how many there are, 1 if it has a shape, and the shape's four
 * numbers (attack, decay, sustain, release).
 *
 * rg_game_recording_samples: every recording's samples, -128 to 127, a byte each.
 */
#include "rg_mix.h"
#include "rg_runtime.h"
#include "rg_sound.h"

#define VOICES_MOST 16
#define SLICE_MOST 1024
#define NUMBERS_PER_RECORDING 7

#define MIXES (rg_game_mix[0])
#define SLICE_SAMPLES (rg_game_mix[1])
#define SHAPES (rg_game_mix[2])
#define SLIDE_SHARE (rg_game_mix[3])
#define VOICES (rg_game_mix[4])
#define VOL_SHIFT (rg_game_mix[5])
#define STEP_SHIFT (rg_game_mix[6])
#define GAIN_FRACTION (rg_game_mix[7])
#define RAMP_SPLIT (rg_game_mix[8])
#define SHAPE_FULL (rg_game_mix[9])
#define SHAPE_SCALE (rg_game_mix[10])

/* Which part of its shape a note is in, and the frame after it has fallen to nothing, which the
 * voice is held for so it comes free on the same frame the console's does. */
#define CLIMBING 0
#define HOLDING 1
#define FALLING 2
#define DONE 3

/* Whose a voice is: the game's own sound, a part of the song playing, or a part of a sound effect
 * — a part by its lane, counted among the parts that play recordings, and an effect by its
 * number (rg_mix.h). */
#define GAME 0
#define SONG 1
#define EFFECT 2

typedef struct {
  int32_t sounding;
  int32_t owner;
  int32_t effect;   /* a sound effect's number, for an effect's part */
  int32_t lane;     /* a song's or an effect's part, which of its recorded parts */
  int32_t rank;     /* the song's or the effect's rank (IR::Tunes); -1 for the game's own sound */
  int32_t loops;    /* a game's sound asked to loop, which gives way after every one-shot */
  int32_t ticket;   /* how many sounds the game had started, this one among them */
  int32_t recording;
  int32_t position; /* the sample it reads next */
  int32_t fraction; /* the part of a sample carried toward the next one, out of 65536 */
  int32_t step;     /* how far it moves for each sample of the slice; 65536 is one */
  int32_t back;     /* how far it reads back at the end of its recording; 0 stops there */
  int32_t loudness; /* out of 64 */
  int32_t gain;     /* the loudness the mix multiplies by, with GAIN_FRACTION bits under it */
  int32_t ramp;     /* how far the gain moves each sample, while a shaped note slides */
  int32_t shaped;
  int32_t level;    /* how far its shape has climbed or fallen, 0 to SHAPE_FULL */
  int32_t phase;
  int32_t attack, decay, sustain, release;
} mix_voice;

static mix_voice voices[VOICES_MOST];
static int32_t slice[SLICE_MOST];
static int32_t slices_made;
static int32_t peak;
static int32_t drops;
static int32_t drops_music;

static const int32_t *recording_numbers(int32_t recording) {
  if (recording < 0 || recording >= rg_game_recordings[0]) rg_fault("there is no recording number %d", (int)recording);
  return &rg_game_recordings[1 + (recording * NUMBERS_PER_RECORDING)];
}

static int32_t voices_sounding(void) {
  int32_t count = 0;
  for (int32_t i = 0; i < VOICES; i++) count += voices[i].sounding;
  return count;
}

static void record_peak(void) {
  int32_t now = voices_sounding();
  if (now > peak) peak = now;
}

/* A play that found every voice busy is dropped rather than cutting off one already sounding,
 * and counted, with how many voices the music was holding then. */
static void record_drop(void) {
  int32_t music = 0;
  for (int32_t i = 0; i < VOICES; i++) music += voices[i].sounding && voices[i].owner != GAME;
  drops++;
  if (music > drops_music) drops_music = music;
}

static int32_t free_voice(void) {
  if (VOICES > VOICES_MOST) rg_fault("the mixer has %d voices, and the most is %d", (int)VOICES, VOICES_MOST);
  for (int32_t i = 0; i < VOICES; i++) {
    if (!voices[i].sounding) return i;
  }
  return -1;
}

/* A note of the song's that has ended and is falling away, or has just finished falling. */
static int32_t releasing(const mix_voice *voice) {
  return voice->owner != GAME && (voice->phase == FALLING || voice->phase == DONE);
}

/* THE QUIETEST NOTE FALLING AWAY — the first thing to give way when a voice is wanted and none is
 * free, since it is on its way out already. The first of them, when two are as quiet. */
static int32_t quietest_releasing_voice(void) {
  int32_t found = -1;
  for (int32_t i = 0; i < VOICES; i++) {
    if (!voices[i].sounding || !releasing(&voices[i])) continue;
    if (found < 0 || voices[i].level < voices[found].level) found = i;
  }
  return found;
}

/* THE LOWEST-RANKED SOUND RANKED BELOW +rank+ — the game's own first, since they rank below every
 * song, and of those the one playing longest, a one-shot before a loop. The first of them in the
 * order of the voices, when two are the same. */
static int32_t lowest_ranked_voice_below(int32_t rank) {
  int32_t found = -1;
  for (int32_t i = 0; i < VOICES; i++) {
    const mix_voice *voice = &voices[i];
    if (!voice->sounding || voice->rank >= rank) continue;
    if (found >= 0) {
      const mix_voice *best = &voices[found];
      if (voice->rank > best->rank) continue;
      if (voice->rank == best->rank &&
          (voice->loops > best->loops || (voice->loops == best->loops && voice->ticket >= best->ticket))) {
        continue;
      }
    }
    found = i;
  }
  return found;
}

/* A voice at the top of +recording+, read +step+ at a time, going +back+ at its end, at +loudness+
 * out of 64, and shaped by +shape+ (whether it has one, then its four numbers). One with a shape
 * starts at nothing and climbs, its gain at nothing until the shape's first frame sets it; one
 * without sounds flat out from its first sample. */
static void start_voice(int32_t at, int32_t recording, int32_t step, int32_t back, int32_t loudness, const int32_t *shape) {
  recording_numbers(recording);
  int32_t shaped = shape[0];
  voices[at] = (mix_voice){.sounding = 1,
                           .owner = GAME,
                           .rank = -1,
                           .recording = recording,
                           .step = step,
                           .back = back,
                           .loudness = loudness,
                           .gain = shaped ? 0 : loudness << GAIN_FRACTION,
                           .shaped = shaped,
                           .level = shaped ? 0 : SHAPE_FULL,
                           .phase = CLIMBING,
                           .attack = shape[1],
                           .decay = shape[2],
                           .sustain = shape[3],
                           .release = shape[4]};
}

static int32_t tickets; /* how many sounds the game has started */

void rg_mix_play(int32_t recording, int32_t step, int32_t loudness, int32_t back, int32_t loops) {
  rg_sound_log("sample %d", (int)recording);
  int32_t at = free_voice();
  if (at < 0) at = quietest_releasing_voice();
  if (at < 0) {
    record_drop();
    return;
  }

  start_voice(at, recording, step, back, loudness, &recording_numbers(recording)[2]);
  voices[at].loops = loops;
  voices[at].ticket = ++tickets;
  record_peak();
}

/* --- the voices the recorded parts of songs and sound effects borrow --- */

/* The voice sounding part +lane+'s note now — the song's part for an +effect+ of -1, else that
 * effect's — and not one of its earlier notes falling away. */
static int32_t sounding_voice(int32_t effect, int32_t lane) {
  int32_t owner = effect < 0 ? SONG : EFFECT;
  for (int32_t i = 0; i < VOICES; i++) {
    const mix_voice *voice = &voices[i];
    if (!voice->sounding || voice->owner != owner || voice->lane != lane || releasing(voice)) continue;
    if (owner == SONG || voice->effect == effect) return i;
  }
  return -1;
}

/* Tell a voice its note has ended. True when it has a shape to fall through, so it is kept; false
 * when it has none and simply stops. */
static int32_t start_release(mix_voice *voice) {
  if (!voice->shaped) return 0;
  voice->phase = FALLING;
  return 1;
}

int32_t rg_mix_start_music_note(int32_t effect, int32_t lane, int32_t rank, const int32_t *sound, int32_t loudness) {
  int32_t at = sounding_voice(effect, lane);
  if (at >= 0 && start_release(&voices[at])) at = -1;
  if (at < 0) at = free_voice();
  if (at < 0) at = quietest_releasing_voice();
  if (at < 0) at = lowest_ranked_voice_below(rank);
  if (at < 0) {
    record_drop();
    return 0;
  }

  start_voice(at, sound[0], sound[1], sound[2], loudness, &sound[3]);
  voices[at].owner = effect < 0 ? SONG : EFFECT;
  voices[at].effect = effect;
  voices[at].lane = lane;
  voices[at].rank = rank;
  return 1;
}

int32_t rg_mix_release_music(int32_t effect, int32_t lane) {
  int32_t at = sounding_voice(effect, lane);
  if (at < 0) return 0;
  if (!start_release(&voices[at])) voices[at].sounding = 0;
  return 1;
}

void rg_mix_release_all_music(void) {
  for (int32_t i = 0; i < VOICES; i++) {
    mix_voice *voice = &voices[i];
    if (!voice->sounding || voice->owner != SONG || releasing(voice)) continue;
    if (!start_release(voice)) voice->sounding = 0;
  }
}

int32_t rg_mix_rescale_music(int32_t lane, int32_t loudness) {
  int32_t at = sounding_voice(-1, lane);
  if (at < 0) return 0;
  voices[at].loudness = loudness;
  /* In a game that shapes a note the mix reads the gain, and a note with no shape has nothing
   * else to move it. */
  if (!voices[at].shaped) voices[at].gain = loudness << GAIN_FRACTION;
  return 1;
}

void rg_mix_stop(int32_t recording) {
  for (int32_t i = 0; i < VOICES; i++) {
    mix_voice *voice = &voices[i];
    if (voice->sounding && voice->owner == GAME && (recording < 0 || voice->recording == recording)) voice->sounding = 0;
  }
  rg_sound_log("stop_sample");
}

/* One voice's frame into the totals. Nought when its recording ran out partway and it stopped,
 * which is the rest of the frame left out of the totals. The product is worked out in 64 bits
 * and shifted down as a whole number, which rounds toward minus infinity as Ruby's does. */
static int32_t mix_voice_into(mix_voice *voice, int32_t *totals) {
  const int32_t *numbers = recording_numbers(voice->recording);
  const int8_t *data = &rg_game_recording_samples[numbers[0]];
  int32_t length = numbers[1];
  int32_t whole = voice->step >> STEP_SHIFT;
  int32_t part = voice->step & ((1 << STEP_SHIFT) - 1);
  int32_t gain = SHAPES ? voice->gain : voice->loudness << GAIN_FRACTION;
  for (int32_t at = 0; at < SLICE_SAMPLES; at++) {
    totals[at] += (int32_t)(((int64_t)gain * data[voice->position]) >> (VOL_SHIFT + GAIN_FRACTION));
    gain += voice->ramp;
    voice->fraction += part;
    voice->position += whole + (voice->fraction >> STEP_SHIFT);
    voice->fraction &= (1 << STEP_SHIFT) - 1;
    if (voice->position < length) continue;
    if (voice->back == 0) return 0;

    while (voice->position >= length) voice->position -= voice->back;
    if (voice->owner == GAME) rg_sound_log("sample %d", (int)voice->recording);
  }
  voice->gain = gain;
  return 1;
}

void rg_mix_frame(void) {
  if (!MIXES) return;
  if (SLICE_SAMPLES > SLICE_MOST) rg_fault("a slice of %d samples is more than the mixer holds", (int)SLICE_SAMPLES);

  for (int32_t at = 0; at < SLICE_SAMPLES; at++) slice[at] = 0;
  for (int32_t i = 0; i < VOICES; i++) {
    if (voices[i].sounding && !mix_voice_into(&voices[i], slice)) voices[i].sounding = 0;
  }
  for (int32_t at = 0; at < SLICE_SAMPLES; at++) {
    if (slice[at] > 127) slice[at] = 127;
    if (slice[at] < -128) slice[at] = -128;
  }
  slices_made++;
}

/* --- shapes --- */

/* One frame of a shape (Audio::Envelope#step, the rule every backend keeps). */
static void step_shape(mix_voice *voice) {
  switch (voice->phase) {
  case CLIMBING: {
    int32_t climbed = voice->level + voice->attack;
    if (climbed >= SHAPE_FULL) {
      voice->level = SHAPE_FULL;
      voice->phase = HOLDING;
    } else {
      voice->level = climbed;
    }
    break;
  }
  case HOLDING:
    if (voice->level > voice->sustain) {
      int32_t fallen = (voice->level * voice->decay) >> SHAPE_SCALE;
      voice->level = fallen > voice->sustain ? fallen : voice->sustain;
    }
    break;
  default: voice->level = (voice->level * voice->release) >> SHAPE_SCALE; break;
  }
}

/* The gain a shaped note ends the frame at — the loudness scaled by the level, a full 255
 * counting as 256 — and the slide there, one step a sample. A note's first frame does not slide:
 * it starts there. The distance is shifted down before it is multiplied and the product after, so
 * the sum fits in 32 bits, as the console's does. */
static void slide_gain(mix_voice *voice, int32_t first) {
  int32_t level = voice->level;
  int32_t target = (voice->loudness * (level + (level >> 7))) << (GAIN_FRACTION - SHAPE_SCALE);
  if (first) voice->gain = target;
  voice->ramp = (((target - voice->gain) >> RAMP_SPLIT) * SLIDE_SHARE) >> RAMP_SPLIT;
}

void rg_mix_step_shapes(void) {
  record_peak();
  for (int32_t i = 0; i < VOICES; i++) {
    mix_voice *voice = &voices[i];
    if (!voice->sounding || !voice->shaped) continue;
    if (voice->phase == DONE) {
      voice->sounding = 0;
      continue;
    }

    int32_t first = voice->phase == CLIMBING && voice->level == 0;
    step_shape(voice);
    if (voice->level == 0 && voice->phase == FALLING) voice->phase = DONE;
    slide_gain(voice, first);
  }
}

/* --- what a test reads back --- */

int32_t rg_mix_slices_made(void) { return slices_made; }

int32_t rg_mix_newest_slice(const int32_t **samples) {
  *samples = slice;
  return slices_made > 0 ? SLICE_SAMPLES : 0;
}

int32_t rg_mix_voice_count(void) { return VOICES; }

int32_t rg_mix_voice_sounding(int32_t voice, rg_mix_voice_reading *reading) {
  const mix_voice *sounding = &voices[voice];
  if (!sounding->sounding) return 0;
  *reading = (rg_mix_voice_reading){.recording = sounding->recording,
                                    .loudness = sounding->loudness,
                                    .level = sounding->level,
                                    .owner = sounding->owner,
                                    .effect = sounding->owner == EFFECT ? sounding->effect : -1,
                                    .lane = sounding->lane};
  return 1;
}

int32_t rg_mix_peak(void) { return peak; }

int32_t rg_mix_drops(int32_t *music_held) {
  *music_held = drops_music;
  return drops;
}
