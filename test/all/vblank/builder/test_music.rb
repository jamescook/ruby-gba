# frozen_string_literal: true

require "test_helper"

require "tempfile"

# A song's notes and timing, and the friendly errors a song can raise. What the Advance's
# cartridge holds for a song, and the cartridge playing it in the emulator, are in
# test/lowering/gba/vblank/builder/test_music_cartridge.rb.
class TestMusic < Minitest::Test
  include VBlank::Console::Hardware

  private def build(validate: false, &block)
    VBlank.build("MUSTEST", console: :gba, code: "BMUS", maker: "01", validate: validate, out: nil, err: nil, &block)
  end

  # ========================================================================
  # SongContext — note collection and timing
  # ========================================================================

  def test_song_context_collects_events
    ctx = VBlank::Audio::Music::SongContext.new
    ctx.instance_eval do
      tempo 120
      note :C4, :quarter
      note :E4, :eighth
      rest :eighth
    end

    events = ctx.voices.first.events
    assert_equal 3, events.size
    # At 120 BPM, quarter = 30 frames, eighth = 15 frames
    assert_equal [0, 262], events[0]     # C4 at frame 0
    assert_equal [30, 330], events[1]    # E4 at frame 30
    assert_equal [45, 0], events[2]      # rest at frame 45
    assert_equal 60, ctx.total_frames    # 30 + 15 + 15
  end

  def test_song_context_tempo_affects_duration
    ctx = VBlank::Audio::Music::SongContext.new
    ctx.instance_eval do
      tempo 60  # slow: quarter = 60 frames
      note :A4, :quarter
    end

    assert_equal 60, ctx.total_frames
  end

  def test_song_context_dotted_durations
    ctx = VBlank::Audio::Music::SongContext.new
    ctx.instance_eval do
      tempo 120  # quarter = 30 frames
      note :C4, :dotted_quarter  # 1.5 * 30 = 45
      note :D4, :dotted_eighth   # 0.75 * 30 = 22.5 → 23 (rounded)
    end

    events = ctx.voices.first.events
    assert_equal [0, 262], events[0]
    assert_equal [45, 294], events[1]
  end

  def test_song_context_duty_and_volume
    ctx = VBlank::Audio::Music::SongContext.new
    ctx.instance_eval do
      duty :quarter
      volume 8
    end

    assert_equal :quarter, ctx.duty
    assert_equal 8, ctx.volume
  end

  def test_song_context_unknown_note_raises
    ctx = VBlank::Audio::Music::SongContext.new
    assert_raises(ArgumentError) do
      ctx.note(:Z9, :quarter)
    end
  end

  def test_song_context_unknown_duration_raises
    ctx = VBlank::Audio::Music::SongContext.new
    assert_raises(ArgumentError) do
      ctx.note(:C4, :triple)
    end
  end

  def test_song_context_note_by_frequency
    ctx = VBlank::Audio::Music::SongContext.new
    ctx.instance_eval do
      tempo 120
      note 440, :quarter  # A4 by frequency
    end

    events = ctx.voices.first.events
    assert_equal 1, events.size
    assert_equal [0, 440], events[0]
  end

  def test_song_context_note_bad_frequency_raises
    ctx = VBlank::Audio::Music::SongContext.new
    assert_raises(ArgumentError) do
      ctx.note(-100, :quarter)
    end
  end

  def test_song_context_note_bad_type_raises
    ctx = VBlank::Audio::Music::SongContext.new
    assert_raises(ArgumentError) do
      ctx.note("C4", :quarter)
    end
  end

  def test_song_context_bad_tempo_raises
    ctx = VBlank::Audio::Music::SongContext.new
    assert_raises(ArgumentError) do
      ctx.tempo(-10)
    end
  end

  def test_song_context_bad_volume_raises
    ctx = VBlank::Audio::Music::SongContext.new
    assert_raises(ArgumentError) do
      ctx.volume(20)
    end
  end

  # ========================================================================
  # SongContext — layered parts (voices)
  # ========================================================================

  def test_voice_blocks_collect_separate_parts
    ctx = VBlank::Audio::Music::SongContext.new
    ctx.instance_eval do
      tempo 120
      voice :melody do
        note :C5, :quarter   # frame 0
        note :E5, :quarter   # frame 30
      end
      voice :bass do
        note :C3, :half      # frame 0, lasts 60
      end
    end

    voices = ctx.voices
    assert_equal 2, voices.size
    assert_equal [[0, 523], [30, 659]], voices[0].events
    assert_equal [[0, 131]], voices[1].events
    # The song loops at the length of its longest part.
    assert_equal 60, ctx.total_frames
  end

  def test_each_voice_keeps_its_own_duty_and_volume
    ctx = VBlank::Audio::Music::SongContext.new
    ctx.instance_eval do
      voice :lead do
        duty :quarter
        volume 12
        note :C5, :quarter
      end
      voice :bass do
        volume 6
        note :C3, :quarter
      end
    end

    assert_equal({ duty: :quarter, volume: 12 }, ctx.voices[0].to_h.slice(:duty, :volume))
    assert_equal({ duty: :half, volume: 6 }, ctx.voices[1].to_h.slice(:duty, :volume))
  end

  def test_mixing_loose_notes_and_voice_blocks_is_a_friendly_error
    ctx = VBlank::Audio::Music::SongContext.new
    err = assert_raises(ArgumentError) do
      ctx.instance_eval do
        note :C4, :quarter
        voice(:bass) { note :C3, :quarter }
      end
    end
    assert_match(/loose notes or `voice` blocks/, err.message)
  end

  # ========================================================================
  # song — friendly errors
  # ========================================================================

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
  # play_song — friendly errors
  # ========================================================================

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
  # Note frequency math
  # ========================================================================

  def test_note_frequencies_cover_c3_to_c6
    freqs = VBlank::Audio::Music::NOTE_FREQUENCIES
    assert_equal 131, freqs[:C3]
    assert_equal 262, freqs[:C4]
    assert_equal 440, freqs[:A4]
    assert_equal 523, freqs[:C5]
    assert_equal 1047, freqs[:C6]
  end

  def test_all_durations_defined
    durs = VBlank::Audio::Music::DURATION_MULTIPLIERS
    assert_equal 4.0, durs[:whole]
    assert_equal 2.0, durs[:half]
    assert_equal 1.0, durs[:quarter]
    assert_equal 0.5, durs[:eighth]
    assert_equal 0.25, durs[:sixteenth]
    assert_equal 1.5, durs[:dotted_quarter]
    assert_equal 0.75, durs[:dotted_eighth]
  end
end
