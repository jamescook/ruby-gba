# frozen_string_literal: true

require "test_helper"
require "native_comparison"
require RubyGBA.root.join("examples/level").to_s

# examples/level.rb built for the desktop shows the interpreter's picture pixel for pixel, frame
# by frame, while the hero is walked round a level whose tiles and map came from files: right,
# down, left and up again.
class TestLevelPicture < Minitest::Test
  # The native lowering's own tests, which only a native run plays (see TestSuites).
  runs_on :native

  include NativeComparison

  WALK = Ractor.make_shareable(
    NativeComparison.held_for([2..20, :right], [21..40, :down], [41..50, :left], [51..60, :up])
  )

  def test_level_matches_the_interpreter_through_a_recorded_run
    program = Native.new.checked_program(Level::GAME, err: nil)

    assert_recorded_run_matches_reference program, frames: 64, buttons: WALK
  end
end
