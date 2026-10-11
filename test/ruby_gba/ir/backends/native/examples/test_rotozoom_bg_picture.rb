# frozen_string_literal: true

require "test_helper"
require "native_comparison"
require_relative "../../../../../../examples/rotozoom_bg"

# examples/rotozoom_bg.rb built for the desktop shows the interpreter's picture pixel for pixel,
# frame by frame, while its checkerboard is turned one way, grown, turned back past upright and
# shrunk: every pixel of every frame is worked back through the turn to the board.
class TestRotozoomBgPicture < Minitest::Test
  # The native lowering's own tests, which only a native run plays (see TestSuites).
  runs_on :native

  include NativeComparison

  TURNS = Ractor.make_shareable(
    NativeComparison.held_for([2..20, :left], [21..50, :up], [51..90, :right], [91..130, :down])
  )

  def test_rotozoom_bg_matches_the_interpreter_through_a_recorded_run
    program = Native.new.checked_program(RotozoomBg::GAME, err: nil)

    last = assert_native_matches_reference(program, frames: 134, buttons: TURNS)

    untouched = reference_snapshots(program, frames: 134, buttons: {}).last
    assert untouched.picture != last.picture, "the board should be turned in the last picture compared"
  end
end
