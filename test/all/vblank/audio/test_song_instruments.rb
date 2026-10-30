# frozen_string_literal: true

require "test_helper"

require "stringio"

# A song part can play a recorded instrument instead of the square-wave voice:
# `voice :melody, plays: :piano do ... end`. Each note plays the instrument's recording at that
# note's pitch, through the mixer, and a rest silences it. The part names the instrument, never a
# channel — which voice it uses is the framework's business.
class TestSongInstruments < Minitest::Test
  # Each note played at its pitch on the Advance's cartridge, read back in the emulator, is in
  # test/lowering/gba/vblank/audio/test_song_instruments_cartridge.rb.

  # --- the surface ---

  def test_an_instrument_nobody_declared_is_a_friendly_error
    err = StringIO.new
    assert_raises(VBlank::ROMError) do
      VBlank.build("NOPIANO", console: :gba, code: "ZNOP", maker: "01", out: StringIO.new, err: err) do
        screen :bitmap
        enable_sound
        song(:tune) { voice(:melody, plays: :piano) { note :C4, :quarter } }
        play_song :tune
        game_loop { wait_vblank }
      end
    end
    assert_match(/instrument :piano/, err.string)
  end

  # `plays: :sine` is the console's wave voice, so a recording called :sine could never be played
  # by a part — it would sit in the cartridge, envelope and all, and nothing would say so.
  def test_a_recording_named_like_one_of_the_consoles_own_voices_is_a_friendly_error
    error = assert_raises(ArgumentError) do
      Builder.new.instance_eval { instrument :sine, pcm: [60, -60] * 400, rate: 8000 }
    end

    assert_match(/:sine/, error.message)
    assert_match(/different name/, error.message)
  end

  # A song whose second part is an instrument leaves the square voice beeps use alone, so a
  # beep beside it is nothing to warn about.
  def test_an_instrument_part_does_not_share_the_voice_beeps_use
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      enable_sound
      instrument :bass, pcm: [60, -60] * 4000, rate: 8000, note: :C3
      song :duet do
        voice(:melody) { note :C5, :whole }
        voice(:bass, plays: :bass) { note :C3, :whole }
      end
      play_song :duet
      game_loop do
        wait_vblank
        beep :high
      end
    end
    b.finalize_program
    report = VBlank::IR::Guardrails::Validator.new.run(b.program, autofix: false)

    refute(report.warnings.any? { |w| w.check == :channel_conflict })
  end
end
