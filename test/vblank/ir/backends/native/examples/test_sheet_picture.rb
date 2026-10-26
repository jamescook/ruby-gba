# frozen_string_literal: true

require "test_helper"
require "native_comparison"
require VBlank.root.join("examples/sheet").to_s

# examples/sheet.rb built for the desktop shows the interpreter's picture pixel for pixel, frame
# by frame, while a hero whose walk cycle was cut from a sprite sheet is walked right, down, left
# and up again: the frames of the cycle change on the same frames in both.
class TestSheetPicture < Minitest::Test
  include NativeComparison

  WALK = Ractor.make_shareable(
    NativeComparison.held_for([2..20, :right], [21..40, :down], [41..50, :left], [51..60, :up])
  )

  def test_sheet_matches_the_interpreter_through_a_recorded_run
    program = Native.new.checked_program(Sheet::GAME, err: nil)

    assert_recorded_run_matches_reference program, frames: 64, buttons: WALK
  end
end
