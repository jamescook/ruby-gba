/*
 * THE GAME'S SOUND: the music player, the console's four voices it and the game's own sounds play
 * on, and the log of what was played. A port of the native runtime's rg_sound.c, function for
 * function; that file says every rule of the voices and the layout of every array the lowering
 * writes (rg_game_music, rg_game_beeps, ...), and this one reads them the same way. Where the C
 * keeps a pointer into one of those arrays, this keeps the place in it.
 *
 * The voices are worked out here sample by sample, whatever the driver does with them: the
 * windowless one writes them to a file for a test, and a page hands them to the browser to play.
 */

const RG_SOUND_RATE = 48000;
const RG_SOUND_FRAME_MOST = 1024;
const RG_SQUARE_VOICES = 2;
const RG_WAVE_VOICE = 3;
const RG_NOISE_VOICE = 4;

const PARTS_MOST = 20;
const NUMBERS_PER_NOTE = 4;
const NUMBERS_PER_NOTE_SOUND = 8;
const NUMBERS_PER_BEEP = 4;
const NUMBERS_PER_WAVE = 3;
const NUMBERS_PER_HIT = 4;
const BEEP_VOICE = 2;
const WAVE_STEPS = 32;
const VOLUMES = 16;

const PART_SQUARE = 0, PART_WAVE = 1, PART_NOISE = 2, PART_RECORDED = 3;

function SQUARE_CLOCK_HZ() { return rg_game_sound_rules[0]; }
function WAVE_CLOCK_HZ() { return rg_game_sound_rules[1]; }
function NOISE_CLOCK_HZ() { return rg_game_sound_rules[2]; }
function OUTPUT_HZ() { return rg_game_sound_rules[3]; }
function FULL_LEVEL() { return rg_game_sound_rules[4]; }
function LEVEL_SHIFT() { return rg_game_sound_rules[5]; }
const WAVE_QUARTERS = 6;
function SONG_COUNT() { return rg_game_music[0]; }
const SONG_STARTS = 1;
const NUMBERS_PER_SONG = 5;
const NUMBERS_PER_PART = 6;
function EFFECT_COUNT() { return rg_game_effects[0]; }
function EFFECTS_PLAY_WAVE() { return rg_game_effects[1]; }
const EFFECT_ROWS = 2;
const NUMBERS_PER_EFFECT = 5;
const EFFECT_SONG = 0, EFFECT_NOTES = 1, EFFECT_RANK = 2, EFFECT_GROUP = 3, EFFECT_PRIORITY = 4;
const EFFECTS_MOST = 512;

const STEP_SIZE = 1092;
const MIX_STEP = 128;
const FRAME_TICKS = 280896;
const TICKS_A_SECOND = 2 ** 24;

/* --- a loudness that fades --- */

function volume_from(volume, fade_64ths) {
  const hold = Math.trunc((fade_64ths * RG_SOUND_RATE) / 64);
  return { volume, hold_samples: hold, left: hold };
}

function fade_one_sample(fading) {
  if (fading.hold_samples > 0 && fading.volume > 0 && --fading.left === 0) {
    fading.volume--;
    fading.left = fading.hold_samples;
  }
}

/* --- the square voices --- */

function silent_square() {
  return { wave_ticks: 0, eighths_high: 0, loudness: volume_from(0, 0), eighth: 0, eighth_progress: 0 };
}
const squares = [silent_square(), silent_square()];
let heard_only = 0;
let sample_carry = 0;

function square_start(voice, wave_ticks, eighths_high, volume, fade_64ths) {
  const square = squares[voice - 1];
  square.wave_ticks = wave_ticks;
  square.eighths_high = eighths_high;
  square.loudness = volume_from(volume, fade_64ths);
  square.eighth = 0;
  square.eighth_progress = 0;
}

function eighth_is_high(eighths_high, eighth) {
  switch (eighths_high) {
    case 1: return eighth === 7;
    case 2: return eighth === 0 || eighth === 7;
    case 4: return eighth === 0 || eighth >= 5;
    default: return eighth >= 1 && eighth <= 6;
  }
}

function square_sample(square) {
  if (square.wave_ticks === 0 || square.loudness.volume === 0) return 0;

  const high = eighth_is_high(square.eighths_high, square.eighth);
  const sample = Math.trunc((STEP_SIZE * square.loudness.volume * (high ? 8 - square.eighths_high : -square.eighths_high)) / 8);

  const eighth_length = square.wave_ticks * RG_SOUND_RATE;
  square.eighth_progress += SQUARE_CLOCK_HZ() * 8;
  while (square.eighth_progress >= eighth_length) {
    square.eighth_progress -= eighth_length;
    square.eighth = (square.eighth + 1) & 7;
  }
  fade_one_sample(square.loudness);
  return sample;
}

/* --- the wave voice --- */

const wave = { steps: new Int32Array(WAVE_STEPS), switched_on: 0, wave_ticks: 0, quarters: 0, cut_sum: 0, step: 0, step_progress: 0 };
let loaded_waveform = -1;

function wave_step_cut(step) { return Math.trunc((step * wave.quarters) / 4); }

function wave_set_loudness(quarters) {
  wave.quarters = quarters;
  wave.cut_sum = 0;
  for (let i = 0; i < WAVE_STEPS; i++) wave.cut_sum += wave_step_cut(wave.steps[i]);
}

function wave_load(which) {
  if (which < 0 || which >= rg_game_waveforms[0]) rg_fault(`there is no waveform number ${which}`);
  for (let i = 0; i < WAVE_STEPS; i++) wave.steps[i] = rg_game_waveforms[1 + which * WAVE_STEPS + i];
  loaded_waveform = which;
  wave.switched_on = 1;
  wave.wave_ticks = 0;
  wave_set_loudness(wave.quarters);
}

function wave_start(wave_ticks, quarters) {
  wave.wave_ticks = wave.switched_on ? wave_ticks : 0;
  wave.step = 0;
  wave.step_progress = 0;
  wave_set_loudness(quarters);
}

function wave_switch_off() {
  wave.switched_on = 0;
  wave.wave_ticks = 0;
}

function wave_sample() {
  if (wave.wave_ticks === 0) return 0;

  const sample = Math.trunc((STEP_SIZE * (WAVE_STEPS * wave_step_cut(wave.steps[wave.step]) - wave.cut_sum)) / WAVE_STEPS);

  const step_length = wave.wave_ticks * RG_SOUND_RATE;
  wave.step_progress += WAVE_CLOCK_HZ() * WAVE_STEPS;
  while (wave.step_progress >= step_length) {
    wave.step_progress -= step_length;
    wave.step = (wave.step + 1) % WAVE_STEPS;
  }
  return sample;
}

/* --- the noise voice --- */

const hiss = { step_ticks: 0, bits: 0, row: 0, high: 0, heard_high: 0, loudness: volume_from(0, 0), row_progress: 0, hand_progress: 0 };

function noise_start(step_ticks, bits, volume, fade_64ths) {
  hiss.step_ticks = step_ticks;
  hiss.bits = bits;
  hiss.row = (2 ** bits - 1) >>> 0;
  hiss.high = 0;
  hiss.heard_high = 0;
  hiss.loudness = volume_from(volume, fade_64ths);
  hiss.row_progress = 0;
  hiss.hand_progress = 0;
}

function noise_step() {
  const fell = hiss.row & 1;
  hiss.row >>>= 1;
  if (fell) hiss.row = (hiss.row ^ (3 << (hiss.bits - 2))) >>> 0;
  hiss.high = fell;
}

function noise_sample() {
  if (hiss.step_ticks === 0 || hiss.loudness.volume === 0) return 0;

  hiss.hand_progress += OUTPUT_HZ();
  while (hiss.hand_progress >= RG_SOUND_RATE) {
    hiss.hand_progress -= RG_SOUND_RATE;
    const step_length = hiss.step_ticks * OUTPUT_HZ();
    hiss.row_progress += NOISE_CLOCK_HZ();
    while (hiss.row_progress >= step_length) {
      hiss.row_progress -= step_length;
      noise_step();
    }
    hiss.heard_high = hiss.high;
  }
  const sample = Math.trunc((STEP_SIZE * hiss.loudness.volume * (hiss.heard_high ? 1 : -1)) / 2);
  fade_one_sample(hiss.loudness);
  return sample;
}

/* --- the sound of a frame --- */

function rg_sound_hear_only(voice) { heard_only = voice; }

function heard(voice, sample) { return heard_only === 0 || heard_only === voice ? sample : 0; }

/* The sound of the frame that has just been played, written into +samples+ (an Int16Array with
 * room for RG_SOUND_FRAME_MOST); gives back how many. */
function rg_sound_render_frame(samples) {
  sample_carry += RG_SOUND_RATE * FRAME_TICKS;
  const count = Math.floor(sample_carry / TICKS_A_SECOND);
  sample_carry %= TICKS_A_SECOND;

  const mixed = heard_only === 0 ? rg_mix_newest_slice() : null;
  const mixed_count = mixed ? mixed.length : 0;

  for (let i = 0; i < count; i++) {
    let sum = 0;
    for (let voice = 1; voice <= RG_SQUARE_VOICES; voice++) sum += heard(voice, square_sample(squares[voice - 1]));
    sum += heard(RG_WAVE_VOICE, wave_sample());
    sum += heard(RG_NOISE_VOICE, noise_sample());
    if (mixed_count > 0) sum += mixed[Math.trunc((i * mixed_count) / count)] * MIX_STEP;
    if (sum > 32767) sum = 32767;
    if (sum < -32768) sum = -32768;
    samples[i] = sum;
  }
  return count;
}

/* --- the log --- */

function rg_sound_log(line) { rg_active_driver.sound_logged(line); }

/* --- the sounds the game makes itself --- */

function rg_sound_enabled() { rg_sound_log("enabled"); }

function rg_sound_beep(which) {
  if (which < 0 || which >= rg_game_beeps[0]) rg_fault(`there is no beep number ${which}`);
  const beep = 1 + which * NUMBERS_PER_BEEP;
  rg_sound_log(`beep ${which}`);
  square_start(BEEP_VOICE, rg_game_beeps[beep], rg_game_beeps[beep + 1], rg_game_beeps[beep + 2], rg_game_beeps[beep + 3]);
}

function rg_sound_wave(which) {
  if (which < 0 || which >= rg_game_waves[0]) rg_fault(`there is no wave number ${which}`);
  const said = 1 + which * NUMBERS_PER_WAVE;
  rg_sound_log(`wave ${which}`);
  wave_load(rg_game_waves[said]);
  wave_start(rg_game_waves[said + 1], rg_game_waves[said + 2]);
  loaded_waveform = -1;
}

function rg_sound_stop_wave() {
  rg_sound_log("stop_wave");
  wave_switch_off();
  loaded_waveform = -1;
}

function rg_sound_noise(which) {
  if (which < 0 || which >= rg_game_hits[0]) rg_fault(`there is no hit number ${which}`);
  const hit = 1 + which * NUMBERS_PER_HIT;
  rg_sound_log(`noise ${which}`);
  noise_start(rg_game_hits[hit], rg_game_hits[hit + 1], rg_game_hits[hit + 2], rg_game_hits[hit + 3]);
}

/* --- the player --- */

let wanted = -1;
let playing = -1;
let ended = -1;
let stops = 0;
let stops_seen = 0;

let song = 0; /* where the playing song's numbers start in rg_game_music */
let song_frame = 0;
let part_count = 0;
const parts = [];
for (let i = 0; i < PARTS_MOST; i++) parts.push(null);

let level_variable = null; /* reads the game's music volume, for a game that keeps one */
let level = -1;

let holding = [];

function rg_music_request(number) {
  if (number < 0 || number >= SONG_COUNT()) rg_fault(`there is no song number ${number}`);
  wanted = number;
}

function rg_music_request_one_of(songs, count, which) {
  if (which >= 0 && which < count) rg_music_request(songs[which]);
}

function rg_music_stop() {
  wanted = -1;
  stops++;
}

function rg_music_follow_level(variable) { level_variable = variable; }

/* Where song number +number+'s numbers start, from its length on. */
function song_numbers(number) { return rg_game_music[SONG_STARTS + number]; }

/* The part of song number +number+ written at +part+ (a place in rg_game_music), as a walk of its
 * notes. Gives back the walk and where the song's next part is written. */
function read_part(number, part, again, squares_met) {
  const kind = rg_game_music[part], first = rg_game_music[part + 4], after = rg_game_music[part + 5];
  const first_notes = part + NUMBERS_PER_PART;
  const after_notes = first_notes + NUMBERS_PER_NOTE * first;
  const voice = kind === PART_WAVE ? RG_WAVE_VOICE
    : kind === PART_NOISE ? RG_NOISE_VOICE
      : kind === PART_RECORDED ? 0
        : ++squares_met.count;
  if (squares_met.count > RG_SQUARE_VOICES) {
    rg_fault(`song number ${number} has more parts on the square wave than the ${RG_SQUARE_VOICES} there are`);
  }
  const walk = { notes: again ? after_notes : first_notes, count: again ? after : first, next: 0, kind, voice,
    number: rg_game_music[part + 1], tone: rg_game_music[part + 2], fade: rg_game_music[part + 3] };
  return [walk, after_notes + NUMBERS_PER_NOTE * after];
}

function start_walks(again) {
  let part = song + NUMBERS_PER_SONG;
  const squares_met = { count: 0 };
  for (let i = 0; i < part_count; i++) {
    const [walk, next] = read_part(playing, part, again, squares_met);
    parts[i] = walk;
    part = next;
  }
}

function scaled_volume(volume) { return (volume * level) >> LEVEL_SHIFT(); }

function wave_quarters_at(volume) {
  if (volume < 0) volume = 0;
  if (volume >= VOLUMES) volume = VOLUMES - 1;
  return rg_game_sound_rules[WAVE_QUARTERS + volume];
}

function log_held_loudness(note) {
  if (note.voice === 0) rg_sound_log(`mixer_loudness ${note.lane} ${scaled_volume(note.volume)}`);
  else rg_sound_log(`loudness ${note.voice} ${scaled_volume(note.volume)}`);
}

function hold_note(note) {
  let at = 0;
  while (at < holding.length && (holding[at].voice !== note.voice || (note.voice === 0 && holding[at].lane !== note.lane))) at++;
  holding[at] = note;
  log_held_loudness(note);
}

function follow_level(now) {
  if (now === level) return;
  level = now;
  for (const note of holding) {
    if (note.volume <= 0) continue;
    if (note.voice === 0 && !rg_mix_rescale_music(note.lane, scaled_volume(note.volume))) continue;
    log_held_loudness(note);
    if (note.voice === 0) continue;
    if (note.voice === RG_WAVE_VOICE) {
      wave_set_loudness(wave_quarters_at(scaled_volume(note.volume)));
    } else {
      square_start(note.voice, note.wave_ticks, note.eighths_high, scaled_volume(note.volume), 0);
    }
  }
}

function silence_voice(voice) {
  switch (voice) {
    case RG_WAVE_VOICE: wave_set_loudness(0); break;
    case RG_NOISE_VOICE: noise_start(0, hiss.bits, 0, 0); break;
    default: square_start(voice, 0, 0, 0, 0); break;
  }
}

function rest_on(part) {
  if (part.kind !== PART_RECORDED) silence_voice(part.voice);
}

/* --- who holds a console voice --- */

function ORDER_MASK() { return rg_game_sound_rules[WAVE_QUARTERS + VOLUMES]; }
const holders = [0, 0, 0, 0, 0];
const holder_order = [];

function claim_voice(voice, rank, sounds) {
  if (holders[voice] > rank) return 0;
  if (!holder_order.includes(voice)) holder_order.push(voice);
  holders[voice] = sounds ? rank : 0;
  return 1;
}

function note_sounds(kind, pitch, volume) {
  if (pitch === 0 || volume <= 0) return 0;
  return kind !== PART_WAVE || wave_quarters_at(volume) !== 0 ? 1 : 0;
}

function wave_put_in(which) {
  if (which === loaded_waveform) return;
  wave_load(which);
}

function silence_song() {
  rg_sound_log("stop_music");
  for (let i = 0; i < part_count; i++) {
    if (parts[i].kind === PART_RECORDED || (holders[parts[i].voice] & ORDER_MASK()) !== 0) continue;
    rest_on(parts[i]);
  }
  for (let voice = 1; voice <= RG_NOISE_VOICE; voice++) {
    if ((holders[voice] & ORDER_MASK()) === 0) holders[voice] = 0;
  }
  holding = [];
  rg_mix_release_all_music();
}

function switch_to_wanted_song() {
  if (ended >= 0) {
    if (wanted === ended && stops === stops_seen) {
      if (playing >= 0) silence_song();
      playing = -1;
      return false;
    }
    ended = -1;
  }
  if (wanted === playing && stops === stops_seen) return false;

  stops_seen = stops;
  if (playing >= 0) silence_song();
  playing = wanted;
  song_frame = 0;
  part_count = 0;
  if (playing < 0) return true;

  song = song_numbers(playing);
  part_count = rg_game_music[song + 4];
  if (part_count > PARTS_MOST) rg_fault(`song number ${playing} has ${part_count} parts, and the most is ${PARTS_MOST}`);
  start_walks(0);
  if (EFFECTS_PLAY_WAVE()) return true;
  for (let i = 0; i < part_count; i++) {
    if (parts[i].kind !== PART_WAVE) continue;
    wave_load(parts[i].tone);
    break;
  }
  return true;
}

function play_recorded_note(part, note) {
  const pitch = rg_game_music[note + 1], loudness = rg_game_music[note + 2], sound = rg_game_music[note + 3];
  if (pitch === 0 || loudness <= 0) {
    rg_mix_release_music(-1, part.tone);
  } else {
    const numbers = 1 + sound * NUMBERS_PER_NOTE_SOUND;
    if (!rg_mix_start_music_note(-1, part.tone, rg_game_music[song + 3], numbers,
      level_variable ? scaled_volume(loudness) : loudness)) {
      return;
    }
  }
  rg_sound_log(`note ${playing} ${pitch}`);
  if (level_variable) hold_note({ voice: 0, lane: part.tone, volume: pitch === 0 ? 0 : loudness, wave_ticks: 0, eighths_high: 0 });
}

function play_note(part, note) {
  if (part.kind === PART_RECORDED) {
    play_recorded_note(part, note);
    return;
  }

  const pitch = rg_game_music[note + 1], volume = rg_game_music[note + 2], ticks = rg_game_music[note + 3];
  if (!claim_voice(part.voice, rg_game_music[song + 3], note_sounds(part.kind, pitch, volume))) return;

  const written = pitch === 0 ? 0 : volume;
  const sounded = level_variable ? scaled_volume(written) : written;
  rg_sound_log(`note ${playing} ${pitch}`);
  rg_sound_log(`voice ${part.voice} ${playing} ${pitch} ${volume}`);
  switch (part.kind) {
    case PART_WAVE:
      if (level_variable) hold_note({ voice: part.voice, lane: 0, volume: written, wave_ticks: 0, eighths_high: 0 });
      if (pitch === 0) {
        rg_sound_log("stop_wave");
        rest_on(part);
      } else {
        rg_sound_log(`part_wave ${playing} ${part.number} ${pitch}`);
        if (EFFECTS_PLAY_WAVE()) wave_put_in(part.tone);
        wave_start(ticks, wave_quarters_at(sounded));
      }
      break;
    case PART_NOISE:
      if (level_variable) rg_sound_log(`loudness ${part.voice} ${sounded}`);
      if (pitch === 0) {
        rg_sound_log("noise_rest");
        rest_on(part);
      } else {
        rg_sound_log(`part_noise ${playing} ${part.number} ${pitch}`);
        noise_start(ticks, part.tone, sounded, part.fade);
      }
      break;
    default:
      if (level_variable) hold_note({ voice: part.voice, lane: 0, volume: written, wave_ticks: ticks, eighths_high: part.tone });
      square_start(part.voice, ticks, part.tone, sounded, 0);
      break;
  }
}

/* --- sound effects --- */

const effect_asked = new Uint8Array(EFFECTS_MOST);
const effect_asked_now = new Uint8Array(EFFECTS_MOST);
const effect_stopping = new Uint8Array(EFFECTS_MOST);
const effect_running = new Uint8Array(EFFECTS_MOST);
const effect_frame = new Int32Array(EFFECTS_MOST);
const effect_cursors = [];
for (let i = 0; i < EFFECTS_MOST; i++) effect_cursors.push(null);

function effect_row(effect) { return EFFECT_ROWS + effect * NUMBERS_PER_EFFECT; }
function effect_field(effect, field) { return rg_game_effects[effect_row(effect) + field]; }

function effect_pending(effect) {
  return effect_asked[effect] || (effect_running[effect] && !effect_stopping[effect]);
}

function refuse_too_many_effects() {
  if (EFFECT_COUNT() > EFFECTS_MOST) rg_fault(`the game has ${EFFECT_COUNT()} sound effects, and the most is ${EFFECTS_MOST}`);
}

function request_effect(effect) {
  refuse_too_many_effects();
  if (effect_field(effect, EFFECT_GROUP) >= 0) {
    for (let other = 0; other < EFFECT_COUNT(); other++) {
      if (effect_field(other, EFFECT_GROUP) !== effect_field(effect, EFFECT_GROUP) || !effect_pending(other)) continue;
      if (effect_field(effect, EFFECT_PRIORITY) < effect_field(other, EFFECT_PRIORITY)) return;
      effect_asked[other] = 0;
      effect_stopping[other] = 1;
      break;
    }
  }
  effect_asked[effect] = 1;
}

function rg_effect_request_one_of(effects, count, which) {
  if (which >= 0 && which < count) request_effect(effects[which]);
}

function drop_held_note(voice) { holding = holding.filter((note) => note.voice !== voice); }

function finish_effect(effect) {
  const number = effect_field(effect, EFFECT_SONG), rank = effect_field(effect, EFFECT_RANK);
  effect_running[effect] = 0;
  for (const voice of holder_order) {
    if (holders[voice] !== rank) continue;
    holders[voice] = 0;
    rg_sound_log(`note ${number} 0`);
    rg_sound_log(`voice ${voice} ${number} 0 0`);
    if (voice === RG_NOISE_VOICE) rg_sound_log("noise_rest");
    if (voice === RG_WAVE_VOICE) rg_sound_log("stop_wave");
    silence_voice(voice);
  }

  const numbers = song_numbers(effect_field(effect, EFFECT_NOTES));
  let part = numbers + NUMBERS_PER_SONG;
  const squares_met = { count: 0 };
  for (let i = 0; i < rg_game_music[numbers + 4]; i++) {
    const [walk, next] = read_part(number, part, 0, squares_met);
    part = next;
    if (walk.kind === PART_RECORDED && rg_mix_release_music(effect, walk.tone)) rg_sound_log(`note ${number} 0`);
  }
}

function play_effect_note(effect, part, note) {
  const number = effect_field(effect, EFFECT_SONG), rank = effect_field(effect, EFFECT_RANK);
  const pitch = rg_game_music[note + 1], volume = rg_game_music[note + 2];
  const sounds = note_sounds(part.kind, pitch, volume);

  if (part.kind === PART_RECORDED) {
    const sound = rg_game_music[note + 3];
    const loudness = rg_game_music[note + 2];
    const was_heard = sounds ? rg_mix_start_music_note(effect, part.tone, rank, 1 + sound * NUMBERS_PER_NOTE_SOUND, loudness)
      : rg_mix_release_music(effect, part.tone);
    if (was_heard) rg_sound_log(`note ${number} ${pitch}`);
    return;
  }
  if (!claim_voice(part.voice, rank, sounds)) return;

  const ticks = rg_game_music[note + 3];
  drop_held_note(part.voice);
  rg_sound_log(`note ${number} ${pitch}`);
  rg_sound_log(`voice ${part.voice} ${number} ${pitch} ${volume}`);
  switch (part.kind) {
    case PART_WAVE:
      if (pitch === 0) {
        rg_sound_log("stop_wave");
        silence_voice(part.voice);
      } else {
        rg_sound_log(`part_wave ${number} ${part.number} ${pitch}`);
        wave_put_in(part.tone);
        wave_start(ticks, wave_quarters_at(volume));
      }
      break;
    case PART_NOISE:
      if (pitch === 0) {
        rg_sound_log("noise_rest");
        silence_voice(part.voice);
      } else {
        rg_sound_log(`part_noise ${number} ${part.number} ${pitch}`);
        noise_start(ticks, part.tone, volume, part.fade);
      }
      break;
    default: square_start(part.voice, ticks, part.tone, pitch === 0 ? 0 : volume, 0); break;
  }
}

function play_effect_frame(effect) {
  const number = effect_field(effect, EFFECT_SONG);
  const numbers = song_numbers(effect_field(effect, EFFECT_NOTES));
  if (effect_stopping[effect]) {
    effect_stopping[effect] = 0;
    finish_effect(effect);
  }
  if (effect_asked_now[effect]) {
    effect_running[effect] = 1;
    effect_frame[effect] = 0;
    effect_cursors[effect] = new Int32Array(PARTS_MOST);
    rg_sound_log(`sound_effect ${effect}`);
  } else if (effect_running[effect] && effect_frame[effect] >= rg_game_music[numbers]) {
    finish_effect(effect);
  }
  if (!effect_running[effect]) return;

  const part_total = rg_game_music[numbers + 4];
  if (part_total > PARTS_MOST) rg_fault(`a sound effect has ${part_total} parts, and the most is ${PARTS_MOST}`);
  let part = numbers + NUMBERS_PER_SONG;
  const squares_met = { count: 0 };
  const cursors = effect_cursors[effect];
  for (let i = 0; i < part_total; i++) {
    const [walk, next] = read_part(number, part, 0, squares_met);
    part = next;
    if (cursors[i] >= walk.count) continue;
    const note = walk.notes + NUMBERS_PER_NOTE * cursors[i];
    if (rg_game_music[note] !== effect_frame[effect]) continue;
    cursors[i]++;
    play_effect_note(effect, walk, note);
  }
  effect_frame[effect]++;
}

/* --- the frame --- */

function effects_by_rank() { return EFFECT_ROWS + EFFECT_COUNT() * NUMBERS_PER_EFFECT; }

function rg_music_frame() {
  if (level < 0) level = FULL_LEVEL();
  refuse_too_many_effects();
  switch_to_wanted_song();
  for (let effect = 0; effect < EFFECT_COUNT(); effect++) {
    effect_asked_now[effect] = effect_asked[effect];
    effect_asked[effect] = 0;
  }
  const tune = playing >= 0 ? rg_game_music[song + 3] : -1;
  const by_rank = effects_by_rank();
  let at = 0;
  while (at < EFFECT_COUNT() && effect_field(rg_game_effects[by_rank + at], EFFECT_RANK) > tune) {
    play_effect_frame(rg_game_effects[by_rank + at++]);
  }
  if (playing >= 0) play_song_frame();
  while (at < EFFECT_COUNT()) play_effect_frame(rg_game_effects[by_rank + at++]);
}

function rg_music_start_here() {
  if (level < 0) level = FULL_LEVEL();
  if (switch_to_wanted_song() && playing >= 0) play_song_frame();
}

function rg_effect_start_here_one_of(effects, count, which) {
  if (which < 0 || which >= count) return;
  const asked = effects[which];
  request_effect(asked);
  if (!effect_asked[asked]) return;

  const by_rank = effects_by_rank();
  for (let at = 0; at < EFFECT_COUNT(); at++) {
    const effect = rg_game_effects[by_rank + at];
    if (effect === asked) {
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

function rg_music_start_here_one_of(songs, count, which) {
  if (which < 0 || which >= count) return;
  rg_music_request(songs[which]);
  rg_music_start_here();
}

function play_song_frame() {
  if (level_variable) follow_level(level_variable());
  for (let i = 0; i < part_count; i++) {
    const part = parts[i];
    if (part.next >= part.count) continue;
    const note = part.notes + NUMBERS_PER_NOTE * part.next;
    if (rg_game_music[note] !== song_frame) continue;

    play_note(part, note);
    part.next++;
  }

  song_frame++;
  if (song_frame < rg_game_music[song]) return;
  if (rg_game_music[song + 2]) {
    ended = playing;
    return;
  }
  song_frame = rg_game_music[song + 1];
  start_walks(1);
}
