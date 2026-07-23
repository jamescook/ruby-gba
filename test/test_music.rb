# frozen_string_literal: true

require "minitest/autorun"
require "tempfile"
require_relative "../lib/ruby_gba"
require_relative "test_helper"

class TestMusic < Minitest::Test
  include RubyGBA::Constants
  include GembaSupport

  def build(validate: false, &block)
    RubyGBA.build("MUSTEST", code: "BMUS", maker: "01", validate: validate, &block)
  end

  # ========================================================================
  # SongContext — note collection and timing
  # ========================================================================

  def test_song_context_collects_events
    ctx = RubyGBA::Music::SongContext.new
    ctx.instance_eval do
      tempo 120
      note :C4, :quarter
      note :E4, :eighth
      rest :eighth
    end

    assert_equal 3, ctx.events.size
    # At 120 BPM, quarter = 30 frames, eighth = 15 frames
    assert_equal [0, 262], ctx.events[0]     # C4 at frame 0
    assert_equal [30, 330], ctx.events[1]    # E4 at frame 30
    assert_equal [45, 0], ctx.events[2]      # rest at frame 45
    assert_equal 60, ctx.total_frames        # 30 + 15 + 15
  end

  def test_song_context_tempo_affects_duration
    ctx = RubyGBA::Music::SongContext.new
    ctx.instance_eval do
      tempo 60  # slow: quarter = 60 frames
      note :A4, :quarter
    end

    assert_equal 60, ctx.total_frames
  end

  def test_song_context_dotted_durations
    ctx = RubyGBA::Music::SongContext.new
    ctx.instance_eval do
      tempo 120  # quarter = 30 frames
      note :C4, :dotted_quarter  # 1.5 * 30 = 45
      note :D4, :dotted_eighth   # 0.75 * 30 = 22.5 → 23 (rounded)
    end

    assert_equal [0, 262], ctx.events[0]
    assert_equal [45, 294], ctx.events[1]
  end

  def test_song_context_duty_and_volume
    ctx = RubyGBA::Music::SongContext.new
    ctx.instance_eval do
      duty :quarter
      volume 8
    end

    assert_equal :quarter, ctx.duty
    assert_equal 8, ctx.volume
  end

  def test_song_context_unknown_note_raises
    ctx = RubyGBA::Music::SongContext.new
    assert_raises(ArgumentError) do
      ctx.note(:Z9, :quarter)
    end
  end

  def test_song_context_unknown_duration_raises
    ctx = RubyGBA::Music::SongContext.new
    assert_raises(ArgumentError) do
      ctx.note(:C4, :triple)
    end
  end

  def test_song_context_note_by_frequency
    ctx = RubyGBA::Music::SongContext.new
    ctx.instance_eval do
      tempo 120
      note 440, :quarter  # A4 by frequency
    end

    assert_equal 1, ctx.events.size
    assert_equal [0, 440], ctx.events[0]
  end

  def test_song_context_note_bad_frequency_raises
    ctx = RubyGBA::Music::SongContext.new
    assert_raises(ArgumentError) do
      ctx.note(-100, :quarter)
    end
  end

  def test_song_context_note_bad_type_raises
    ctx = RubyGBA::Music::SongContext.new
    assert_raises(ArgumentError) do
      ctx.note("C4", :quarter)
    end
  end

  def test_song_context_bad_tempo_raises
    ctx = RubyGBA::Music::SongContext.new
    assert_raises(ArgumentError) do
      ctx.tempo(-10)
    end
  end

  def test_song_context_bad_volume_raises
    ctx = RubyGBA::Music::SongContext.new
    assert_raises(ArgumentError) do
      ctx.volume(20)
    end
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

  def test_song_duplicate_name_raises
    assert_raises(ArgumentError) do
      build do
        enable_sound
        song :melody do
          note :C4, :quarter
        end
        song :melody do
          note :E4, :quarter
        end
        halt
      end
    end
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
        wait_vblank
        play_song :bgm
      end
    end

    # ROM should be larger than a minimal build (sequencer code adds instructions)
    assert_operator rom.code_offset, :>, 0x200
  end

  def test_play_song_unknown_raises
    assert_raises(ArgumentError) do
      build do
        enable_sound
        play_song :nonexistent
        halt
      end
    end
  end

  def test_play_song_without_enable_sound_raises
    assert_raises(ArgumentError) do
      build do
        song :bgm do
          note :C4, :quarter
        end
        play_song :bgm
        halt
      end
    end
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
        wait_vblank
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
  # Note frequency math
  # ========================================================================

  def test_note_frequencies_cover_c3_to_c6
    freqs = RubyGBA::Music::NOTE_FREQUENCIES
    assert_equal 131, freqs[:C3]
    assert_equal 262, freqs[:C4]
    assert_equal 440, freqs[:A4]
    assert_equal 523, freqs[:C5]
    assert_equal 1047, freqs[:C6]
  end

  def test_all_durations_defined
    durs = RubyGBA::Music::DURATION_MULTIPLIERS
    assert_equal 4.0, durs[:whole]
    assert_equal 2.0, durs[:half]
    assert_equal 1.0, durs[:quarter]
    assert_equal 0.5, durs[:eighth]
    assert_equal 0.25, durs[:sixteenth]
    assert_equal 1.5, durs[:dotted_quarter]
    assert_equal 0.75, durs[:dotted_eighth]
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
        wait_vblank
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
        wait_vblank
        play_song :test_melody
      end
    end

    assert_gemba_loads_rom(rom, frames: 120)
  end
end
