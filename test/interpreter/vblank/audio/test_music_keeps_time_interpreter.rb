# frozen_string_literal: true

require "test_helper"
require "all/vblank/audio/test_music_keeps_time"

# A TUNE AND A RECORDING KEEP TIME IN A LATE GAME, asked of the interpreter, the one player that
# can be told a pass took several frames (`frames_each_pass`). The rest of the music's timing,
# played on every run, is in test/all/vblank/audio/test_music_keeps_time.rb.
class TestMusicKeepsTimeInterpreter < Minitest::Test
  include MusicKeepsTimeGames

  # --- the interpreter, told that a pass ran late ---

  def test_a_late_game_hears_the_same_notes_in_the_same_time
    on_time = game_player.run(scale_game, frames: 30)
    late = game_player.frames_each_pass { 2 }.run(scale_game, frames: 15)

    assert_equal [C4, E4, G4], notes(on_time), "thirty frames of the tune reach its third note"
    assert_equal notes(on_time), notes(late),
                 "fifteen passes of two frames each are thirty frames too, so the tune is as far along"
  end

  # --- a recording keeps time too ---

  # A recording of thirty frames, played once at the start. The console mixes it a frame at a
  # time from the screen's own interrupt, so it ends thirty frames in however long a pass takes
  # (test_mixer_keeps_time.rb holds the console to that).
  private def clip_game
    b = Builder.new
    b.instance_eval do
      screen :bitmap
      clip = sample :tone, pcm: Array.new(30 * 100) { |i| i.even? ? 90 : -90 }, rate: 6000 # a hundred samples a frame
      started = var :started, 0
      game_loop do
        (started == 0).then do
          started.set! 1
          clip.play
        end
      end
    end
    b.finalize_program
    b.program
  end

  # The recording starts on the first pass, after the first frame, so a run of N passes has
  # played it for N - 1 of them: on time that is N - 1 frames, and at two frames a pass it is
  # twice that.
  def test_a_late_game_hears_a_recording_end_after_the_same_number_of_frames
    program = clip_game
    sounding = ->(passes, each_pass) { game_player.frames_each_pass { each_pass }.run(program, frames: passes).active_samples }

    assert_equal [:tone], sounding.call(30, 1), "29 frames in, the recording is still playing"
    assert_empty sounding.call(31, 1), "and 30 frames in it has ended"
    assert_equal [:tone], sounding.call(15, 2), "fourteen passes of two frames are 28 frames, still playing"
    assert_empty sounding.call(16, 2), "and fifteen are 30, so it has ended on the same frame"
  end
end
