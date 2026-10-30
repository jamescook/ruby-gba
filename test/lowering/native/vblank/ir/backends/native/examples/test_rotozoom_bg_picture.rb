# frozen_string_literal: true

require "test_helper"
require "native_comparison"
require VBlank.root.join("examples/rotozoom_bg").to_s

# examples/rotozoom_bg.rb built for the desktop shows the interpreter's picture pixel for pixel,
# frame by frame, while its checkerboard is turned one way, grown, turned back past upright and
# shrunk: every pixel of every frame is worked back through the turn to the board.
class TestRotozoomBgPicture < Minitest::Test
  include NativeComparison

  TURNS = Ractor.make_shareable(
    NativeComparison.held_for([2..20, :left], [21..50, :up], [51..90, :right], [91..130, :down])
  )

  def test_rotozoom_bg_matches_the_interpreter_through_a_recorded_run
    program = Native.new.checked_program(RotozoomBg::GAME, err: nil)

    assert_recorded_run_matches_reference program, frames: 134, buttons: TURNS
  end
end
