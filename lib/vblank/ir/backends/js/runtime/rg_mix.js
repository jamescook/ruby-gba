/*
 * THE MIXER: several recordings sounding at once, added together a frame at a time into one stream
 * of sound, the way the console's own software mixer does it. A port of the native runtime's
 * rg_mix.c, function for function; that file says the arithmetic and the layout of rg_game_mix and
 * rg_game_recordings, and this one keeps both to the bit. A product too big for 32 bits is worked
 * out as a float, which holds it exactly, and brought down by rounding down, as the C's 64-bit
 * shift does.
 */

const VOICES_MOST = 16;
const NUMBERS_PER_RECORDING = 7;

function MIXES() { return rg_game_mix[0]; }
function SLICE_SAMPLES() { return rg_game_mix[1]; }
function SHAPES() { return rg_game_mix[2]; }
function SLIDE_SHARE() { return rg_game_mix[3]; }
function VOICES() { return rg_game_mix[4]; }
function VOL_SHIFT() { return rg_game_mix[5]; }
function STEP_SHIFT() { return rg_game_mix[6]; }
function GAIN_FRACTION() { return rg_game_mix[7]; }
function RAMP_SPLIT() { return rg_game_mix[8]; }
function SHAPE_FULL() { return rg_game_mix[9]; }
function SHAPE_SCALE() { return rg_game_mix[10]; }
function LOUDNESS_TO_GAIN() { return rg_game_mix[11]; }
function WHOLE_GAIN_SHIFT() { return rg_game_mix[12]; }

const CLIMBING = 0, HOLDING = 1, FALLING = 2, DONE = 3;
const GAME = 0, SONG = 1, EFFECT = 2;

function silent_mix_voice() {
  return { sounding: 0, owner: GAME, effect: 0, lane: 0, rank: 0, loops: 0, ticket: 0, recording: 0, position: 0,
    fraction: 0, step: 0, back: 0, loudness: 0, gain: 0, ramp: 0, shaped: 0, level: 0, phase: CLIMBING, attack: 0,
    decay: 0, sustain: 0, release: 0 };
}

const mix_voices = [];
for (let i = 0; i < VOICES_MOST; i++) mix_voices.push(silent_mix_voice());
let slice = null;
let slices_made = 0;
let peak = 0;
let drops = 0;
let drops_music = 0;
let tickets = 0;

/* Where recording number +recording+'s numbers start in rg_game_recordings. */
function recording_numbers(recording) {
  if (recording < 0 || recording >= rg_game_recordings[0]) rg_fault(`there is no recording number ${recording}`);
  return 1 + recording * NUMBERS_PER_RECORDING;
}

function voices_sounding() {
  let count = 0;
  for (let i = 0; i < VOICES(); i++) count += mix_voices[i].sounding;
  return count;
}

function record_peak() {
  const now = voices_sounding();
  if (now > peak) peak = now;
}

function record_drop() {
  let music = 0;
  for (let i = 0; i < VOICES(); i++) music += mix_voices[i].sounding && mix_voices[i].owner !== GAME ? 1 : 0;
  drops++;
  if (music > drops_music) drops_music = music;
}

function free_voice() {
  if (VOICES() > VOICES_MOST) rg_fault(`the mixer has ${VOICES()} voices, and the most is ${VOICES_MOST}`);
  for (let i = 0; i < VOICES(); i++) {
    if (!mix_voices[i].sounding) return i;
  }
  return -1;
}

function releasing(voice) { return voice.owner !== GAME && (voice.phase === FALLING || voice.phase === DONE); }

function quietest_releasing_voice() {
  let found = -1;
  for (let i = 0; i < VOICES(); i++) {
    if (!mix_voices[i].sounding || !releasing(mix_voices[i])) continue;
    if (found < 0 || mix_voices[i].level < mix_voices[found].level) found = i;
  }
  return found;
}

function lowest_ranked_voice_below(rank) {
  let found = -1;
  for (let i = 0; i < VOICES(); i++) {
    const voice = mix_voices[i];
    if (!voice.sounding || voice.rank >= rank) continue;
    if (found >= 0) {
      const best = mix_voices[found];
      if (voice.rank > best.rank) continue;
      if (voice.rank === best.rank && (voice.loops > best.loops || (voice.loops === best.loops && voice.ticket >= best.ticket))) {
        continue;
      }
    }
    found = i;
  }
  return found;
}

/* A voice at the top of +recording+, shaped by the five numbers of +shape+ from +at+ (whether it
 * has one, then its four numbers). */
function start_voice(voice_at, recording, step, back, loudness, shape, at) {
  recording_numbers(recording);
  const shaped = shape[at];
  const voice = silent_mix_voice();
  Object.assign(voice, { sounding: 1, owner: GAME, rank: -1, recording, step, back, loudness,
    gain: shaped ? 0 : loudness << LOUDNESS_TO_GAIN(), shaped, level: shaped ? 0 : SHAPE_FULL(), phase: CLIMBING,
    attack: shape[at + 1], decay: shape[at + 2], sustain: shape[at + 3], release: shape[at + 4] });
  mix_voices[voice_at] = voice;
}

function rg_mix_play(recording, step, loudness, back, loops) {
  rg_sound_log(`sample ${recording}`);
  let at = free_voice();
  if (at < 0) at = quietest_releasing_voice();
  if (at < 0) {
    record_drop();
    return;
  }

  start_voice(at, recording, step, back, loudness, rg_game_recordings, recording_numbers(recording) + 2);
  mix_voices[at].loops = loops;
  mix_voices[at].ticket = ++tickets;
  record_peak();
}

function sounding_voice(effect, lane) {
  const owner = effect < 0 ? SONG : EFFECT;
  for (let i = 0; i < VOICES(); i++) {
    const voice = mix_voices[i];
    if (!voice.sounding || voice.owner !== owner || voice.lane !== lane || releasing(voice)) continue;
    if (owner === SONG || voice.effect === effect) return i;
  }
  return -1;
}

function start_release(voice) {
  if (!voice.shaped) return 0;
  voice.phase = FALLING;
  return 1;
}

/* +sound+ is where the note's eight numbers start in rg_game_note_sounds. */
function rg_mix_start_music_note(effect, lane, rank, sound, loudness) {
  let at = sounding_voice(effect, lane);
  if (at >= 0 && start_release(mix_voices[at])) at = -1;
  if (at < 0) at = free_voice();
  if (at < 0) at = quietest_releasing_voice();
  if (at < 0) at = lowest_ranked_voice_below(rank);
  if (at < 0) {
    record_drop();
    return 0;
  }

  start_voice(at, rg_game_note_sounds[sound], rg_game_note_sounds[sound + 1], rg_game_note_sounds[sound + 2], loudness,
    rg_game_note_sounds, sound + 3);
  mix_voices[at].owner = effect < 0 ? SONG : EFFECT;
  mix_voices[at].effect = effect;
  mix_voices[at].lane = lane;
  mix_voices[at].rank = rank;
  return 1;
}

function rg_mix_release_music(effect, lane) {
  const at = sounding_voice(effect, lane);
  if (at < 0) return 0;
  if (!start_release(mix_voices[at])) mix_voices[at].sounding = 0;
  return 1;
}

function rg_mix_release_all_music() {
  for (let i = 0; i < VOICES(); i++) {
    const voice = mix_voices[i];
    if (!voice.sounding || voice.owner !== SONG || releasing(voice)) continue;
    if (!start_release(voice)) voice.sounding = 0;
  }
}

function rg_mix_rescale_music(lane, loudness) {
  const at = sounding_voice(-1, lane);
  if (at < 0) return 0;
  mix_voices[at].loudness = loudness;
  if (!mix_voices[at].shaped) mix_voices[at].gain = loudness << LOUDNESS_TO_GAIN();
  return 1;
}

function rg_mix_stop(recording) {
  for (let i = 0; i < VOICES(); i++) {
    const voice = mix_voices[i];
    if (voice.sounding && voice.owner === GAME && (recording < 0 || voice.recording === recording)) voice.sounding = 0;
  }
  rg_sound_log("stop_sample");
}

/* One voice's frame into the totals. Nought when its recording ran out partway and it stopped. */
function mix_voice_into(voice, totals) {
  const numbers = recording_numbers(voice.recording);
  const data = rg_game_recordings[numbers];
  const length = rg_game_recordings[numbers + 1];
  const step_shift = STEP_SHIFT(), step_mask = (1 << step_shift) - 1;
  const whole = voice.step >> step_shift;
  const part = voice.step & step_mask;
  const down = 2 ** (VOL_SHIFT() + GAIN_FRACTION());
  let gain = SHAPES() ? voice.gain : voice.loudness << LOUDNESS_TO_GAIN();
  for (let at = 0; at < SLICE_SAMPLES(); at++) {
    totals[at] += Math.floor((gain * rg_game_recording_samples[data + voice.position]) / down);
    gain = (gain + voice.ramp) | 0;
    voice.fraction += part;
    voice.position += whole + (voice.fraction >> step_shift);
    voice.fraction &= step_mask;
    if (voice.position < length) continue;
    if (voice.back === 0) return 0;

    while (voice.position >= length) voice.position -= voice.back;
    if (voice.owner === GAME) rg_sound_log(`sample ${voice.recording}`);
  }
  voice.gain = gain;
  return 1;
}

function rg_mix_frame() {
  if (!MIXES()) return;
  if (!slice) slice = new Int32Array(SLICE_SAMPLES());

  slice.fill(0);
  for (let i = 0; i < VOICES(); i++) {
    if (mix_voices[i].sounding && !mix_voice_into(mix_voices[i], slice)) mix_voices[i].sounding = 0;
  }
  for (let at = 0; at < SLICE_SAMPLES(); at++) {
    if (slice[at] > 127) slice[at] = 127;
    if (slice[at] < -128) slice[at] = -128;
  }
  slices_made++;
}

/* --- shapes --- */

function step_shape(voice) {
  switch (voice.phase) {
    case CLIMBING: {
      const climbed = voice.level + voice.attack;
      if (climbed >= SHAPE_FULL()) {
        voice.level = SHAPE_FULL();
        voice.phase = HOLDING;
      } else {
        voice.level = climbed;
      }
      break;
    }
    case HOLDING:
      if (voice.level > voice.sustain) {
        const fallen = (voice.level * voice.decay) >> SHAPE_SCALE();
        voice.level = fallen > voice.sustain ? fallen : voice.sustain;
      }
      break;
    default: voice.level = (voice.level * voice.release) >> SHAPE_SCALE(); break;
  }
}

function nearest_whole_gain(gain) {
  return (gain + (1 << (GAIN_FRACTION() - 1))) & ~((1 << GAIN_FRACTION()) - 1);
}

function slide_gain(voice, first) {
  const level = voice.level;
  const target = ((voice.loudness * (level + (level >> 7))) >> WHOLE_GAIN_SHIFT()) << GAIN_FRACTION();
  voice.gain = first ? target : nearest_whole_gain(voice.gain);
  voice.ramp = (((target - voice.gain) >> RAMP_SPLIT()) * SLIDE_SHARE()) >> RAMP_SPLIT();
}

function rg_mix_step_shapes() {
  record_peak();
  for (let i = 0; i < VOICES(); i++) {
    const voice = mix_voices[i];
    if (!voice.sounding || !voice.shaped) continue;
    if (voice.phase === DONE) {
      voice.sounding = 0;
      continue;
    }

    const first = voice.phase === CLIMBING && voice.level === 0;
    step_shape(voice);
    if (voice.level === 0 && voice.phase === FALLING) voice.phase = DONE;
    slide_gain(voice, first);
  }
}

/* --- what a test reads back --- */

function rg_mix_slices_made() { return slices_made; }

/* The newest slice's samples, or null before the first. */
function rg_mix_newest_slice() { return slices_made > 0 ? slice : null; }

function rg_mix_voice_count() { return VOICES(); }

/* What voice +voice+ is playing, or null when it is not sounding. */
function rg_mix_voice_sounding(voice) {
  const sounding = mix_voices[voice];
  if (!sounding.sounding) return null;
  return { recording: sounding.recording, loudness: sounding.loudness, level: sounding.level, owner: sounding.owner,
    effect: sounding.owner === EFFECT ? sounding.effect : -1, lane: sounding.lane };
}

function rg_mix_peak() { return peak; }
function rg_mix_drops() { return [drops, drops_music]; }
