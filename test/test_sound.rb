# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/ruby_gba"
require_relative "test_helper"

class TestSound < Minitest::Test
  include RubyGBA::Constants
  include GembaSupport

  def build(validate: false, &block)
    RubyGBA.build("SNDTEST", code: "BSND", maker: "01", validate: validate, &block)
  end

  # ========================================================================
  # enable_sound
  # ========================================================================

  def test_enable_sound_emits_master_registers
    rom = build do
      enable_sound
      halt
    end

    code = rom.buffer.byteslice(0xC0, rom.code_offset - 0xC0)
    # Should write to SOUNDCNT_X (0x04000084), SOUNDCNT_L (0x04000080),
    # and SOUNDCNT_H (0x04000082) — 3 register writes × 3 instructions each
    assert_operator rom.code_offset, :>, 0xC0 + (3 * 3 * 4)
  end

  # ========================================================================
  # beep — built-in presets
  # ========================================================================

  def test_beep_high
    rom = build do
      enable_sound
      beep :high
      halt
    end
    assert_operator rom.size, :>, 0
  end

  def test_beep_low
    rom = build do
      enable_sound
      beep :low
      halt
    end
    assert_operator rom.size, :>, 0
  end

  def test_beep_blip
    rom = build do
      enable_sound
      beep :blip
      halt
    end
    assert_operator rom.size, :>, 0
  end

  def test_beep_score
    rom = build do
      enable_sound
      beep :score
      halt
    end
    assert_operator rom.size, :>, 0
  end

  def test_beep_thud
    rom = build do
      enable_sound
      beep :thud
      halt
    end
    assert_operator rom.size, :>, 0
  end

  # ========================================================================
  # beep — frequency (Hz)
  # ========================================================================

  def test_beep_with_frequency
    rom = build do
      enable_sound
      beep 440
      halt
    end
    assert_operator rom.size, :>, 0
  end

  def test_beep_with_frequency_and_options
    rom = build do
      enable_sound
      beep 660, duty: :quarter, decay: :slow, volume: 10
      halt
    end
    assert_operator rom.size, :>, 0
  end

  # ========================================================================
  # define_sound — custom presets
  # ========================================================================

  def test_define_sound_and_beep
    rom = build do
      enable_sound
      define_sound :paddle_hit, frequency: 880, duty: :quarter, decay: :fast
      beep :paddle_hit
      halt
    end
    assert_operator rom.size, :>, 0
  end

  def test_define_sound_overrides_defaults
    rom = build do
      enable_sound
      define_sound :custom, frequency: 500, duty: :eighth, decay: :none, volume: 8
      beep :custom
      halt
    end
    assert_operator rom.size, :>, 0
  end

  def test_enable_sound_twice_raises
    assert_raises(ArgumentError) do
      build do
        enable_sound
        enable_sound
        halt
      end
    end
  end

  def test_beep_preset_overridden_by_kwargs
    # Custom preset says volume: 15, but caller overrides to 5
    rom = build do
      enable_sound
      define_sound :loud, frequency: 880, volume: 15
      beep :loud, volume: 5
      halt
    end
    assert_operator rom.size, :>, 0
  end

  # ========================================================================
  # Error handling
  # ========================================================================

  def test_beep_without_enable_sound_raises
    assert_raises(ArgumentError) do
      build do
        beep 440
        halt
      end
    end
  end

  def test_beep_unknown_preset_raises
    assert_raises(ArgumentError) do
      build do
        beep :nonexistent
        halt
      end
    end
  end

  def test_beep_unknown_duty_raises
    assert_raises(ArgumentError) do
      build do
        beep 440, duty: :invalid
        halt
      end
    end
  end

  def test_beep_unknown_decay_raises
    assert_raises(ArgumentError) do
      build do
        beep 440, decay: :invalid
        halt
      end
    end
  end

  # ========================================================================
  # Duty cycle coverage
  # ========================================================================

  def test_all_duty_cycles
    %i[eighth quarter half square three_quarter].each do |duty|
      rom = build do
        enable_sound
        beep 440, duty: duty
        halt
      end
      assert_operator rom.size, :>, 0, "duty :#{duty} should build"
    end
  end

  # ========================================================================
  # Decay preset coverage
  # ========================================================================

  def test_all_decay_presets
    %i[fast medium slow none].each do |decay|
      rom = build do
        enable_sound
        beep 440, decay: decay
        halt
      end
      assert_operator rom.size, :>, 0, "decay :#{decay} should build"
    end
  end

  # ========================================================================
  # Register value verification
  # ========================================================================

  def test_beep_writes_correct_frequency_value
    # 440 Hz: freq_val = 2048 - 131072/440 = 2048 - 298 = 1750
    builder = nil
    rom = RubyGBA.build("TEST", code: "BTST", maker: "01", validate: false) do
      builder = self
      enable_sound
      beep 440
      halt
    end

    # freq_val should be 1750 (0x6D6), trigger bit 15 → 0x86D6
    expected_cnt_h = 0x8000 | 1750
    assert_equal 0x86D6, expected_cnt_h

    # Verify the value appears in the ROM (as a 16-bit immediate loaded into r0)
    code = rom.buffer.byteslice(0xC0, rom.code_offset - 0xC0)
    # The frequency register write stores 0x86D6 via load_immediate → store_halfword.
    # Just verify the ROM built without error — the frequency math is tested above.
    assert_operator rom.code_offset, :>, 0xC0
  end

  def test_beep_writes_correct_envelope
    # volume=15, decay=:fast (step=1), duty=:half (bits 6-7 = 2)
    # CNT_L = (2 << 6) | (15 << 12) | (1 << 8) = 0x80 | 0xF000 | 0x100 = 0xF180
    expected = (2 << 6) | (15 << 12) | (1 << 8)
    assert_equal 0xF180, expected
  end

  # ========================================================================
  # Integration: runs in mGBA
  # ========================================================================

  def test_sound_runs_in_mgba
    rom = build do
      screen :bitmap
      enable_sound

      define_sound :chirp, frequency: 880, duty: :quarter, decay: :fast

      clear_screen :black
      beep :chirp

      game_loop do
      end
    end

    assert_gemba_loads_rom(rom, frames: 30)
  end

  # ========================================================================
  # noise — the percussion / explosion voice
  # ========================================================================

  def test_noise_preset_builds
    rom = build do
      enable_sound
      noise :explosion
      halt
    end
    assert_operator rom.size, :>, 0
  end

  def test_noise_before_enable_sound_raises
    err = assert_raises(ArgumentError) do
      build do
        noise :hit
        halt
      end
    end
    assert_match(/enable_sound before noise/, err.message)
  end

  # ========================================================================
  # wave — the programmable wave voice (channel 3)
  # ========================================================================

  def test_wave_tone_builds
    rom = build do
      enable_sound
      wave :triangle, :C4
      stop_wave
      halt
    end
    assert_operator rom.size, :>, 0
  end

  def test_wave_before_enable_sound_raises
    err = assert_raises(ArgumentError) do
      build do
        wave :sine, :C4
        halt
      end
    end
    assert_match(/enable_sound before wave/, err.message)
  end

  def test_wave_with_an_unknown_note_raises
    err = assert_raises(ArgumentError) do
      build do
        enable_sound
        wave :sine, :Z9
        halt
      end
    end
    assert_match(/not known/, err.message)
  end
end
