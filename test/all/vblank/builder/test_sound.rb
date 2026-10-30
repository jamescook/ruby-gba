# frozen_string_literal: true

require "test_helper"

# The friendly errors a sound verb raises. That each sound builds into the Advance's cartridge,
# the numbers its registers are given, and the cartridge playing a sound in the emulator are in
# test/lowering/gba/vblank/builder/test_sound_cartridge.rb.
class TestSound < Minitest::Test
  include VBlank::Console::Hardware

  private def build(validate: false, &block)
    VBlank.build("SNDTEST", console: :gba, code: "BSND", maker: "01", validate: validate, out: nil, err: nil, &block)
  end

  # ========================================================================
  # enable_sound
  # ========================================================================

  def test_enable_sound_twice_raises
    assert_raises(ArgumentError) do
      build do
        enable_sound
        enable_sound
        halt
      end
    end
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
  # noise — the percussion / explosion voice
  # ========================================================================

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
