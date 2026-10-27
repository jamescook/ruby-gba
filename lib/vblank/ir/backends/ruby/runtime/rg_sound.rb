# THE GAME'S SOUND: the music player, the four voices it and the game's own sounds play on, and the
# log of what was played. The rules are native/runtime/rg_sound.c's, rule for rule, and that file
# says every one of them and the layout of every table the lowering writes (@rg_game_music,
# @rg_game_beeps, ...); this one reads them the same way. Where the C keeps a pointer into one of
# those tables, this keeps the place in it.
#
# THE VOICES ARE A SOUND CHIP'S, not one console's: two square waves, a voice that loops a
# waveform of 32 steps, and a hiss from a row of bits. The Game Boy Advance and the Game Boy Color
# carry the same chip, and nothing here knows which of them the game was built for. Every number
# that belongs to a console comes in the game's own tables: how fast each voice's clock ticks
# (@rg_game_sound_rules), how long a frame is (rg_console_cycles_per_frame), and whether there is a
# mixer for recordings at all (@rg_game_mix, rg_mix.rb).
#
# The voices are worked out a sample at a time when a driver asks for a frame's sound
# (rg_sound_render_frame): the windowless one writes it to a file for a test. Nothing else needs
# the samples, so a driver that does not ask spends nothing on them.

RG_SOUND_RATE = 48000 # samples a second, whatever the console: the speaker's rate, not the chip's
RG_SOUND_FRAME_MOST = 1024
RG_SQUARE_VOICES = 2
RG_WAVE_VOICE = 3
RG_NOISE_VOICE = 4

RG_PARTS_MOST = 20
RG_NUMBERS_PER_NOTE = 4
RG_NUMBERS_PER_NOTE_SOUND = 8
RG_NUMBERS_PER_BEEP = 4
RG_NUMBERS_PER_WAVE = 3
RG_NUMBERS_PER_HIT = 4
RG_BEEP_VOICE = 2
RG_WAVE_STEPS = 32
RG_VOLUMES = 16

RG_PART_SQUARE = 0
RG_PART_WAVE = 1
RG_PART_NOISE = 2
RG_PART_RECORDED = 3

RG_WAVE_QUARTERS = 6 # where the wave voice's loudness for each volume starts in @rg_game_sound_rules
RG_SONG_STARTS = 1
RG_NUMBERS_PER_SONG = 5
RG_NUMBERS_PER_PART = 6
RG_EFFECT_ROWS = 2
RG_NUMBERS_PER_EFFECT = 5
RG_EFFECT_SONG = 0
RG_EFFECT_NOTES = 1
RG_EFFECT_RANK = 2
RG_EFFECT_GROUP = 3
RG_EFFECT_PRIORITY = 4
RG_EFFECTS_MOST = 512

# How much one step of loudness moves the speaker, and one step of the mixer's byte: two voices at
# their loudest swing through half of what a sample holds, and so does the mixer at its loudest.
RG_STEP_SIZE = 1092
RG_MIX_STEP = 128

# A loudness that fades: 0 to 15 now, the samples it holds each step for (0 never fades), and the
# samples left until the next step down.
class RgFading
  attr_accessor :volume, :hold_samples, :left

  def initialize(volume, fade_64ths)
    @volume = volume
    @hold_samples = fade_64ths * RG_SOUND_RATE / 64
    @left = @hold_samples
  end

  # One sample has gone by.
  def fade_one_sample
    return unless @hold_samples > 0 && @volume > 0

    @left -= 1
    return unless @left == 0

    @volume -= 1
    @left = @hold_samples
  end
end

# A square voice: ticks one wave lasts (0 has nothing to play), how many eighths of it are high,
# its loudness, which eighth it is in, and how far through it in ticks times samples a second.
class RgSquare
  attr_accessor :wave_ticks, :eighths_high, :loudness, :eighth, :eighth_progress

  def initialize = start(0, 0, 0, 0)

  def start(wave_ticks, eighths_high, volume, fade_64ths)
    @wave_ticks = wave_ticks
    @eighths_high = eighths_high
    @loudness = RgFading.new(volume, fade_64ths)
    @eighth = 0
    @eighth_progress = 0
  end
end

# The wave voice: the waveform it loops, whether it is switched on, ticks all its steps last,
# its loudness in quarters of each step, every step at that loudness added up, which step it is
# on, and how far through it.
class RgWave
  attr_accessor :steps, :switched_on, :wave_ticks, :quarters, :cut_sum, :step, :step_progress

  def initialize
    @steps = Array.new(RG_WAVE_STEPS, 0)
    @switched_on = false
    @wave_ticks = 0
    @quarters = 0
    @cut_sum = 0
    @step = 0
    @step_progress = 0
  end
end

# The noise voice: ticks one step of the hiss lasts, the bits in its row, the row, which way the
# last bit to fall off left the voice and which way it stood when the speaker was last handed it,
# its loudness, and how far through a step and to the next hand-over.
class RgHiss
  attr_accessor :step_ticks, :bits, :row, :high, :heard_high, :loudness, :row_progress, :hand_progress

  def initialize = start(0, 0, 0, 0)

  def start(step_ticks, bits, volume, fade_64ths)
    @step_ticks = step_ticks
    @bits = bits
    @row = (1 << bits) - 1
    @high = 0
    @heard_high = 0
    @loudness = RgFading.new(volume, fade_64ths)
    @row_progress = 0
    @hand_progress = 0
  end
end

# One part of a song as the player walks it: where its notes start in @rg_game_music, how many,
# the next to play, its kind and the voice it plays on, which of its song's parts it is, and the
# two numbers for what its voice sounds like.
RgPartWalk = Struct.new(:notes, :count, :next_note, :kind, :voice, :number, :tone, :fade)

# A note the player holds while the game keeps a music volume, so a change of volume sounds it
# again: the voice (0 for a recorded part, then its lane), its written volume, and what a square
# note needs to start again.
RgHeldNote = Struct.new(:voice, :lane, :volume, :wave_ticks, :eighths_high)

def rg_sound_setup
  @rg_squares = Array.new(RG_SQUARE_VOICES) { RgSquare.new }
  @rg_wave = RgWave.new
  @rg_hiss = RgHiss.new
  @rg_heard_only = 0 # a test listening to one voice: its number, or 0 for every voice
  @rg_sample_carry = 0 # the part of a sample left over from the last frame, in console cycles
  @rg_loaded_waveform = -1
  # the player
  @rg_wanted = -1
  @rg_playing = -1
  @rg_ended = -1
  @rg_stops = 0
  @rg_stops_seen = 0
  @rg_song = 0 # where the playing song's numbers start in @rg_game_music
  @rg_song_frame = 0
  @rg_part_count = 0
  @rg_parts = Array.new(RG_PARTS_MOST)
  @rg_level_variable = nil # reads the game's music volume, for a game that keeps one
  @rg_level = -1
  @rg_holding = []
  # who holds each console voice, by rank, and the voices in the order they were first claimed
  @rg_holders = [0, 0, 0, 0, 0]
  @rg_holder_order = []
  # the sound effects
  @rg_effect_asked = Array.new(RG_EFFECTS_MOST, false)
  @rg_effect_asked_now = Array.new(RG_EFFECTS_MOST, false)
  @rg_effect_stopping = Array.new(RG_EFFECTS_MOST, false)
  @rg_effect_running = Array.new(RG_EFFECTS_MOST, false)
  @rg_effect_frame = Array.new(RG_EFFECTS_MOST, 0)
  @rg_effect_cursors = Array.new(RG_EFFECTS_MOST)
end

def rg_square_clock_hz = @rg_game_sound_rules[0]
def rg_wave_clock_hz = @rg_game_sound_rules[1]
def rg_noise_clock_hz = @rg_game_sound_rules[2]
def rg_output_hz = @rg_game_sound_rules[3]
def rg_full_level = @rg_game_sound_rules[4]
def rg_level_shift = @rg_game_sound_rules[5]
def rg_order_mask = @rg_game_sound_rules[RG_WAVE_QUARTERS + RG_VOLUMES]
def rg_song_count = @rg_game_music[0]
def rg_effect_count = @rg_game_effects[0]
def rg_effects_play_wave = @rg_game_effects[1]

# C's division, which drops the fraction toward nought: Ruby's rounds down, which differs for a
# sample below nought.
def rg_sound_quotient(numerator, denominator)
  numerator < 0 ? -(-numerator / denominator) : numerator / denominator
end

# --- the square voices ---

def rg_square_start(voice, wave_ticks, eighths_high, volume, fade_64ths)
  @rg_squares[voice - 1].start(wave_ticks, eighths_high, volume, fade_64ths)
end

# Which of the eight parts of a wave are high, for each tone, in the chip's own order.
def rg_eighth_is_high(eighths_high, eighth)
  case eighths_high
  when 1 then eighth == 7
  when 2 then eighth == 0 || eighth == 7
  when 4 then eighth == 0 || eighth >= 5
  else eighth >= 1 && eighth <= 6
  end
end

# One sample of a square voice, high and low set either side of nought by how long each lasts.
def rg_square_sample(square)
  return 0 if square.wave_ticks == 0 || square.loudness.volume == 0

  high = rg_eighth_is_high(square.eighths_high, square.eighth)
  sample = rg_sound_quotient(RG_STEP_SIZE * square.loudness.volume * (high ? 8 - square.eighths_high : -square.eighths_high), 8)

  eighth_length = square.wave_ticks * RG_SOUND_RATE
  square.eighth_progress += rg_square_clock_hz * 8
  while square.eighth_progress >= eighth_length
    square.eighth_progress -= eighth_length
    square.eighth = (square.eighth + 1) & 7
  end
  square.loudness.fade_one_sample
  sample
end

# --- the wave voice ---

def rg_wave_step_cut(step) = step * @rg_wave.quarters / 4

def rg_wave_set_loudness(quarters)
  @rg_wave.quarters = quarters
  @rg_wave.cut_sum = @rg_wave.steps.sum { |step| rg_wave_step_cut(step) }
end

# Waveform number +which+ goes into the voice, which switches it on and stops what it played.
def rg_wave_load(which)
  rg_fault("there is no waveform number #{which}") if which < 0 || which >= @rg_game_waveforms[0]
  @rg_wave.steps = @rg_game_waveforms[1 + (which * RG_WAVE_STEPS), RG_WAVE_STEPS]
  @rg_loaded_waveform = which
  @rg_wave.switched_on = true
  @rg_wave.wave_ticks = 0
  rg_wave_set_loudness(@rg_wave.quarters)
end

# A note from the top of the waveform, if the voice is switched on.
def rg_wave_start(wave_ticks, quarters)
  @rg_wave.wave_ticks = @rg_wave.switched_on ? wave_ticks : 0
  @rg_wave.step = 0
  @rg_wave.step_progress = 0
  rg_wave_set_loudness(quarters)
end

def rg_wave_switch_off
  @rg_wave.switched_on = false
  @rg_wave.wave_ticks = 0
end

# One sample of the wave voice, each step set either side of the middle of the whole waveform.
def rg_wave_sample
  wave = @rg_wave
  return 0 if wave.wave_ticks == 0

  sample = rg_sound_quotient(RG_STEP_SIZE * ((RG_WAVE_STEPS * rg_wave_step_cut(wave.steps[wave.step])) - wave.cut_sum),
                             RG_WAVE_STEPS)
  step_length = wave.wave_ticks * RG_SOUND_RATE
  wave.step_progress += rg_wave_clock_hz * RG_WAVE_STEPS
  while wave.step_progress >= step_length
    wave.step_progress -= step_length
    wave.step = (wave.step + 1) % RG_WAVE_STEPS
  end
  sample
end

# --- the noise voice ---

# A hit starts with every bit of the row set, which is where the emulator picks the pattern up.
def rg_noise_start(step_ticks, bits, volume, fade_64ths) = @rg_hiss.start(step_ticks, bits, volume, fade_64ths)

# One step of the hiss: the bit at the end falls off and says which way the voice stands, and when
# it was set it is stirred back into the two places at the other end.
def rg_noise_step
  hiss = @rg_hiss
  fell = hiss.row & 1
  hiss.row >>= 1
  hiss.row ^= 3 << (hiss.bits - 2) if fell != 0
  hiss.high = fell
end

# One sample of the noise voice. The hiss steps on its own clock, but the speaker is handed it
# only so many times a second, and hears whichever way it stood then until the next time.
def rg_noise_sample
  hiss = @rg_hiss
  return 0 if hiss.step_ticks == 0 || hiss.loudness.volume == 0

  hiss.hand_progress += rg_output_hz
  while hiss.hand_progress >= RG_SOUND_RATE
    hiss.hand_progress -= RG_SOUND_RATE
    step_length = hiss.step_ticks * rg_output_hz
    hiss.row_progress += rg_noise_clock_hz
    while hiss.row_progress >= step_length
      hiss.row_progress -= step_length
      rg_noise_step
    end
    hiss.heard_high = hiss.high
  end
  sample = rg_sound_quotient(RG_STEP_SIZE * hiss.loudness.volume * (hiss.heard_high != 0 ? 1 : -1), 2)
  hiss.loudness.fade_one_sample
  sample
end

# --- the sound of a frame ---

def rg_sound_hear_only(voice)
  @rg_heard_only = voice
end

def rg_sound_heard(voice, sample) = @rg_heard_only == 0 || @rg_heard_only == voice ? sample : 0

# The sound of the frame that has just been played, as an Array of samples: that frame's share of
# a second's, by the console's own clock, with the part of a sample left over carried to the next
# frame so no time is lost or made up.
def rg_sound_render_frame
  @rg_sample_carry += RG_SOUND_RATE * rg_console_cycles_per_frame
  count = @rg_sample_carry / rg_console_cycles_per_second
  @rg_sample_carry %= rg_console_cycles_per_second

  # The mixer's newest slice is stretched over the frame, and heard only with every voice.
  mixed = @rg_heard_only == 0 ? rg_mix_newest_slice : nil
  mixed_count = mixed ? mixed.length : 0
  Array.new(count) do |i|
    sum = 0 # every voice moves on, heard or not
    @rg_squares.each_with_index { |square, at| sum += rg_sound_heard(at + 1, rg_square_sample(square)) }
    sum += rg_sound_heard(RG_WAVE_VOICE, rg_wave_sample)
    sum += rg_sound_heard(RG_NOISE_VOICE, rg_noise_sample)
    sum += mixed[i * mixed_count / count] * RG_MIX_STEP if mixed_count > 0
    sum.clamp(-32768, 32767)
  end
end

# --- the log ---

def rg_sound_log(line) = rg_driver_sound_logged(line)

# --- the sounds the game makes itself ---

def rg_sound_enabled = rg_sound_log("enabled")

def rg_sound_beep(which)
  rg_fault("there is no beep number #{which}") if which < 0 || which >= @rg_game_beeps[0]
  beep = 1 + (which * RG_NUMBERS_PER_BEEP)
  rg_sound_log("beep #{which}")
  rg_square_start(RG_BEEP_VOICE, @rg_game_beeps[beep], @rg_game_beeps[beep + 1], @rg_game_beeps[beep + 2],
                  @rg_game_beeps[beep + 3])
end

def rg_sound_wave(which)
  rg_fault("there is no wave number #{which}") if which < 0 || which >= @rg_game_waves[0]
  said = 1 + (which * RG_NUMBERS_PER_WAVE)
  rg_sound_log("wave #{which}")
  rg_wave_load(@rg_game_waves[said])
  rg_wave_start(@rg_game_waves[said + 1], @rg_game_waves[said + 2])
  @rg_loaded_waveform = -1
end

def rg_sound_stop_wave
  rg_sound_log("stop_wave")
  rg_wave_switch_off
  @rg_loaded_waveform = -1
end

def rg_sound_noise(which)
  rg_fault("there is no hit number #{which}") if which < 0 || which >= @rg_game_hits[0]
  hit = 1 + (which * RG_NUMBERS_PER_HIT)
  rg_sound_log("noise #{which}")
  rg_noise_start(@rg_game_hits[hit], @rg_game_hits[hit + 1], @rg_game_hits[hit + 2], @rg_game_hits[hit + 3])
end

# --- the player ---

def rg_music_request(number)
  rg_fault("there is no song number #{number}") if number < 0 || number >= rg_song_count
  @rg_wanted = number
end

def rg_music_request_one_of(songs, count, which)
  rg_music_request(songs[which]) if which >= 0 && which < count
end

def rg_music_stop
  @rg_wanted = -1
  @rg_stops += 1
end

def rg_music_follow_level(variable)
  @rg_level_variable = variable
end

# Where song number +number+'s numbers start, from its length on.
def rg_song_numbers(number) = @rg_game_music[RG_SONG_STARTS + number]

# The part of song number +number+ written at +part+ (a place in @rg_game_music), as a walk of its
# notes, and where the song's next part is written. +squares_met+ counts the square parts so far.
def rg_read_part(number, part, again, squares_met)
  music = @rg_game_music
  kind = music[part]
  first = music[part + 4]
  after = music[part + 5]
  first_notes = part + RG_NUMBERS_PER_PART
  after_notes = first_notes + (RG_NUMBERS_PER_NOTE * first)
  voice = case kind
          when RG_PART_WAVE then RG_WAVE_VOICE
          when RG_PART_NOISE then RG_NOISE_VOICE
          when RG_PART_RECORDED then 0
          else squares_met[0] += 1
          end
  if squares_met[0] > RG_SQUARE_VOICES
    rg_fault("song number #{number} has more parts on the square wave than the #{RG_SQUARE_VOICES} there are")
  end
  walk = RgPartWalk.new(again ? after_notes : first_notes, again ? after : first, 0, kind, voice, music[part + 1],
                        music[part + 2], music[part + 3])
  [walk, after_notes + (RG_NUMBERS_PER_NOTE * after)]
end

def rg_start_walks(again)
  part = @rg_song + RG_NUMBERS_PER_SONG
  squares_met = [0]
  @rg_part_count.times do |i|
    walk, part = rg_read_part(@rg_playing, part, again, squares_met)
    @rg_parts[i] = walk
  end
end

def rg_scaled_volume(volume) = (volume * @rg_level) >> rg_level_shift

def rg_wave_quarters_at(volume) = @rg_game_sound_rules[RG_WAVE_QUARTERS + volume.clamp(0, RG_VOLUMES - 1)]

def rg_log_held_loudness(note)
  if note.voice == 0
    rg_sound_log("mixer_loudness #{note.lane} #{rg_scaled_volume(note.volume)}")
  else
    rg_sound_log("loudness #{note.voice} #{rg_scaled_volume(note.volume)}")
  end
end

def rg_hold_note(note)
  at = @rg_holding.index { |held| held.voice == note.voice && (note.voice != 0 || held.lane == note.lane) }
  @rg_holding[at || @rg_holding.length] = note
  rg_log_held_loudness(note)
end

def rg_follow_level(now)
  return if now == @rg_level

  @rg_level = now
  @rg_holding.each do |note|
    next if note.volume <= 0
    next if note.voice == 0 && rg_mix_rescale_music(note.lane, rg_scaled_volume(note.volume)) == 0

    rg_log_held_loudness(note)
    next if note.voice == 0

    if note.voice == RG_WAVE_VOICE
      rg_wave_set_loudness(rg_wave_quarters_at(rg_scaled_volume(note.volume)))
    else
      rg_square_start(note.voice, note.wave_ticks, note.eighths_high, rg_scaled_volume(note.volume), 0)
    end
  end
end

def rg_silence_voice(voice)
  case voice
  when RG_WAVE_VOICE then rg_wave_set_loudness(0)
  when RG_NOISE_VOICE then rg_noise_start(0, @rg_hiss.bits, 0, 0)
  else rg_square_start(voice, 0, 0, 0, 0)
  end
end

def rg_rest_on(part)
  rg_silence_voice(part.voice) if part.kind != RG_PART_RECORDED
end

# --- who holds a console voice ---

def rg_claim_voice(voice, rank, sounds)
  return false if @rg_holders[voice] > rank

  @rg_holder_order << voice unless @rg_holder_order.include?(voice)
  @rg_holders[voice] = sounds ? rank : 0
  true
end

def rg_note_sounds(kind, pitch, volume)
  return false if pitch == 0 || volume <= 0

  kind != RG_PART_WAVE || rg_wave_quarters_at(volume) != 0
end

def rg_wave_put_in(which)
  rg_wave_load(which) unless which == @rg_loaded_waveform
end

def rg_silence_song
  rg_sound_log("stop_music")
  @rg_part_count.times do |i|
    part = @rg_parts[i]
    next if part.kind == RG_PART_RECORDED || (@rg_holders[part.voice] & rg_order_mask) != 0

    rg_rest_on(part)
  end
  (1..RG_NOISE_VOICE).each { |voice| @rg_holders[voice] = 0 if (@rg_holders[voice] & rg_order_mask) == 0 }
  @rg_holding = []
  rg_mix_release_all_music
end

# Catches up with the tune the game asked for. True when it changed to another, or to none.
def rg_switch_to_wanted_song
  if @rg_ended >= 0
    if @rg_wanted == @rg_ended && @rg_stops == @rg_stops_seen
      rg_silence_song if @rg_playing >= 0
      @rg_playing = -1
      return false
    end
    @rg_ended = -1
  end
  return false if @rg_wanted == @rg_playing && @rg_stops == @rg_stops_seen

  @rg_stops_seen = @rg_stops
  rg_silence_song if @rg_playing >= 0
  @rg_playing = @rg_wanted
  @rg_song_frame = 0
  @rg_part_count = 0
  return true if @rg_playing < 0

  @rg_song = rg_song_numbers(@rg_playing)
  @rg_part_count = @rg_game_music[@rg_song + 4]
  if @rg_part_count > RG_PARTS_MOST
    rg_fault("song number #{@rg_playing} has #{@rg_part_count} parts, and the most is #{RG_PARTS_MOST}")
  end
  rg_start_walks(false)
  return true if rg_effects_play_wave != 0

  wave_part = @rg_parts.first(@rg_part_count).find { |part| part.kind == RG_PART_WAVE }
  rg_wave_load(wave_part.tone) if wave_part
  true
end

def rg_play_recorded_note(part, note)
  music = @rg_game_music
  pitch = music[note + 1]
  loudness = music[note + 2]
  sound = music[note + 3]
  if pitch == 0 || loudness <= 0
    rg_mix_release_music(-1, part.tone)
  else
    numbers = 1 + (sound * RG_NUMBERS_PER_NOTE_SOUND)
    heard = rg_mix_start_music_note(-1, part.tone, music[@rg_song + 3], numbers,
                                    @rg_level_variable ? rg_scaled_volume(loudness) : loudness)
    return if heard == 0
  end
  rg_sound_log("note #{@rg_playing} #{pitch}")
  rg_hold_note(RgHeldNote.new(0, part.tone, pitch == 0 ? 0 : loudness, 0, 0)) if @rg_level_variable
end

def rg_play_note(part, note)
  return rg_play_recorded_note(part, note) if part.kind == RG_PART_RECORDED

  music = @rg_game_music
  pitch = music[note + 1]
  volume = music[note + 2]
  ticks = music[note + 3]
  return unless rg_claim_voice(part.voice, music[@rg_song + 3], rg_note_sounds(part.kind, pitch, volume))

  written = pitch == 0 ? 0 : volume
  sounded = @rg_level_variable ? rg_scaled_volume(written) : written
  rg_sound_log("note #{@rg_playing} #{pitch}")
  rg_sound_log("voice #{part.voice} #{@rg_playing} #{pitch} #{volume}")
  case part.kind
  when RG_PART_WAVE
    rg_hold_note(RgHeldNote.new(part.voice, 0, written, 0, 0)) if @rg_level_variable
    if pitch == 0
      rg_sound_log("stop_wave")
      rg_rest_on(part)
    else
      rg_sound_log("part_wave #{@rg_playing} #{part.number} #{pitch}")
      rg_wave_put_in(part.tone) if rg_effects_play_wave != 0
      rg_wave_start(ticks, rg_wave_quarters_at(sounded))
    end
  when RG_PART_NOISE
    rg_sound_log("loudness #{part.voice} #{sounded}") if @rg_level_variable
    if pitch == 0
      rg_sound_log("noise_rest")
      rg_rest_on(part)
    else
      rg_sound_log("part_noise #{@rg_playing} #{part.number} #{pitch}")
      rg_noise_start(ticks, part.tone, sounded, part.fade)
    end
  else
    rg_hold_note(RgHeldNote.new(part.voice, 0, written, ticks, part.tone)) if @rg_level_variable
    rg_square_start(part.voice, ticks, part.tone, sounded, 0)
  end
end

# --- sound effects ---

def rg_effect_field(effect, field) = @rg_game_effects[RG_EFFECT_ROWS + (effect * RG_NUMBERS_PER_EFFECT) + field]

def rg_effect_pending(effect) = @rg_effect_asked[effect] || (@rg_effect_running[effect] && !@rg_effect_stopping[effect])

def rg_refuse_too_many_effects
  return unless rg_effect_count > RG_EFFECTS_MOST

  rg_fault("the game has #{rg_effect_count} sound effects, and the most is #{RG_EFFECTS_MOST}")
end

def rg_request_effect(effect)
  rg_refuse_too_many_effects
  group = rg_effect_field(effect, RG_EFFECT_GROUP)
  if group >= 0
    rg_effect_count.times do |other|
      next if rg_effect_field(other, RG_EFFECT_GROUP) != group || !rg_effect_pending(other)
      return if rg_effect_field(effect, RG_EFFECT_PRIORITY) < rg_effect_field(other, RG_EFFECT_PRIORITY)

      @rg_effect_asked[other] = false
      @rg_effect_stopping[other] = true
      break
    end
  end
  @rg_effect_asked[effect] = true
end

def rg_effect_request_one_of(effects, count, which)
  rg_request_effect(effects[which]) if which >= 0 && which < count
end

def rg_drop_held_note(voice)
  @rg_holding = @rg_holding.reject { |note| note.voice == voice }
end

def rg_finish_effect(effect)
  number = rg_effect_field(effect, RG_EFFECT_SONG)
  rank = rg_effect_field(effect, RG_EFFECT_RANK)
  @rg_effect_running[effect] = false
  @rg_holder_order.each do |voice|
    next if @rg_holders[voice] != rank

    @rg_holders[voice] = 0
    rg_sound_log("note #{number} 0")
    rg_sound_log("voice #{voice} #{number} 0 0")
    rg_sound_log("noise_rest") if voice == RG_NOISE_VOICE
    rg_sound_log("stop_wave") if voice == RG_WAVE_VOICE
    rg_silence_voice(voice)
  end

  numbers = rg_song_numbers(rg_effect_field(effect, RG_EFFECT_NOTES))
  part = numbers + RG_NUMBERS_PER_SONG
  squares_met = [0]
  @rg_game_music[numbers + 4].times do
    walk, part = rg_read_part(number, part, false, squares_met)
    rg_sound_log("note #{number} 0") if walk.kind == RG_PART_RECORDED && rg_mix_release_music(effect, walk.tone) != 0
  end
end

def rg_play_effect_note(effect, part, note)
  music = @rg_game_music
  number = rg_effect_field(effect, RG_EFFECT_SONG)
  rank = rg_effect_field(effect, RG_EFFECT_RANK)
  pitch = music[note + 1]
  volume = music[note + 2]
  sounds = rg_note_sounds(part.kind, pitch, volume)

  if part.kind == RG_PART_RECORDED
    sound = music[note + 3]
    heard = if sounds
              rg_mix_start_music_note(effect, part.tone, rank, 1 + (sound * RG_NUMBERS_PER_NOTE_SOUND), volume)
            else
              rg_mix_release_music(effect, part.tone)
            end
    rg_sound_log("note #{number} #{pitch}") if heard != 0
    return
  end
  return unless rg_claim_voice(part.voice, rank, sounds)

  ticks = music[note + 3]
  rg_drop_held_note(part.voice)
  rg_sound_log("note #{number} #{pitch}")
  rg_sound_log("voice #{part.voice} #{number} #{pitch} #{volume}")
  case part.kind
  when RG_PART_WAVE
    if pitch == 0
      rg_sound_log("stop_wave")
      rg_silence_voice(part.voice)
    else
      rg_sound_log("part_wave #{number} #{part.number} #{pitch}")
      rg_wave_put_in(part.tone)
      rg_wave_start(ticks, rg_wave_quarters_at(volume))
    end
  when RG_PART_NOISE
    if pitch == 0
      rg_sound_log("noise_rest")
      rg_silence_voice(part.voice)
    else
      rg_sound_log("part_noise #{number} #{part.number} #{pitch}")
      rg_noise_start(ticks, part.tone, volume, part.fade)
    end
  else
    rg_square_start(part.voice, ticks, part.tone, pitch == 0 ? 0 : volume, 0)
  end
end

def rg_play_effect_frame(effect)
  number = rg_effect_field(effect, RG_EFFECT_SONG)
  numbers = rg_song_numbers(rg_effect_field(effect, RG_EFFECT_NOTES))
  if @rg_effect_stopping[effect]
    @rg_effect_stopping[effect] = false
    rg_finish_effect(effect)
  end
  if @rg_effect_asked_now[effect]
    @rg_effect_running[effect] = true
    @rg_effect_frame[effect] = 0
    @rg_effect_cursors[effect] = Array.new(RG_PARTS_MOST, 0)
    rg_sound_log("sound_effect #{effect}")
  elsif @rg_effect_running[effect] && @rg_effect_frame[effect] >= @rg_game_music[numbers]
    rg_finish_effect(effect)
  end
  return unless @rg_effect_running[effect]

  part_total = @rg_game_music[numbers + 4]
  rg_fault("a sound effect has #{part_total} parts, and the most is #{RG_PARTS_MOST}") if part_total > RG_PARTS_MOST
  part = numbers + RG_NUMBERS_PER_SONG
  squares_met = [0]
  cursors = @rg_effect_cursors[effect]
  part_total.times do |i|
    walk, part = rg_read_part(number, part, false, squares_met)
    next if cursors[i] >= walk.count

    note = walk.notes + (RG_NUMBERS_PER_NOTE * cursors[i])
    next if @rg_game_music[note] != @rg_effect_frame[effect]

    cursors[i] += 1
    rg_play_effect_note(effect, walk, note)
  end
  @rg_effect_frame[effect] += 1
end

# --- the frame ---

def rg_effects_by_rank = RG_EFFECT_ROWS + (rg_effect_count * RG_NUMBERS_PER_EFFECT)

# The player's frame: the tune caught up with, then every effect that outranks the tune, the tune,
# and the effects below it.
def rg_music_frame
  @rg_level = rg_full_level if @rg_level < 0
  rg_refuse_too_many_effects
  rg_switch_to_wanted_song
  rg_effect_count.times do |effect|
    @rg_effect_asked_now[effect] = @rg_effect_asked[effect]
    @rg_effect_asked[effect] = false
  end
  tune = @rg_playing >= 0 ? @rg_game_music[@rg_song + 3] : -1
  by_rank = rg_effects_by_rank
  at = 0
  while at < rg_effect_count && rg_effect_field(@rg_game_effects[by_rank + at], RG_EFFECT_RANK) > tune
    rg_play_effect_frame(@rg_game_effects[by_rank + at])
    at += 1
  end
  rg_play_song_frame if @rg_playing >= 0
  while at < rg_effect_count
    rg_play_effect_frame(@rg_game_effects[by_rank + at])
    at += 1
  end
end

def rg_music_start_here
  @rg_level = rg_full_level if @rg_level < 0
  rg_play_song_frame if rg_switch_to_wanted_song && @rg_playing >= 0
end

def rg_effect_start_here_one_of(effects, count, which)
  return if which < 0 || which >= count

  asked = effects[which]
  rg_request_effect(asked)
  return unless @rg_effect_asked[asked]

  by_rank = rg_effects_by_rank
  rg_effect_count.times do |at|
    effect = @rg_game_effects[by_rank + at]
    if effect == asked
      @rg_effect_asked[asked] = false
      @rg_effect_asked_now[asked] = true
      rg_play_effect_frame(asked)
      @rg_effect_asked_now[asked] = false
    elsif @rg_effect_stopping[effect]
      @rg_effect_stopping[effect] = false
      rg_finish_effect(effect)
    end
  end
end

def rg_music_start_here_one_of(songs, count, which)
  return if which < 0 || which >= count

  rg_music_request(songs[which])
  rg_music_start_here
end

def rg_play_song_frame
  rg_follow_level(@rg_level_variable.call) if @rg_level_variable
  @rg_part_count.times do |i|
    part = @rg_parts[i]
    next if part.next_note >= part.count

    note = part.notes + (RG_NUMBERS_PER_NOTE * part.next_note)
    next if @rg_game_music[note] != @rg_song_frame

    rg_play_note(part, note)
    part.next_note += 1
  end

  @rg_song_frame += 1
  return if @rg_song_frame < @rg_game_music[@rg_song]

  if @rg_game_music[@rg_song + 2] != 0
    @rg_ended = @rg_playing
    return
  end
  @rg_song_frame = @rg_game_music[@rg_song + 1]
  rg_start_walks(true)
end
