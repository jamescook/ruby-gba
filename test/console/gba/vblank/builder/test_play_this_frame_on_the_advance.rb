# frozen_string_literal: true

require "test_helper"
require "mixed_sound"

# The tests of test_play_this_frame.rb whose games play a song or a sound effect on a recording,
# which a Game Boy Color's hardware cannot play, so they play on the Advance's runs alone.
class TestPlayThisFrameOnTheAdvance < Minitest::Test
  include MixedSound

  Score = VBlank::Audio::Score
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

  # TWO EFFECTS OF A GROUP ON RECORDINGS: the one sounding since pass 1 is cut off where the other
  # is asked, and the other's first note starts, both in the same slice of sound on both backends.
  def test_the_console_cuts_off_and_starts_recorded_effects_of_a_group_as_the_interpreter_does
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      enable_sound
      instrument :piano, pcm: [60, -60] * 16_000, rate: 8000, note: :C4
      sfx = sound_effects :sfx, [
        Score.new(tempo: 150, group: :voice, parts: [Part.new(plays: :piano, notes: [Note.new(at: 0, key: :G4)])]),
        Score.new(tempo: 150, group: :voice, parts: [Part.new(plays: :piano, notes: [Note.new(at: 0, key: :D5), Note.new(at: 5, key: :C5)])]),
      ]
      pass = var :pass, 0
      game_loop do
        pass.add! 1
        (pass == 1).then { sfx.play 0 }
        (pass == ASKED_ON).then { sfx.play 1, this_frame: true }
      end
    end
    b.finalize_program

    assert_mixes_agree(b.program, frames: 20)
  end

  # AN EFFECT ITS GROUP DOES NOT PLAY, asked for `this_frame: true`, changes nothing where it is
  # asked: another group's effect, cut off by a plain ask earlier in the same pass, is still let go
  # of on the next frame, on both backends.
  def test_an_effect_not_played_asked_for_this_frame_cuts_nothing_off_early
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      enable_sound
      instrument :piano, pcm: [60, -60] * 16_000, rate: 8000, note: :C4
      held = ->(group, priority, key) { Score.new(tempo: 150, group: group, priority: priority, parts: [Part.new(plays: :piano, notes: [Note.new(at: 0, key: key)])]) }
      sfx = sound_effects :sfx, [held.call(:a, 5, :G4), held.call(:a, 0, :A4), held.call(:b, 0, :C5), held.call(:b, 0, :D5)]
      pass = var :pass, 0
      game_loop do
        pass.add! 1
        (pass == 1).then do
          sfx.play 0
          sfx.play 2
        end
        (pass == ASKED_ON).then do
          sfx.play 3
          sfx.play 1, this_frame: true
        end
      end
    end
    b.finalize_program

    assert_mixes_agree(b.program, frames: 20)
  end
end
