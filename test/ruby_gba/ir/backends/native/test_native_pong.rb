# frozen_string_literal: true

require "test_helper"
require "native_comparison"
require_relative "../../../../../examples/pong"

# examples/pong.rb built for the desktop shows the interpreter's picture pixel for pixel, frame
# by frame, over a recorded run: the zooming title and its menu, START, the zoom away, and a
# rally with the paddle moved up and down. Its sound is not played yet; nothing it draws or
# keeps depends on it.
class TestNativePong < Minitest::Test
  # Starts child processes (zig, and the program it builds), which Ruby cannot do from inside a
  # Ractor — the spawn waits for ever — so on the main Ractor, not in the pool. See test_helper.
  runs_on_the_main_ractor!

  include NativeComparison

  # The buttons held, frame by frame: down and up on the title's menu, A on START, then the
  # paddle up and down once the rally is under way.
  RUN = Ractor.make_shareable(
    { 20 => %i[down], 24 => %i[up], 30 => %i[a] }
      .merge((100..125).to_h { |frame| [frame, %i[up]] })
      .merge((126..160).to_h { |frame| [frame, %i[down]] })
  )

  def test_pong_matches_the_interpreter_through_a_recorded_run
    program = Native.new.checked_program(PongGame::GAME, err: nil)

    last = assert_native_matches_reference(program, frames: 160, buttons: RUN)

    assert_equal 1, last.variables[:state], "the run should end in the rally"
  end
end
