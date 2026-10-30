# frozen_string_literal: true

require "test_helper"

# A SONG WITH AN INTRODUCTION. Game music plays a fanfare once and then loops a later stretch
# for as long as the scene lasts, so a song can say where its loop starts — `loop_from:` on a
# Score, `loop_from_here` in a song block. At its end it goes back there, not to its first note.
#
# What makes that more than a jump is what each part is doing at the loop point: the first time
# round a part gets there from the notes before it, every time after from the end of the song.
# A note held across the loop point is sounded again there on every pass after the first, and a
# part that is silent there is silenced there, whatever the end of the song left it doing.
#
# What the Advance's music voice does at the loop point, read in the emulator, is in
# test/lowering/gba/vblank/audio/test_song_loop_point_cartridge.rb.

# The scores these tests write, shared with the cartridge's tests.
module SongLoopPointGames
  Score = VBlank::Audio::Score
  Part = Score::Part
  Note = Score::Note
  NOTES = VBlank::Audio::Music::NOTE_FREQUENCIES

  # Shareable, as test_helper makes a test class's own constants: a test may run in a Ractor.
  INTRO_THEN_LOOP = Ractor.make_shareable([[0, :C4], [24, :E4], [48, :G4]])

  # At 150 beats a minute and 24 ticks a beat, a tick is one frame. Every song here is 72 ticks
  # long and loops from tick 24 unless it says otherwise: frames 0-23 are the introduction.
  private def score(*parts, loop_from: 24, length: 72)
    Score.new(tempo: 150, length: length, loop_from: loop_from, parts: parts)
  end

  private def part(*notes) = Part.new(plays: :organ, notes: notes.map { |at, key| Note.new(at: at, key: key) })
end

class TestSongLoopPoint < Minitest::Test
  include SongLoopPointGames

  # --- in a song block ---

  def test_a_song_block_marks_its_loop_with_loop_from_here
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      enable_sound
      song :title do
        tempo 150
        note :C4, :whole # the fanfare
        loop_from_here
        note :E4, :half
        note :G4, :half
      end
      play_song :title
      game_loop { wait_vblank }
    end
    b.finalize_program
    notes = game_player.run(b.program, frames: 400).audio.select { |entry| entry[0] == :note }.map(&:last)

    assert_equal NOTES.values_at(:C4, :E4, :G4, :E4, :G4, :E4, :G4, :E4), notes
  end

  # --- what cannot be had, said plainly ---

  def test_a_score_that_loops_from_its_end_is_a_friendly_error
    err = assert_raises(ArgumentError) { score(part(*INTRO_THEN_LOOP), loop_from: 72).to_song }

    assert_match(/before the end/, err.message)
  end

  def test_a_loop_point_that_is_not_a_tick_is_a_friendly_error
    err = assert_raises(ArgumentError) { score(part(*INTRO_THEN_LOOP), loop_from: -1).to_song }

    assert_match(/whole number/, err.message)
  end

  def test_loop_from_here_at_the_end_of_a_song_is_a_friendly_error
    ctx = VBlank::Audio::Music::SongContext.new
    ctx.instance_eval do
      note :C4, :quarter
      loop_from_here
    end

    assert_match(/at the end of the song/, assert_raises(ArgumentError) { ctx.loop_frame }.message)
  end

  def test_parts_that_mark_different_loop_points_are_a_friendly_error
    ctx = VBlank::Audio::Music::SongContext.new
    ctx.instance_eval do
      voice(:melody) { note(:C4, :quarter); loop_from_here; note(:E4, :half) }
      voice(:bass) { note(:C3, :half); loop_from_here; note(:G3, :quarter) }
    end

    assert_match(/different places to loop from/, assert_raises(ArgumentError) { ctx.loop_frame }.message)
  end
end
