# frozen_string_literal: true

require "test_helper"

# The tests of test_song_loop_point.rb whose games play their music from a recording, which a Game
# Boy Color's sound hardware cannot play, so they play on the Advance's runs alone.
class TestSongLoopPointOnTheAdvance < Minitest::Test
  Score = RubyGBA::Audio::Score
  Part = Score::Part
  Note = Score::Note
  NOTES = RubyGBA::Audio::Music::NOTE_FREQUENCIES

  # At 150 beats a minute and 24 ticks a beat, a tick is one frame. Every song here is 72 ticks
  # long and loops from tick 24 unless it says otherwise: frames 0-23 are the introduction.
  private def score(*parts, loop_from: 24, length: 72)
    Score.new(tempo: 150, length: length, loop_from: loop_from, parts: parts)
  end

  private def part(*notes) = Part.new(plays: :organ, notes: notes.map { |at, key| Note.new(at: at, key: key) })

  private def game(song)
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      enable_sound
      # Five seconds of a steady tone, so a note is still sounding wherever a test looks.
      instrument :organ, pcm: [60, -60] * 20_000, rate: 8000, note: :C4
      music = songs :music, [song]
      game_loop { music.play 0 }
    end
    b.finalize_program
    b.program
  end

  # Every note the interpreter played, in order, over +frames+.
  private def heard(song, frames: 190)
    game_player.run(game(song), frames: frames).audio.select { |entry| entry[0] == :note }.map(&:last)
  end

  # --- the introduction plays once ---

  INTRO_THEN_LOOP = [[0, :C4], [24, :E4], [48, :G4]].freeze

  def test_the_introduction_plays_once_and_the_rest_repeats
    notes = heard(score(part(*INTRO_THEN_LOOP)))

    assert_equal NOTES.values_at(:C4, :E4, :G4, :E4, :G4, :E4, :G4, :E4), notes
  end

  def test_without_a_loop_point_the_whole_song_repeats
    notes = heard(score(part(*INTRO_THEN_LOOP), loop_from: nil))

    assert_equal NOTES.values_at(:C4, :E4, :G4, :C4, :E4, :G4, :C4, :E4), notes
  end

  # --- a note held across the loop point ---

  # C4 starts in the introduction and is still sounding when the loop point comes; the song
  # ends on G4. So every time round, C4 has to be sounded again at the loop point.
  HELD = [[0, :C4], [48, :G4]].freeze

  def test_a_note_held_across_the_loop_point_sounds_there_every_time_after_the_first
    notes = heard(score(part(*HELD)))

    assert_equal NOTES.values_at(:C4, :G4, :C4, :G4, :C4, :G4, :C4), notes,
                 "C4 again at each loop — and not twice the first time"
  end

  # A song that ends on the very note held across the loop point is still sounding it when it
  # comes round — so it carries on, rather than being struck again: after the first time, C4 is
  # heard where the song plays it (frame 60), and never at the loop point.
  def test_a_song_that_ends_on_the_held_note_carries_it_on
    notes = heard(score(part([0, :C4], [48, :G4], [60, :C4])))

    assert_equal NOTES.values_at(:C4, :G4, :C4, :G4, :C4, :G4, :C4), notes
  end
end
