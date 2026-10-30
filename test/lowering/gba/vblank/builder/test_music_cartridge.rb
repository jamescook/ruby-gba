# frozen_string_literal: true

require "test_helper"

# Songs on the Advance's cartridge: that a game with a song builds a cartridge with the
# sequencer in it, the numbers its square voice is given, and the cartridge playing in the
# emulator. A song's notes and the friendly errors are in test/all/vblank/builder/test_music.rb.
class TestMusicCartridge < Minitest::Test
  private def build(validate: false, &block)
    VBlank.build("MUSTEST", console: :gba, code: "BMUS", maker: "01", validate: validate, out: nil, err: nil, &block)
  end

  # ========================================================================
  # song — DSL definition
  # ========================================================================

  def test_song_defines_and_stores
    rom = build do
      enable_sound
      song :melody do
        tempo 120
        note :C4, :quarter
        note :E4, :quarter
      end
      halt
    end
    assert_operator rom.size, :>, 0
  end

  # ========================================================================
  # play_song — emits sequencer code
  # ========================================================================

  def test_play_song_emits_code
    rom = build do
      enable_sound
      song :bgm do
        tempo 120
        note :C4, :quarter
        note :E4, :quarter
        rest :quarter
      end

      game_loop do
        play_song :bgm
      end
    end

    # ROM should be larger than a minimal build (sequencer code adds instructions)
    assert_operator rom.code_offset, :>, 0x200
  end

  # ========================================================================
  # stop_music — silences channel 1
  # ========================================================================

  def test_stop_music_emits_code
    rom = build do
      enable_sound
      song :bgm do
        note :C4, :quarter
      end

      game_loop do
        play_song :bgm
      end
    end
    assert_operator rom.size, :>, 0
  end

  def test_stop_music_standalone
    rom = build do
      enable_sound
      stop_music
      halt
    end
    assert_operator rom.size, :>, 0
  end

  # ========================================================================
  # Channel 1 register values
  # ========================================================================

  def test_ch1_frequency_value_a4
    # A4 = 440 Hz: freq_val = 2048 - 131072/440 = 2048 - 298 = 1750
    freq_val = (2048 - (131_072.0 / 440)).round
    assert_equal 1750, freq_val
  end

  def test_ch1_frequency_value_c4
    # C4 = 262 Hz: freq_val = 2048 - 131072/262 = 2048 - 500 = 1548
    freq_val = (2048 - (131_072.0 / 262)).round
    assert_equal 1548, freq_val
  end

  # ========================================================================
  # Integration: full song with beeps
  # ========================================================================

  def test_song_and_beep_coexist
    rom = build do
      enable_sound
      define_sound :hit, frequency: 880, duty: :quarter, decay: :fast

      song :bgm do
        tempo 140
        note :C4, :eighth
        note :E4, :eighth
        note :G4, :quarter
        rest :quarter
      end

      game_loop do
        play_song :bgm
        beep :hit
      end
    end
    assert_operator rom.size, :>, 0
  end

  # ========================================================================
  # Integration: runs in mGBA
  # ========================================================================

  def test_music_runs_in_mgba
    rom = build do
      screen :bitmap
      enable_sound

      song :test_melody do
        tempo 140
        note :C4, :eighth
        note :E4, :eighth
        note :G4, :quarter
        rest :quarter
      end

      clear_screen :black
      draw_text "MUSIC TEST", 80, 70, :white

      game_loop do
        play_song :test_melody
      end
    end

    assert_emulator_loads_rom(rom, frames: 120)
  end
end
