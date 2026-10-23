# frozen_string_literal: true

require "test_helper"
require "mixed_sound"

# The tests of test_play_this_frame.rb whose games play a song on a recording, which a Game Boy
# Color's hardware cannot play, so they play on the Advance's runs alone.
class TestPlayThisFrameOnTheAdvance < Minitest::Test
  include MixedSound

  Score = RubyGBA::Audio::Score
  Part = Score::Part
  Note = Score::Note

  ASKED_ON = 3

  # A song on a recording, asked for from a routine kept in the cartridge, and a recording of the
  # game's own, each started on pass ASKED_ON when given.
  private def recorded_game(song: false, click: false)
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      enable_sound
      instrument :piano, pcm: [60, -60] * 16_000, rate: 8000, note: :C4
      sound = sample :click, pcm: [40, 0, -40, 0] * 2000, rate: 8000
      music = songs :music, [Score.new(tempo: 150, parts: [Part.new(plays: :piano, notes: [Note.new(at: 0, key: :E4)])])]
      func(:ask, fast: false) { music.play 0, this_frame: true }
      pass = var :pass, 0
      game_loop do
        pass.add! 1
        (pass == ASKED_ON).then do
          sound.play if click
          call :ask if song
        end
      end
    end
    b.finalize_program
    b.program
  end

  private def first_slice_heard(program)
    game_player.run(program, frames: 20).mixed_sound.index { |slice| slice.any?(&:nonzero?) }
  end

  # The song's first note is in the slice of sound a recording the game starts in the same pass
  # is first in: the next one made. Taken up a frame late, it would be a slice behind.
  def test_a_recorded_song_is_first_heard_in_the_slice_a_sound_the_game_starts_beside_it_is
    assert_equal first_slice_heard(recorded_game(click: true)), first_slice_heard(recorded_game(song: true))
  end

  # ...and the console makes the same bytes as the interpreter, slice for slice, with both in it.
  def test_the_console_mixes_a_recorded_song_asked_for_this_frame_as_the_interpreter_does
    assert_mixes_agree(recorded_game(song: true, click: true), frames: 20)
  end
end
