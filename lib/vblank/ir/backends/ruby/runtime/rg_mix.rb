# THE MIXER: several recordings sounding at once, added together a frame at a time into one stream
# of sound, the way a console that mixes in software does it. The arithmetic is native/runtime/
# rg_mix.c's, kept to the bit, and that file says it and the layout of @rg_game_mix and
# @rg_game_recordings. A console with no mixer has none of this to do: its game's @rg_game_mix
# starts with nought, and every frame here then does nothing.
#
# The interpreter's numbers are Ruby's whole numbers, and so are these, so a product too big for
# 32 bits is exact here as it is there.

RG_MIX_VOICES_MOST = 16
RG_NUMBERS_PER_RECORDING = 7

# Which part of its shape a note is in, and the frame after it has fallen to nothing.
RG_SHAPE_CLIMBING = 0
RG_SHAPE_HOLDING = 1
RG_SHAPE_FALLING = 2
RG_SHAPE_DONE = 3

# Whose a voice is: the game's own sound, a part of the song playing, or a part of a sound effect.
RG_MIX_GAME = 0
RG_MIX_SONG = 1
RG_MIX_EFFECT = 2

# One voice of the mixer (the fields are rg_mix.c's mix_voice's, and say the same things).
class RgMixVoice
  attr_accessor :sounding, :owner, :effect, :lane, :rank, :loops, :ticket, :recording, :position, :fraction, :step,
                :back, :loudness, :gain, :ramp, :shaped, :level, :phase, :attack, :decay, :sustain, :release

  def initialize
    @sounding = false
    @owner = RG_MIX_GAME
    @effect = 0
    @lane = 0
    @rank = 0
    @loops = 0
    @ticket = 0
    @recording = 0
    @position = 0
    @fraction = 0
    @step = 0
    @back = 0
    @loudness = 0
    @gain = 0
    @ramp = 0
    @shaped = 0
    @level = 0
    @phase = RG_SHAPE_CLIMBING
    @attack = 0
    @decay = 0
    @sustain = 0
    @release = 0
  end

  def releasing? = @owner != RG_MIX_GAME && (@phase == RG_SHAPE_FALLING || @phase == RG_SHAPE_DONE)
end

def rg_mix_setup
  @rg_mix_voices = Array.new(RG_MIX_VOICES_MOST) { RgMixVoice.new }
  @rg_mix_slice = nil # one frame's slice, made the game's length the first time a frame is mixed
  @rg_mix_slices_made = 0
  @rg_mix_peak = 0
  @rg_mix_drop_count = 0 # plays that found every voice busy
  @rg_mix_drops_music = 0 # the most voices the music held at one of those moments
  @rg_mix_tickets = 0
end

def rg_mixes = @rg_game_mix[0]
def rg_slice_samples = @rg_game_mix[1]
def rg_mix_shapes = @rg_game_mix[2]
def rg_slide_share = @rg_game_mix[3]
def rg_mix_voice_count = @rg_game_mix[4]
def rg_vol_shift = @rg_game_mix[5]
def rg_step_shift = @rg_game_mix[6]
def rg_gain_fraction = @rg_game_mix[7]
def rg_ramp_split = @rg_game_mix[8]
def rg_shape_full = @rg_game_mix[9]
def rg_shape_scale = @rg_game_mix[10]
def rg_loudness_to_gain = @rg_game_mix[11]
def rg_whole_gain_shift = @rg_game_mix[12]

# Where recording number +recording+'s numbers start in @rg_game_recordings.
def rg_recording_numbers(recording)
  rg_fault("there is no recording number #{recording}") if recording < 0 || recording >= @rg_game_recordings[0]
  1 + (recording * RG_NUMBERS_PER_RECORDING)
end

# The voices the game has, refused past the most there is room for.
def rg_mix_voices_in_use
  if rg_mix_voice_count > RG_MIX_VOICES_MOST
    rg_fault("the mixer has #{rg_mix_voice_count} voices, and the most is #{RG_MIX_VOICES_MOST}")
  end
  @rg_mix_voices.first(rg_mix_voice_count)
end

def rg_mix_record_peak
  now = @rg_mix_voices.first(rg_mix_voice_count).count(&:sounding)
  @rg_mix_peak = now if now > @rg_mix_peak
end

def rg_mix_record_drop
  music = @rg_mix_voices.first(rg_mix_voice_count).count { |voice| voice.sounding && voice.owner != RG_MIX_GAME }
  @rg_mix_drop_count += 1
  @rg_mix_drops_music = music if music > @rg_mix_drops_music
end

def rg_mix_free_voice = rg_mix_voices_in_use.index { |voice| !voice.sounding } || -1

def rg_mix_quietest_releasing_voice
  found = -1
  rg_mix_voice_count.times do |i|
    voice = @rg_mix_voices[i]
    next unless voice.sounding && voice.releasing?

    found = i if found < 0 || voice.level < @rg_mix_voices[found].level
  end
  found
end

def rg_mix_lowest_ranked_voice_below(rank)
  found = -1
  rg_mix_voice_count.times do |i|
    voice = @rg_mix_voices[i]
    next if !voice.sounding || voice.rank >= rank

    if found >= 0
      best = @rg_mix_voices[found]
      next if voice.rank > best.rank
      next if voice.rank == best.rank && (voice.loops > best.loops || (voice.loops == best.loops && voice.ticket >= best.ticket))
    end
    found = i
  end
  found
end

# A voice at the top of +recording+, shaped by the five numbers of +shape+ from +at+ (whether it
# has one, then its four numbers).
def rg_mix_start_voice(voice_at, recording, step, back, loudness, shape, at)
  rg_recording_numbers(recording)
  shaped = shape[at]
  voice = RgMixVoice.new
  voice.sounding = true
  voice.rank = -1
  voice.recording = recording
  voice.step = step
  voice.back = back
  voice.loudness = loudness
  voice.gain = shaped != 0 ? 0 : loudness << rg_loudness_to_gain
  voice.shaped = shaped
  voice.level = shaped != 0 ? 0 : rg_shape_full
  voice.attack = shape[at + 1]
  voice.decay = shape[at + 2]
  voice.sustain = shape[at + 3]
  voice.release = shape[at + 4]
  @rg_mix_voices[voice_at] = voice
end

def rg_mix_play(recording, step, loudness, back, loops)
  rg_sound_log("sample #{recording}")
  at = rg_mix_free_voice
  at = rg_mix_quietest_releasing_voice if at < 0
  return rg_mix_record_drop if at < 0

  rg_mix_start_voice(at, recording, step, back, loudness, @rg_game_recordings, rg_recording_numbers(recording) + 2)
  @rg_mix_voices[at].loops = loops
  @rg_mix_voices[at].ticket = (@rg_mix_tickets += 1)
  rg_mix_record_peak
end

def rg_mix_sounding_voice(effect, lane)
  owner = effect < 0 ? RG_MIX_SONG : RG_MIX_EFFECT
  rg_mix_voice_count.times do |i|
    voice = @rg_mix_voices[i]
    next if !voice.sounding || voice.owner != owner || voice.lane != lane || voice.releasing?
    return i if owner == RG_MIX_SONG || voice.effect == effect
  end
  -1
end

def rg_mix_start_release(voice)
  return false if voice.shaped == 0

  voice.phase = RG_SHAPE_FALLING
  true
end

# +sound+ is where the note's eight numbers start in @rg_game_note_sounds. 1 when it is heard.
def rg_mix_start_music_note(effect, lane, rank, sound, loudness)
  at = rg_mix_sounding_voice(effect, lane)
  at = -1 if at >= 0 && rg_mix_start_release(@rg_mix_voices[at])
  at = rg_mix_free_voice if at < 0
  at = rg_mix_quietest_releasing_voice if at < 0
  at = rg_mix_lowest_ranked_voice_below(rank) if at < 0
  if at < 0
    rg_mix_record_drop
    return 0
  end

  sounds = @rg_game_note_sounds
  rg_mix_start_voice(at, sounds[sound], sounds[sound + 1], sounds[sound + 2], loudness, sounds, sound + 3)
  voice = @rg_mix_voices[at]
  voice.owner = effect < 0 ? RG_MIX_SONG : RG_MIX_EFFECT
  voice.effect = effect
  voice.lane = lane
  voice.rank = rank
  1
end

# 1 when the part had a note sounding to let go of.
def rg_mix_release_music(effect, lane)
  at = rg_mix_sounding_voice(effect, lane)
  return 0 if at < 0

  @rg_mix_voices[at].sounding = false unless rg_mix_start_release(@rg_mix_voices[at])
  1
end

def rg_mix_release_all_music
  @rg_mix_voices.first(rg_mix_voice_count).each do |voice|
    next if !voice.sounding || voice.owner != RG_MIX_SONG || voice.releasing?

    voice.sounding = false unless rg_mix_start_release(voice)
  end
end

# 1 when the song's part had a note sounding to make louder or quieter.
def rg_mix_rescale_music(lane, loudness)
  at = rg_mix_sounding_voice(-1, lane)
  return 0 if at < 0

  voice = @rg_mix_voices[at]
  voice.loudness = loudness
  voice.gain = loudness << rg_loudness_to_gain if voice.shaped == 0
  1
end

def rg_mix_stop(recording)
  @rg_mix_voices.first(rg_mix_voice_count).each do |voice|
    voice.sounding = false if voice.sounding && voice.owner == RG_MIX_GAME && (recording < 0 || voice.recording == recording)
  end
  rg_sound_log("stop_sample")
end

# One voice's frame added into +totals+. False when its recording ran out partway and it stopped.
def rg_mix_voice_into(voice, totals)
  numbers = rg_recording_numbers(voice.recording)
  data = @rg_game_recordings[numbers]
  length = @rg_game_recordings[numbers + 1]
  samples = @rg_game_recording_samples
  step_shift = rg_step_shift
  step_mask = (1 << step_shift) - 1
  whole = voice.step >> step_shift
  part = voice.step & step_mask
  down = rg_vol_shift + rg_gain_fraction
  gain = rg_mix_shapes != 0 ? voice.gain : voice.loudness << rg_loudness_to_gain
  rg_slice_samples.times do |at|
    totals[at] += (gain * samples[data + voice.position]) >> down
    gain += voice.ramp
    voice.fraction += part
    voice.position += whole + (voice.fraction >> step_shift)
    voice.fraction &= step_mask
    next if voice.position < length
    return false if voice.back == 0

    voice.position -= voice.back while voice.position >= length
    rg_sound_log("sample #{voice.recording}") if voice.owner == RG_MIX_GAME
  end
  voice.gain = gain
  true
end

def rg_mix_frame
  return if rg_mixes == 0

  slice = Array.new(rg_slice_samples, 0)
  rg_mix_voices_in_use.each do |voice|
    voice.sounding = false if voice.sounding && !rg_mix_voice_into(voice, slice)
  end
  @rg_mix_slice = slice.map { |sample| sample.clamp(-128, 127) }
  @rg_mix_slices_made += 1
end

# --- shapes ---

def rg_mix_step_shape(voice)
  case voice.phase
  when RG_SHAPE_CLIMBING
    climbed = voice.level + voice.attack
    if climbed >= rg_shape_full
      voice.level = rg_shape_full
      voice.phase = RG_SHAPE_HOLDING
    else
      voice.level = climbed
    end
  when RG_SHAPE_HOLDING
    if voice.level > voice.sustain
      fallen = (voice.level * voice.decay) >> rg_shape_scale
      voice.level = fallen > voice.sustain ? fallen : voice.sustain
    end
  else
    voice.level = (voice.level * voice.release) >> rg_shape_scale
  end
end

def rg_mix_nearest_whole_gain(gain)
  (gain + (1 << (rg_gain_fraction - 1))) & ~((1 << rg_gain_fraction) - 1)
end

def rg_mix_slide_gain(voice, first)
  level = voice.level
  target = ((voice.loudness * (level + (level >> 7))) >> rg_whole_gain_shift) << rg_gain_fraction
  voice.gain = first ? target : rg_mix_nearest_whole_gain(voice.gain)
  voice.ramp = (((target - voice.gain) >> rg_ramp_split) * rg_slide_share) >> rg_ramp_split
end

def rg_mix_step_shapes
  rg_mix_record_peak
  @rg_mix_voices.first(rg_mix_voice_count).each do |voice|
    next if !voice.sounding || voice.shaped == 0

    if voice.phase == RG_SHAPE_DONE
      voice.sounding = false
      next
    end
    first = voice.phase == RG_SHAPE_CLIMBING && voice.level == 0
    rg_mix_step_shape(voice)
    voice.phase = RG_SHAPE_DONE if voice.level == 0 && voice.phase == RG_SHAPE_FALLING
    rg_mix_slide_gain(voice, first)
  end
end

# --- what a driver reads back ---

def rg_mix_slices_made = @rg_mix_slices_made

# The newest slice's samples, or nil before the first.
def rg_mix_newest_slice = @rg_mix_slices_made > 0 ? @rg_mix_slice : nil

# What voice +voice+ is playing, as [recording, loudness, level, owner, effect, lane], or nil when
# it is not sounding.
def rg_mix_voice_sounding(voice)
  now = @rg_mix_voices[voice]
  return nil unless now.sounding

  [now.recording, now.loudness, now.level, now.owner, now.owner == RG_MIX_EFFECT ? now.effect : -1, now.lane]
end

def rg_mix_peak = @rg_mix_peak
def rg_mix_drops = [@rg_mix_drop_count, @rg_mix_drops_music]
