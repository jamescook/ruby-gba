# frozen_string_literal: true

require "test_helper"
require "native_comparison"
require_relative "../../../../../../examples/snake_buffered"

# examples/snake_buffered.rb built for the desktop shows the interpreter's picture pixel for
# pixel, frame by frame, on a tear-free screen: the title, START, the snake steered up and left,
# and on until it runs into a wall and the game is over. Its variables and its sound log — the
# beep as it dies — match on every frame too.
class TestSnakeBufferedPicture < Minitest::Test
  # The native lowering's own tests, which only a native run plays (see TestSuites).
  runs_on :native

  include NativeComparison

  GAME_OVER = 2

  PLAY = Ractor.make_shareable(
    NativeComparison.held_for([3..4, :start], [20..22, :up], [40..42, :left])
  )

  def test_snake_buffered_matches_the_interpreter_from_the_title_to_game_over
    program = Native.new.checked_program(BufferedSnake::GAME, err: nil)

    last = assert_native_matches_reference(program, frames: 260, buttons: PLAY)

    assert_equal GAME_OVER, last.variables[:state], "the run should end with the game over"
    assert(last.sounds.any? { |entry| entry.first == :beep }, "with the beep as the snake dies in the log compared")
  end
end
