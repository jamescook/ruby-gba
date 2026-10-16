# frozen_string_literal: true

require "test_helper"

# The shared Sound module: the one source of truth both the DSL and the IR
# backends resolve sounds through. These tests pin the two halves precisely —
# the musical resolution (what a beep *means*) and the register encoding (the
# exact hardware writes) — so any drift is caught here rather than as a silent
# change in how a game sounds.
class TestSoundModule < Minitest::Test
  runs_on :reference, :native

  include RubyGBA::Console::Hardware

  Sound = RubyGBA::Audio::Sound
  Registers = RubyGBA::Audio::Sound::Registers

  # ---- musical resolution ----

  def test_named_preset_resolves_to_its_values
    assert_equal Sound::Effect.new(frequency: 880, duty: :half, decay: :fast, volume: 15),
                 Sound.resolve_effect(:high)
  end

  def test_bare_frequency_uses_the_defaults
    assert_equal Sound::Effect.new(frequency: 440, duty: :half, decay: :fast, volume: 15),
                 Sound.resolve_effect(440)
  end

  def test_overrides_replace_only_what_they_name
    effect = Sound.resolve_effect(440, duty: :quarter, volume: 10)
    assert_equal :quarter, effect.duty
    assert_equal 10, effect.volume
    assert_equal :fast, effect.decay # untouched
  end

  def test_a_defined_sound_wins_over_a_built_in_of_the_same_name
    defined = { high: Sound::Effect.new(frequency: 100, duty: :eighth, decay: :none, volume: 3) }
    assert_equal 100, Sound.resolve_effect(:high, defined: defined).frequency
  end

  def test_unknown_preset_is_a_friendly_error
    err = assert_raises(ArgumentError) { Sound.resolve_effect(:nope) }
    assert_match(/unknown sound preset/, err.message)
  end

  # ---- register encoding (exact hardware writes) ----

  def test_enable_writes_the_master_registers
    # 0xFF77 routes all four channels to both speakers (so a channel-2 music voice
    # or a channel-4 noise hit is heard), at full master volume.
    assert_equal [[REG_SOUNDCNT_X, 0x0080], [REG_SOUNDCNT_L, 0xFF77], [REG_SOUNDCNT_H, 0x0002]],
                 Registers.enable
  end

  def test_channel2_encodes_duty_volume_decay_and_frequency
    # duty :half=2<<6, volume 15<<12, decay :fast=1<<8 => 0xF180.
    # freq 880 -> period 2048 - round(131072/880) = 1899, plus trigger bit => 0x876B.
    assert_equal [[REG_SOUND2CNT_L, 0xF180], [REG_SOUND2CNT_H, 0x876B]],
                 Registers.beep_writes(frequency: 880, duty: :half, decay: :fast, volume: 15)
  end

  def test_channel1_note_sustains_with_no_decay
    # music notes carry no decay: control = duty(2<<6) | volume(12<<12) = 0xC080.
    assert_equal [[REG_SOUND1CNT_L, 0x0000], [REG_SOUND1CNT_H, 0xC080], [REG_SOUND1CNT_X, 0x86D6]],
                 Registers.channel1_note(frequency: 440, duty: :half, volume: 12)
  end

  def test_a_zero_frequency_note_is_a_rest
    assert_equal [[REG_SOUND1CNT_H, 0x0000], [REG_SOUND1CNT_X, 0x8000]],
                 Registers.channel1_note(frequency: 0, duty: :half, volume: 12)
  end

  # Channel 2 as a sustaining music voice mirrors channel 1 (same control word),
  # but has no sweep register, so it's just control + trigger.
  def test_channel2_note_sustains_like_channel_one_without_sweep
    assert_equal [[REG_SOUND2CNT_L, 0xC080], [REG_SOUND2CNT_H, 0x86D6]],
                 Registers.channel2_note(frequency: 440, duty: :half, volume: 12)
  end

  def test_channel_note_dispatches_by_channel
    assert_equal Registers.channel1_note(frequency: 440, duty: :half, volume: 12),
                 Registers.channel_note(1, frequency: 440, duty: :half, volume: 12)
    assert_equal Registers.channel2_note(frequency: 440, duty: :half, volume: 12),
                 Registers.channel_note(2, frequency: 440, duty: :half, volume: 12)
  end

  def test_unknown_duty_is_a_friendly_error
    assert_raises(ArgumentError) do
      Registers.beep_writes(frequency: 440, duty: :wobble, decay: :fast, volume: 15)
    end
  end

  # ---- noise (channel 4) ----

  def test_noise_preset_resolves_to_its_values
    assert_equal({ pitch: :low, decay: :slow, volume: 15, metallic: false },
                 Sound.resolve_noise(:explosion))
  end

  def test_noise_overrides_replace_preset_values
    got = Sound.resolve_noise(:explosion, pitch: :high, volume: 9, metallic: true)
    assert_equal({ pitch: :high, decay: :slow, volume: 9, metallic: true }, got)
  end

  def test_a_nil_noise_preset_is_the_default_hit
    assert_equal Sound.resolve_noise(:hit), Sound.resolve_noise(nil)
  end

  def test_unknown_noise_preset_is_a_friendly_error
    err = assert_raises(ArgumentError) { Sound.resolve_noise(:kaboom) }
    assert_match(/unknown noise preset/, err.message)
  end

  def test_channel4_encodes_the_noise_registers
    # volume 15 (0xF<<12) + fast decay (step 1 <<8) = 0xF100; trigger sets the
    # restart bit, the low-pitch shift (8<<4 = 0x80), and 15-bit width (metallic off).
    assert_equal [[REG_SOUND4CNT_L, 0xF100], [REG_SOUND4CNT_H, 0x8080]],
                 Registers.noise_hit_writes(pitch: :low, decay: :fast, volume: 15, metallic: false)
  end

  def test_metallic_noise_sets_the_seven_bit_width_bit
    _control, trigger = Registers.noise_hit_writes(pitch: :high, decay: :fast, volume: 8, metallic: true)
    assert_equal 0x0008, trigger[1] & 0x0008, "metallic noise sets the 7-bit counter-width bit"
  end

  # ---- wave voice (channel 3) ----

  def test_wavetable_shapes_generate_sample_tables
    assert_equal([15] * 16 + [0] * 16, Sound.wavetable(:square))
    saw = Sound.wavetable(:sawtooth)
    assert_equal 32, saw.length
    assert_equal 0, saw.first
    assert_equal 15, saw.last
    assert(Sound.wavetable(:sine).all? { |s| s.between?(0, 15) })
  end

  def test_unknown_wave_shape_is_a_friendly_error
    err = assert_raises(ArgumentError) { Sound.wavetable(:zigzag) }
    assert_match(/:zigzag/, err.message)
    assert_match(/:triangle/, err.message, "it names the shapes there are")
    assert_match(/32 steps/, err.message, "...and says a waveform of your own is the other way")
  end

  # --- a waveform of the game's own, rather than one of the names ---

  # The console's wave voice is 32 steps of four bits, not a set of timbres, and a game whose
  # music came from somewhere else arrives holding those 32 numbers. A 50% pulse is the common
  # case and is none of the four names.
  PULSE_50 = ([15] * 16 + [0] * 16).freeze

  def test_steps_are_taken_as_the_waveform_itself
    assert_equal PULSE_50, Sound.wavetable(PULSE_50)
    refute_equal Sound.wavetable(:triangle), Sound.wavetable(PULSE_50), "a pulse is not a triangle"
  end

  def test_a_waveform_of_the_wrong_length_is_a_friendly_error
    err = assert_raises(ArgumentError) { Sound.wavetable([15] * 31) }
    assert_match(/32 steps/, err.message)
    assert_match(/31/, err.message, "it says how many were given")
  end

  def test_a_step_outside_four_bits_is_a_friendly_error
    err = assert_raises(ArgumentError) { Sound.wavetable(([15] * 31) + [16]) }
    assert_match(/0 to 15/, err.message)
    assert_match(/31/, err.message, "it names which step is wrong")
  end

  def test_wave_rate_inverts_the_channel3_frequency_formula
    # tone = 65536/(2048-value), so value = 2048 - 65536/freq. 440 Hz -> 1899.
    assert_equal 1899, Registers.wave_rate(440)
  end

  def test_pack_wavetable_packs_two_samples_per_byte_two_bytes_per_word
    # A [15,0,15,0,...] table: each byte is 0xF0, each little-endian word 0xF0F0.
    assert_equal [0xF0F0] * 8, Registers.pack_wavetable([15, 0] * 16)
  end

  def test_wave_play_uploads_the_table_and_triggers_the_channel
    writes = Registers.wave_start_writes(Sound.wavetable(:sine), frequency: 440, volume: :full)
    assert_equal 21, writes.length, "two bank uploads (8 words each) plus 5 control writes"
    assert_equal [REG_SOUND3CNT_L, 0x0000], writes.first, "starts with the DAC off to load wave RAM"
    assert_includes writes, [REG_SOUND3CNT_L, 0x0080], "turns the DAC on to play"
    assert_includes writes, [REG_SOUND3CNT_H, 0x2000], "full volume"
    assert_equal [REG_SOUND3CNT_X, 0x8000 | Registers.wave_rate(440)], writes.last, "restart + sample rate last"
  end

  def test_wave_stop_switches_the_dac_off
    assert_equal [[REG_SOUND3CNT_L, 0x0000]], Registers.wave_stop
  end

  def test_unknown_wave_volume_is_a_friendly_error
    err = assert_raises(ArgumentError) do
      Registers.wave_start_writes(Sound.wavetable(:sine), frequency: 440, volume: :loud)
    end
    assert_match(/unknown wave volume/, err.message)
  end

  # ---- what the wave and noise voices sound like, for a backend with no sound chip ----

  # One wave is a whole number of ticks of a 65,536-a-second clock: 440 Hz is 148.9 of them, so
  # it plays as 149. The register holds what is left of 2048, which is the 1899 above.
  def test_a_wave_note_lasts_a_whole_number_of_ticks
    assert_equal 149, Sound.wave_voice_ticks(440)
    assert_equal 2048 - 149, Registers.wave_rate(440)
  end

  # 2048 ticks is the longest wave there is, 32 Hz: a lower note plays there. One tick is the
  # shortest.
  def test_a_wave_note_stops_at_the_ends_of_what_the_voice_can_play
    assert_equal 2048, Sound.wave_voice_ticks(32)
    assert_equal 2048, Sound.wave_voice_ticks(20)
    assert_equal 1, Sound.wave_voice_ticks(100_000)
  end

  # Each step of the waveform is cut to so many quarters, with what is left over dropped: a step
  # of 15 at half is 7, and at three quarters 11.
  def test_a_wave_step_is_cut_to_quarters_and_rounded_down
    assert_equal [0, 3, 7, 11, 15], Sound::WAVE_LEVEL_STEPS.map { |level| Sound.wave_step_at(15, level) }
    assert_equal [0, 1, 2, 3, 5], Sound::WAVE_LEVEL_STEPS.map { |level| Sound.wave_step_at(5, level) }
  end

  # The noise voice's clock is 524,288 ticks a second. A step of the hiss lasts twice its
  # divider, doubled once for each halving — and a divider of 0 stands for a half.
  def test_a_step_of_the_hiss_lasts_a_whole_number_of_ticks
    assert_equal 1, Sound.noise_step_ticks(0, 0)
    assert_equal 2, Sound.noise_step_ticks(1, 0)
    assert_equal 6 << 4, Sound.noise_step_ticks(3, 4)
  end

  # The three pitches a `noise` hit can have, as how long a step lasts: 131,072 steps a second,
  # 16,384 and 2,048.
  def test_the_three_pitches_of_a_hit
    assert_equal({ high: 4, mid: 32, low: 256 },
                 %i[high mid low].to_h { |pitch| [pitch, Sound.noise_hit_step_ticks(pitch)] })
  end

  # A note on the noise voice takes the step nearest its pitch: 262 steps a second is 2001
  # ticks each, and the nearest the voice can make is 2048 — which is the 256 Hz the registers
  # are given.
  def test_a_noise_note_takes_the_nearest_step_there_is
    assert_equal 2048, Sound.noise_note_step_ticks(262)
    assert_equal 256, Registers.noise_frequency(*Registers.noise_clock(262))
  end

  def test_an_unknown_noise_pitch_is_a_friendly_error
    err = assert_raises(ArgumentError) { Sound.noise_hit_step_ticks(:shrill) }
    assert_match(/unknown noise pitch/, err.message)
  end

  # A plain hiss comes out of fifteen bits and a metallic one out of seven, which is what makes
  # it repeat soon enough to be heard as a rattle.
  def test_a_metallic_hiss_repeats_sooner
    assert_equal 15, Sound.noise_register_bits(false)
    assert_equal 7, Sound.noise_register_bits(true)
  end
end
