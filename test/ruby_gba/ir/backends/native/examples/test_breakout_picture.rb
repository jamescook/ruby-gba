# frozen_string_literal: true

require "test_helper"
require "native_comparison"
require_relative "../../../../../../examples/breakout"

# examples/breakout.rb built for the desktop shows the interpreter's picture pixel for pixel,
# frame by frame, over a recorded game: the title, START, the paddle moved right and then left
# under the ball, bricks broken, three lives lost, the game-over screen and back to the title.
# Its variables and its sound log match on every frame too.
#
# The game keeps its best score in save memory (`save_var`), so it is also switched off and on
# again here: the best score is still there, and so is the bar a new game draws from it.
class TestBreakoutPicture < Minitest::Test
  # The native lowering's own tests, which only a native run plays (see TestSuites).
  runs_on :native

  include NativeComparison

  TITLE = 0
  GAME_OVER = 3

  # START on the title; the paddle right and then left, which puts it under the ball's second
  # fall so a run of bricks goes before the first life does; nothing more until the third life is
  # lost and the game is over with 170 points, around frame 374; START again for the title.
  RUN = Ractor.make_shareable(
    NativeComparison.held_for([3..4, :start], [10..25, :right], [90..110, :left], [400..401, :start])
  )
  GAME_OVER_BY = 380

  def program = Native.new.checked_program(Breakout::GAME, err: nil)

  def test_breakout_matches_the_interpreter_through_a_recorded_game
    last = assert_native_matches_reference(program, frames: 420, buttons: RUN)

    assert_equal TITLE, last.variables[:state], "the run should end back on the title"
    assert_equal 170, last.variables[:high_score], "with the game's score kept as the best"
    assert(last.sounds.any? { |entry| entry.first == :beep }, "and the beeps of a played game in the log compared")
  end

  # The same game played from a new cartridge, and then the cartridge switched on again: the
  # best score comes back out of save memory, and a new game draws how near it is to that score
  # as a bar, which a game with no best score never draws.
  def test_the_best_score_is_still_there_when_the_game_is_switched_on_again
    store = SaveImage.new
    played = CheckedNativeRun.new(save: store).input_each_frame { |frame| RUN.fetch(frame, []) }
                             .run(program, frames: GAME_OVER_BY)
    assert_equal [GAME_OVER, 170], [played[:state], played[:high_score]]

    again = CheckedNativeRun.new(save: store).input_each_frame { |frame| RUN.fetch(frame, []) }.run(program, frames: 60)

    assert_equal 170, again[:high_score]
    assert_equal [10, 9], [again[:score], again[:_best_bar]], "one brick down: ten points of 170, along a bar of 160"
  end
end
