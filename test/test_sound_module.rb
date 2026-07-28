# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/ruby_gba"

# The shared Sound module: the one source of truth both the DSL and the IR
# backends resolve sounds through. These tests pin the two halves precisely —
# the musical resolution (what a beep *means*) and the register encoding (the
# exact hardware writes) — so any drift is caught here rather than as a silent
# change in how a game sounds.
class TestSoundModule < Minitest::Test
  include RubyGBA::Constants

  Sound = RubyGBA::Sound
  Registers = RubyGBA::Sound::Registers

  # ---- musical resolution ----

  def test_named_preset_resolves_to_its_values
    assert_equal({ frequency: 880, duty: :half, decay: :fast, volume: 15 },
                 Sound.resolve_effect(:high))
  end

  def test_bare_frequency_uses_the_defaults
    assert_equal({ frequency: 440, duty: :half, decay: :fast, volume: 15 },
                 Sound.resolve_effect(440))
  end

  def test_overrides_replace_only_what_they_name
    effect = Sound.resolve_effect(440, duty: :quarter, volume: 10)
    assert_equal :quarter, effect[:duty]
    assert_equal 10, effect[:volume]
    assert_equal :fast, effect[:decay] # untouched
  end

  def test_a_defined_sound_wins_over_a_built_in_of_the_same_name
    defined = { high: { frequency: 100, duty: :eighth, decay: :none, volume: 3 } }
    assert_equal 100, Sound.resolve_effect(:high, defined: defined)[:frequency]
  end

  def test_unknown_preset_is_a_friendly_error
    err = assert_raises(ArgumentError) { Sound.resolve_effect(:nope) }
    assert_match(/unknown sound preset/, err.message)
  end

  # ---- register encoding (exact hardware writes) ----

  def test_enable_writes_the_master_registers
    assert_equal [[REG_SOUNDCNT_X, 0x0080], [REG_SOUNDCNT_L, 0x3377], [REG_SOUNDCNT_H, 0x0002]],
                 Registers.enable
  end

  def test_channel2_encodes_duty_volume_decay_and_frequency
    # duty :half=2<<6, volume 15<<12, decay :fast=1<<8 => 0xF180.
    # freq 880 -> period 2048 - round(131072/880) = 1899, plus trigger bit => 0x876B.
    assert_equal [[REG_SOUND2CNT_L, 0xF180], [REG_SOUND2CNT_H, 0x876B]],
                 Registers.channel2(frequency: 880, duty: :half, decay: :fast, volume: 15)
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

  def test_stop_music_silences_both_music_voices
    assert_equal [[REG_SOUND1CNT_H, 0x0000], [REG_SOUND1CNT_X, 0x8000],
                  [REG_SOUND2CNT_L, 0x0000], [REG_SOUND2CNT_H, 0x8000]], Registers.stop_music
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
      Registers.channel2(frequency: 440, duty: :wobble, decay: :fast, volume: 15)
    end
  end
end
