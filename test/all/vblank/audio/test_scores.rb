# frozen_string_literal: true

require "test_helper"

require "stringio"

# The songs and the game these tests hand them to, kept once for this file and for the tests of
# the same songs on the Advance's cartridge (test/lowering/gba/vblank/audio/test_scores_cartridge.rb).
module ScoresGames
  Score = VBlank::Audio::Score
  Part = Score::Part
  Note = Score::Note
  NOTES = VBlank::Audio::Music::NOTE_FREQUENCIES

  # At 150 beats a minute and 24 ticks a beat, a tick is one frame — so a note's tick is the
  # frame it sounds on, counted from the frame the song starts.
  private def notes_every_ten_ticks(*keys, plays: nil, tempo: 150)
    notes = keys.each_with_index.map { |key, n| Note.new(at: n * 10, key: key) }
    Score.new(tempo: tempo, parts: [Part.new(plays: plays, notes: notes)])
  end

  # A game that hands over +scores+, names one each pass with the block, and otherwise does
  # nothing. The block is handed the song list and how many passes have run.
  private def game(scores, &body)
    b = VBlank::Builder.new
    b.instance_eval do
      screen :bitmap
      enable_sound
      instrument :piano, pcm: [60, -60] * 4000, rate: 8000, note: :C4
      instrument :harp, pcm: [40, -40] * 4000, rate: 8000, note: :C4
      music = songs :music, scores
      pass = var :pass, 0
      game_loop do
        pass.add! 1
        instance_exec(music, pass, &body)
      end
    end
    b.finalize_program
    b.program
  end

  # One note held for the whole of a song twenty frames long.
  private def held_note(plays: nil, **options)
    Score.new(tempo: 150, length: 20, **options, parts: [Part.new(plays: plays, notes: [Note.new(at: 0, key: :C5)])])
  end

  # A MIDI key reaches no further than 12,543 Hz, and the noise voice steps as fast as 524,288
  # times a second, so a drum decoded off another cartridge says its rate with `hz:` instead.
  private def drums_at(*rates, plays: :noise)
    notes = rates.each_with_index.map { |rate, n| Note.new(at: n * 4, hz: rate) }
    Score.new(tempo: 150, parts: [Part.new(plays: plays, notes: notes)])
  end
end

# MUSIC HANDED OVER AS DATA. A game whose music already exists as numbers — decoded out of
# another cartridge, read from a file — hands the framework Scores, and picks one to play by a
# number it works out as it runs: `music = songs :music, scores` then `music.play track`.
# Nothing about the tune is written in the program.
#
# What the Advance's cartridge plays — its voices, its speaker, its noise register, and the
# bytes it is built to — is in test/lowering/gba/vblank/audio/test_scores_cartridge.rb.
class TestScores < Minitest::Test
  include ScoresGames

  # --- low notes ---

  def test_saying_it_with_anything_but_true_or_false_is_a_friendly_error
    error = assert_raises(ArgumentError) do
      Score.new(parts: [Part.new(notes: [Note.new(at: 0, key: 60)])], low_notes_intended: :yes).to_song
    end
    assert_match(/must be true or false/, error.message)
  end

  # --- a song that plays once ---

  # Two notes ten frames apart in a song twenty frames long, which says it plays once.
  private def two_notes_once(**options)
    Score.new(tempo: 150, length: 20, plays_once: true, **options,
              parts: [Part.new(notes: [Note.new(at: 0, key: :C4), Note.new(at: 10, key: :E4)])])
  end

  # --- a note's length, instrument and loudness ---

  def test_a_volume_with_a_fraction_on_a_console_voice_is_a_friendly_error
    square = Score.new(parts: [Part.new(notes: [Note.new(at: 0, key: :C4, volume: 7.5)])])
    assert_match(/whole number/, build_error { songs :music, [square] })
  end

  # --- what cannot be had, said plainly ---

  private def build_error(&program)
    err = assert_raises(ArgumentError) do
      b = Builder.new
      b.instance_eval do
        screen :bitmap
        enable_sound
        instance_exec(&program)
      end
    end
    err.message
  end

  def test_something_that_is_not_a_score_is_a_friendly_error
    assert_match(/Score/, build_error { songs :music, [:title_theme] })
  end

  def test_a_note_before_the_start_is_a_friendly_error
    bad = Score.new(parts: [Part.new(notes: [Note.new(at: -4, key: :C4)])])
    assert_match(/tick/, build_error { songs :music, [bad] })
  end

  def test_a_rate_on_a_part_that_is_not_the_noise_voice_is_a_friendly_error
    pad = drums_at(440, plays: :wave)
    message = build_error { songs :music, [pad] }

    assert_match(/only a part on the noise voice/i, message)
    assert_match(/key:/, message, "says what the part gives instead")
  end

  def test_a_note_with_both_a_key_and_a_rate_is_a_friendly_error
    both = Score.new(parts: [Part.new(plays: :noise, notes: [Note.new(at: 0, key: 60, hz: 131_072)])])

    assert_match(/both/, build_error { songs :music, [both] })
  end

  def test_a_rate_the_noise_voice_cannot_make_is_a_friendly_error
    [0, -5, 600_000, "fast"].each do |rate|
      drums = drums_at(rate)
      assert_match(/524,288/, build_error { songs :music, [drums] }, "hz: #{rate.inspect}")
    end
  end

  def test_a_written_number_past_the_last_song_is_a_friendly_error
    song = notes_every_ten_ticks(:C4)
    message = build_error { songs(:music, [song, song]).play 5 }
    assert_match(/2 songs/, message)
  end

  def test_a_song_that_plays_once_and_loops_is_a_friendly_error
    both = Score.new(parts: [Part.new(notes: [Note.new(at: 0, key: :C4), Note.new(at: 48, key: :E4)])],
                     plays_once: true, loop_from: 24)

    assert_match(/plays once.*does not loop/m, build_error { songs :music, [both] })
  end

  def test_saying_plays_once_with_anything_but_true_or_false_is_a_friendly_error
    odd = Score.new(parts: [Part.new(notes: [Note.new(at: 0, key: :C4)])], plays_once: 1)

    assert_match(/plays_once.*must be true or false/m, build_error { songs :music, [odd] })
  end

  # A sound effect plays once whatever its Score says, so one that says so is taken as it is:
  # a decoder hands over the same Score whether the game plays it as a song or as an effect.
  def test_a_sound_effect_may_say_it_plays_once
    b = Builder.new
    effect = two_notes_once
    b.instance_eval do
      screen :bitmap
      enable_sound
      sfx = sound_effects :sfx, { ping: effect }
      game_loop { pressed(:a).then { sfx.play :ping } }
    end
    b.finalize_program
    i = game_player.input_each_frame { |frame| frame == 3 ? [:a] : [] }.run(b.program, frames: 40)

    assert_equal [NOTES[:C4], NOTES[:E4]], i.audio.select { |entry| entry[0] == :note }.map(&:last).reject(&:zero?)
  end

  def test_a_name_the_list_does_not_have_is_a_friendly_error
    song = notes_every_ten_ticks(:C4)
    assert_match(/:credits/, build_error { songs(:music, { title: song }).play :credits })
  end
end
